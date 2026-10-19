import AppKit
import Foundation
import MediaPlayer

/// UserDefaults keys shared by the controller and the settings window.
enum PrefKey {
    static let defaultSceneID = "defaultSceneID"
    static let fadeInSeconds = "fadeInSeconds"
    static let pauseFadeSeconds = "pauseFadeSeconds"
    static let timerFadeSeconds = "timerFadeSeconds"
    static let resumeLastScene = "resumeLastScene"
    static let userScenes = "userScenes"
    static let currentMix = "currentMix"
    static let selectedSceneID = "selectedSceneID"
    static let wasPlaying = "wasPlaying"
}

/// App-wide playback state: the current mix, scenes, sleep timer, fades, media keys and Now Playing.
@MainActor
final class NoiseController: ObservableObject {
    static let maxEnabled = 3
    static let gainCeiling: Float = 1.0
    static let timerPresets = [0, 15, 30, 60, 120]

    @Published private(set) var isPlaying = false
    @Published var channels: [ChannelSetting] { didSet { applyGains(); persistCurrent() } }
    @Published var masterVolume: Float { didSet { applyGains(); persistCurrent() } }
    @Published private(set) var userScenes: [SoundScene]
    @Published private(set) var selectedSceneID: String
    @Published private(set) var timerMinutes = 0
    @Published private(set) var timerEndDate: Date?
    @Published private(set) var remainingText = ""
    @Published private(set) var stoppedByTimer = false
    @Published private(set) var iconLevel = 1.0
    @Published var lastError: String?

    private let engine = NoiseEngine()
    private let defaults = UserDefaults.standard
    private var fadeFactor: Float = 0
    private var timerFactor: Float = 1
    private var fadeTask: Task<Void, Never>?
    private var ticker: Timer?
    private var iconTimer: Timer?

    var allScenes: [SoundScene] { SoundScene.builtIns + userScenes }
    var selectedScene: SoundScene? { allScenes.first { $0.id == selectedSceneID } }
    var enabledCount: Int { channels.filter(\.enabled).count }

    init() {
        defaults.register(defaults: [
            PrefKey.defaultSceneID: SoundScene.fallbackID,
            PrefKey.fadeInSeconds: 1.5,
            PrefKey.pauseFadeSeconds: 0.2,
            PrefKey.timerFadeSeconds: 30.0,
            PrefKey.resumeLastScene: true,
        ])
        let decoder = JSONDecoder()
        let storedScenes = defaults.data(forKey: PrefKey.userScenes)
            .flatMap { try? decoder.decode([SoundScene].self, from: $0) } ?? []
        let saved = defaults.data(forKey: PrefKey.currentMix).flatMap { try? decoder.decode(SoundScene.self, from: $0) }
        userScenes = storedScenes
        let defaultScene = SoundScene.builtIns + storedScenes
        let initial: SoundScene
        if defaults.bool(forKey: PrefKey.resumeLastScene), let saved {
            initial = saved
            selectedSceneID = defaults.string(forKey: PrefKey.selectedSceneID) ?? saved.id
        } else {
            let id = defaults.string(forKey: PrefKey.defaultSceneID) ?? SoundScene.fallbackID
            initial = defaultScene.first { $0.id == id } ?? SoundScene.builtIns[0]
            selectedSceneID = initial.id
        }
        channels = Self.normalized(initial.channels)
        masterVolume = initial.master

        engine.onConfigurationChange = { [weak self] in self?.handleConfigurationChange() }
        setUpRemoteCommands()
        applyGains()
        updateNowPlaying()
        if defaults.bool(forKey: PrefKey.resumeLastScene) && defaults.bool(forKey: PrefKey.wasPlaying) {
            play()
        }
    }

    /// Ensures every generator appears exactly once and at most `maxEnabled` are on.
    private static func normalized(_ input: [ChannelSetting]) -> [ChannelSetting] {
        var enabled = 0
        return GeneratorKind.allCases.map { kind in
            var setting = input.first { $0.kind == kind } ?? ChannelSetting(kind: kind, enabled: false, volume: 0.5)
            setting.volume = min(1, max(0, setting.volume))
            if setting.enabled { enabled += 1; if enabled > maxEnabled { setting.enabled = false } }
            return setting
        }
    }

    // MARK: Playback

    func togglePlayPause() { isPlaying ? pause() : play() }

    func play() {
        guard !isPlaying else { return }
        stoppedByTimer = false
        do {
            try engine.start()
        } catch {
            lastError = "Couldn't start audio: \(error.localizedDescription)"
            return
        }
        lastError = nil
        isPlaying = true
        defaults.set(true, forKey: PrefKey.wasPlaying)
        ramp(to: 1, duration: defaults.double(forKey: PrefKey.fadeInSeconds))
        startIconAnimation()
        updateNowPlaying()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        defaults.set(false, forKey: PrefKey.wasPlaying)
        stopIconAnimation()
        updateNowPlaying()
        ramp(to: 0, duration: max(0.05, defaults.double(forKey: PrefKey.pauseFadeSeconds))) { [weak self] in
            self?.engine.pause()
        }
    }

    /// Ramps the fade factor in small steps; per-sample smoothing in the engine removes any zipper noise.
    private func ramp(to target: Float, duration: Double, completion: (() -> Void)? = nil) {
        fadeTask?.cancel()
        let start = fadeFactor
        let steps = max(1, Int(duration * 60))
        let stepNanos = UInt64(max(0, duration) / Double(steps) * 1_000_000_000)
        fadeTask = Task { [weak self] in
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: stepNanos)
                guard !Task.isCancelled, let self else { return }
                self.fadeFactor = start + (target - start) * Float(i) / Float(steps)
                self.applyGains()
            }
            guard !Task.isCancelled else { return }
            completion?()
        }
    }

    /// Pushes per-generator gains to the engine, scaling the sum of enabled gains under the ceiling.
    private func applyGains() {
        let sum = channels.filter(\.enabled).reduce(Float(0)) { $0 + $1.volume }
        let scale = sum > Self.gainCeiling ? Self.gainCeiling / sum : 1
        let overall = scale * masterVolume * fadeFactor * timerFactor
        for channel in channels {
            engine.setGain(channel.enabled ? channel.volume * overall : 0, for: channel.kind)
        }
    }

    private func handleConfigurationChange() {
        guard isPlaying else { return }
        do { try engine.start() } catch { lastError = "Audio device changed: \(error.localizedDescription)" }
    }

    // MARK: Channels

    func canEnable(_ kind: GeneratorKind) -> Bool {
        channels.first { $0.kind == kind }?.enabled == true || enabledCount < Self.maxEnabled
    }

    func setEnabled(_ enabled: Bool, for kind: GeneratorKind) {
        guard let index = channels.firstIndex(where: { $0.kind == kind }) else { return }
        if enabled && !canEnable(kind) { return }
        channels[index].enabled = enabled
    }

    func setVolume(_ volume: Float, for kind: GeneratorKind) {
        guard let index = channels.firstIndex(where: { $0.kind == kind }) else { return }
        channels[index].volume = volume
    }

    // MARK: Scenes

    func selectScene(id: String) {
        guard let scene = allScenes.first(where: { $0.id == id }) else { return }
        selectedSceneID = scene.id
        channels = Self.normalized(scene.channels)
        masterVolume = scene.master
        updateNowPlaying()
    }

    func saveScene(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let scene = SoundScene(id: UUID().uuidString, name: name, master: masterVolume, channels: channels)
        userScenes.append(scene)
        selectedSceneID = scene.id
        persistScenes()
        persistCurrent()
        updateNowPlaying()
    }

    /// Deletes the selected user scene and falls back to the default scene.
    func deleteSelectedScene() {
        guard let scene = selectedScene, !scene.isBuiltIn else { return }
        userScenes.removeAll { $0.id == scene.id }
        persistScenes()
        if defaults.string(forKey: PrefKey.defaultSceneID) == scene.id {
            defaults.set(SoundScene.fallbackID, forKey: PrefKey.defaultSceneID)
        }
        let fallback = defaults.string(forKey: PrefKey.defaultSceneID) ?? SoundScene.fallbackID
        selectScene(id: allScenes.contains { $0.id == fallback } ? fallback : SoundScene.fallbackID)
    }

    private func persistScenes() {
        if let data = try? JSONEncoder().encode(userScenes) { defaults.set(data, forKey: PrefKey.userScenes) }
    }

    private func persistCurrent() {
        let current = SoundScene(id: selectedSceneID, name: selectedScene?.name ?? "Custom",
                                 master: masterVolume, channels: channels)
        if let data = try? JSONEncoder().encode(current) { defaults.set(data, forKey: PrefKey.currentMix) }
        defaults.set(selectedSceneID, forKey: PrefKey.selectedSceneID)
    }

    // MARK: Sleep timer

    /// Starts (or cancels, for 0) the sleep timer. The end date is stored so the countdown survives system sleep.
    func setTimer(minutes: Int) {
        ticker?.invalidate()
        ticker = nil
        timerMinutes = minutes
        timerFactor = 1
        applyGains()
        guard minutes > 0 else {
            timerEndDate = nil
            remainingText = ""
            return
        }
        timerEndDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.timerTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        timerTick()
        play()
    }

    private func timerTick() {
        guard let end = timerEndDate else { return }
        let remaining = end.timeIntervalSinceNow
        guard remaining > 0 else { finishTimer(); return }
        let total = Int(remaining.rounded(.up))
        remainingText = total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
        let fade = max(0.5, defaults.double(forKey: PrefKey.timerFadeSeconds))
        let factor = Float(min(1, remaining / fade))
        if factor != timerFactor {
            timerFactor = factor
            applyGains()
        }
    }

    private func finishTimer() {
        ticker?.invalidate()
        ticker = nil
        timerEndDate = nil
        timerMinutes = 0
        remainingText = ""
        fadeTask?.cancel()
        fadeFactor = 0
        timerFactor = 1
        applyGains()
        engine.pause()
        isPlaying = false
        stoppedByTimer = true
        defaults.set(false, forKey: PrefKey.wasPlaying)
        stopIconAnimation()
        updateNowPlaying()
    }

    // MARK: Menu bar icon

    private func startIconAnimation() {
        iconTimer?.invalidate()
        let levels = [0.35, 0.65, 1.0, 0.65]
        var step = 0
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            step = (step + 1) % levels.count
            let level = levels[step]
            Task { @MainActor in self?.iconLevel = level }
        }
        RunLoop.main.add(timer, forMode: .common)
        iconTimer = timer
    }

    private func stopIconAnimation() {
        iconTimer?.invalidate()
        iconTimer = nil
        iconLevel = 1
    }

    // MARK: Media keys & Now Playing

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
    }

    private func updateNowPlaying() {
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: selectedScene?.name ?? "Custom Mix",
            MPMediaItemPropertyArtist: "NoiseLoom",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        info.playbackState = isPlaying ? .playing : .paused
    }
}
