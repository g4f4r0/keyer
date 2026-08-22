import AppKit
import SwiftUI

@main
struct KeyerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Keyer", systemImage: "waveform") {
            KeyerMenu(coordinator: appDelegate.coordinator)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(coordinator: appDelegate.coordinator)
        }
        .defaultSize(width: 620, height: 440)
    }
}

private struct KeyerMenu: View {
    @ObservedObject var coordinator: DictationCoordinator

    var body: some View {
        Button(coordinator.state.sessionID == nil ? "Start Dictation" : "Stop Dictation") {
            coordinator.toggleDictation()
        }
        .disabled(coordinator.state != .ready && coordinator.state.sessionID == nil)

        Divider()

        Label(coordinator.localModelStatus.label,
              systemImage: coordinator.localModelStatus.isDownloaded
                ? "checkmark.circle" : "arrow.down.circle")
            .foregroundStyle(.secondary)

        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",")

        Button("About Keyer") {
            NSApp.orderFrontStandardAboutPanel(options: [
                .applicationName: "Keyer",
                .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1",
                .credits: NSAttributedString(string: "Hold your shortcut. Speak. Release. Done."),
            ])
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Open Dictations in iCloud Drive") {
            coordinator.openTranscriptArchive()
        }

        Divider()

        Button("Quit Keyer") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
