import SwiftUI

/// Entry point: a menu-bar-only app with a window-style panel and a Settings window.
@main
struct NoiseLoomApp: App {
    @StateObject private var controller = NoiseController()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(controller)
        } label: {
            Image(systemName: "waveform", variableValue: controller.iconLevel)
                .accessibilityLabel("NoiseLoom")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(controller)
        }
    }
}
