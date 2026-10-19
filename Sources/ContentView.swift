import AppKit
import SwiftUI

/// Opens the project's donation page.
enum Support {
    static func openDonationPage() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
    }
}

/// The menu bar panel: transport, master volume, generator mixer, sleep timer and scenes.
struct ContentView: View {
    @EnvironmentObject private var controller: NoiseController
    @State private var isNaming = false
    @State private var newSceneName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if controller.stoppedByTimer {
                Label("Stopped by timer", systemImage: "moon.zzz").font(.callout).foregroundStyle(.secondary)
            }
            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $controller.masterVolume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            .help("Master volume")
            Divider()
            Text("Generators — mix up to \(NoiseController.maxEnabled)").font(.caption).foregroundStyle(.secondary)
            ForEach(controller.channels, id: \.kind) { channel in
                generatorRow(channel)
            }
            Divider()
            timerRow
            sceneRow
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform").font(.title2).foregroundStyle(.tint)
            Text("NoiseLoom").font(.headline)
            Spacer()
            Button {
                controller.togglePlayPause()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(controller.isPlaying ? "Pause" : "Play")
        }
    }

    private func generatorRow(_ channel: ChannelSetting) -> some View {
        HStack {
            Toggle(channel.kind.title, isOn: Binding(
                get: { channel.enabled },
                set: { controller.setEnabled($0, for: channel.kind) }
            ))
            .toggleStyle(.checkbox)
            .disabled(!controller.canEnable(channel.kind))
            .frame(width: 110, alignment: .leading)
            Slider(value: Binding(
                get: { channel.volume },
                set: { controller.setVolume($0, for: channel.kind) }
            ), in: 0...1)
            .disabled(!channel.enabled)
        }
    }

    private var timerRow: some View {
        HStack {
            Picker("Sleep timer", selection: Binding(
                get: { controller.timerMinutes },
                set: { controller.setTimer(minutes: $0) }
            )) {
                ForEach(NoiseController.timerPresets, id: \.self) { minutes in
                    Text(minutes == 0 ? "Off" : "\(minutes) min").tag(minutes)
                }
            }
            if controller.timerEndDate != nil {
                Text(controller.remainingText).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private var sceneRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Scene", selection: Binding(
                    get: { controller.selectedSceneID },
                    set: { controller.selectScene(id: $0) }
                )) {
                    ForEach(controller.allScenes) { Text($0.name).tag($0.id) }
                }
                Button("Save Scene") { isNaming = true }
                Button("Delete", role: .destructive) { controller.deleteSelectedScene() }
                    .disabled(controller.selectedScene?.isBuiltIn ?? true)
            }
            if isNaming {
                HStack {
                    TextField("Scene name", text: $newSceneName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitScene)
                    Button("Save", action: commitScene)
                        .disabled(newSceneName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { isNaming = false; newSceneName = "" }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Support / Donate ❤️") { Support.openDonationPage() }
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }
                .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit NoiseLoom")
        }
    }

    private func commitScene() {
        controller.saveScene(named: newSceneName)
        newSceneName = ""
        isNaming = false
    }
}
