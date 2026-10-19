import AVFoundation

/// The kinds of sound NoiseLoom synthesizes. Everything is generated in code; there are no audio files.
enum GeneratorKind: String, CaseIterable, Codable, Identifiable {
    case white, pink, brown, blue, rain, wind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "White Noise"
        case .pink: return "Pink Noise"
        case .brown: return "Brown Noise"
        case .blue: return "Blue Noise"
        case .rain: return "Rain"
        case .wind: return "Wind"
        }
    }
}

/// Per-generator DSP state. It lives in manually allocated memory so the render block
/// never allocates or locks; the main thread only writes `gainTarget`.
struct DSPState {
    var rng: UInt32 = 0x9E37_79B9
    var gainTarget: Float = 0
    var gain: Float = 0
    var b0: Float = 0, b1: Float = 0, b2: Float = 0
    var prev: Float = 0
    var low: Float = 0, low2: Float = 0
    var env: Float = 0
    var lfo: Float = 0.5, lfoTarget: Float = 0.5
    var lfoCounter = 0
    // Sample-rate dependent coefficients, computed once.
    var sampleRate: Float = 48_000
    var bandLow: Float = 0.05, bandHigh: Float = 0.4
    var burstDecay: Float = 0.999, burstProbability: Float = 0.0005
    var lfoCoef: Float = 0.00002

    init(seed: UInt32, sampleRate: Double) {
        rng = seed | 1
        let sr = Float(sampleRate)
        self.sampleRate = sr
        bandLow = 1 - expf(-2 * .pi * 500 / sr)
        bandHigh = 1 - expf(-2 * .pi * 5_000 / sr)
        burstDecay = expf(-1 / (0.03 * sr))
        burstProbability = 18 / sr
        lfoCoef = 1 - expf(-1 / (1.2 * sr))
    }

    /// Fast xorshift32 white noise in [-1, 1].
    @inline(__always) mutating func white() -> Float {
        rng ^= rng << 13
        rng ^= rng >> 17
        rng ^= rng << 5
        return Float(rng) * (2 / Float(UInt32.max)) - 1
    }

    /// Uniform random value in [0, 1].
    @inline(__always) mutating func unit() -> Float { (white() + 1) * 0.5 }

    /// Paul Kellet's economy three-pole pink filter applied to white noise.
    @inline(__always) mutating func pink() -> Float {
        let w = white()
        b0 = 0.99765 * b0 + w * 0.0990460
        b1 = 0.96300 * b1 + w * 0.2965164
        b2 = 0.57000 * b2 + w * 1.0526913
        return (b0 + b1 + b2 + w * 0.1848) * 0.25
    }

    @inline(__always) mutating func next(_ kind: GeneratorKind) -> Float {
        switch kind {
        case .white:
            return white() * 0.5
        case .pink:
            return pink()
        case .brown:
            // Leaky integrator keeps the random walk from drifting.
            low = (low + 0.02 * white()) / 1.02
            return low * 3.5
        case .blue:
            let w = white()
            defer { prev = w }
            return (w - prev) * 0.35
        case .rain:
            let p = pink()
            low += bandLow * (p - low)
            let high = p - low
            low2 += bandHigh * (high - low2)
            if unit() < burstProbability { env = max(env, 0.3 + 0.7 * unit()) }
            env *= burstDecay
            return low2 * (0.6 + 2.2 * env) * 1.6
        case .wind:
            lfoCounter -= 1
            if lfoCounter <= 0 {
                lfoTarget = 0.15 + 0.85 * unit()
                lfoCounter = Int(sampleRate * (1.5 + 3 * unit()))
            }
            lfo += lfoCoef * (lfoTarget - lfo)
            let cutoff = 0.003 + 0.025 * lfo
            low += cutoff * (white() - low)
            low2 += cutoff * (low - low2)
            return low2 * (0.35 + 0.9 * lfo) * 9
        }
    }
}

/// Owns the AVAudioEngine graph: one AVAudioSourceNode per generator feeding the main mixer.
/// Gains are smoothed per sample and each generator is soft-limited with tanh.
final class NoiseEngine {
    private let engine = AVAudioEngine()
    private var nodes: [AVAudioSourceNode] = []
    private var states: [GeneratorKind: UnsafeMutablePointer<DSPState>] = [:]
    private var configObserver: NSObjectProtocol?

    /// Called on the main queue after the hardware route changed (e.g. headphones unplugged).
    var onConfigurationChange: (() -> Void)?

    var isRunning: Bool { engine.isRunning }

    init() {
        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = hardwareRate > 0 ? hardwareRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let mixer = engine.mainMixerNode
        for (index, kind) in GeneratorKind.allCases.enumerated() {
            let state = UnsafeMutablePointer<DSPState>.allocate(capacity: 1)
            state.initialize(to: DSPState(seed: 0x1234_5678 &* UInt32(index + 1), sampleRate: rate))
            states[kind] = state
            let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, bufferList -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                let frames = Int(frameCount)
                guard buffers.count > 0, let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                    return noErr
                }
                if state.pointee.gainTarget == 0 && state.pointee.gain < 0.00001 {
                    state.pointee.gain = 0
                    for b in 0..<buffers.count { if let d = buffers[b].mData { memset(d, 0, Int(buffers[b].mDataByteSize)) } }
                    isSilence.pointee = true
                    return noErr
                }
                for i in 0..<frames {
                    state.pointee.gain += (state.pointee.gainTarget - state.pointee.gain) * 0.0008
                    out[i] = tanhf(state.pointee.next(kind) * 1.2) * state.pointee.gain
                }
                for b in 1..<max(1, buffers.count) {
                    if let d = buffers[b].mData { memcpy(d, out, frames * MemoryLayout<Float>.size) }
                }
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: mixer, format: format)
            nodes.append(node)
        }
        mixer.outputVolume = 1
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.onConfigurationChange?() }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
        for state in states.values {
            state.deinitialize(count: 1)
            state.deallocate()
        }
    }

    func setGain(_ gain: Float, for kind: GeneratorKind) {
        states[kind]?.pointee.gainTarget = max(0, gain)
    }

    func start() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    func pause() { engine.pause() }
}
