import ServiceManagement
import SwiftUI

/// Preferences: default scene, fade durations, launch at login and resume behaviour.
struct SettingsView: View {
    @EnvironmentObject private var controller: NoiseController
    @AppStorage(PrefKey.defaultSceneID) private var defaultSceneID = SoundScene.fallbackID
    @AppStorage(PrefKey.fadeInSeconds) private var fadeInSeconds = 1.5
    @AppStorage(PrefKey.pauseFadeSeconds) private var pauseFadeSeconds = 0.2
    @AppStorage(PrefKey.timerFadeSeconds) private var timerFadeSeconds = 30.0
    @AppStorage(PrefKey.resumeLastScene) private var resumeLastScene = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Scenes") {
                Picker("Default scene", selection: $defaultSceneID) {
                    ForEach(controller.allScenes) { Text($0.name).tag($0.id) }
                }
                Toggle("Resume last scene on launch", isOn: $resumeLastScene)
            }
            Section("Fades") {
                LabeledContent("Fade in") {
                    Stepper(String(format: "%.1f s", fadeInSeconds), value: $fadeInSeconds, in: 0...10, step: 0.5)
                }
                LabeledContent("Pause fade-out") {
                    Stepper(String(format: "%.1f s", pauseFadeSeconds), value: $pauseFadeSeconds, in: 0.1...3, step: 0.1)
                }
                LabeledContent("Sleep timer fade-out") {
                    Stepper("\(Int(timerFadeSeconds)) s", value: $timerFadeSeconds, in: 5...300, step: 5)
                }
            }
            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
                Text("Play/pause media keys work while NoiseLoom is the active Now Playing app. If another app (Music, a browser) takes over the media keys, use the menu bar button instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("NoiseLoom is free and open source.")
                    Spacer()
                    Button("Support / Donate ❤️") { Support.openDonationPage() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Couldn't update login item: \(error.localizedDescription). You can manage it in System Settings › General › Login Items."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
