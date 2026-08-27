import AppKit
import SwiftUI
import WaveCore

@main
struct KeyerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("show-menu-bar-icon") private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            KeyerMenu(
                coordinator: appDelegate.coordinator,
                meetingCoordinator: appDelegate.meetingCoordinator
            )
        } label: {
            Image(nsImage: KeyerMenuBarIcon.image)
        }
        .menuBarExtraStyle(.menu)

        Window("History", id: "history") {
            HistoryView()
        }
        .defaultSize(width: 1040, height: 680)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(
                coordinator: appDelegate.coordinator,
                meetingCoordinator: appDelegate.meetingCoordinator,
                providerSettings: appDelegate.providerSettings
            )
        }
        .defaultSize(width: 620, height: 460)
    }
}

private struct KeyerMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var coordinator: DictationCoordinator
    @ObservedObject var meetingCoordinator: MeetingCoordinator

    var body: some View {
        meetingControls

        Divider()

        if let shortcut = coordinator.holdShortcut.menuKeyboardShortcut {
            dictationButton
                .keyboardShortcut(shortcut)
        } else {
            dictationButton
                .badge(Text(coordinator.holdShortcut.lockDisplayTokens.joined(separator: " ")))
        }

        Divider()

        Button("History", systemImage: "clock") {
            openWindow(id: "history")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("h", modifiers: [.command, .shift])

        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",")

        Button("About", systemImage: "info.circle") {
            NSApp.orderFrontStandardAboutPanel(options: [
                .applicationName: "Keyer",
                .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1",
                .credits: NSAttributedString(string: "Hold your shortcut. Speak. Release. Done."),
            ])
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var meetingControls: some View {
        switch meetingCoordinator.state {
        case .idle, .suggested:
            Button("Start Meeting", systemImage: "record.circle") {
                meetingCoordinator.startMeeting()
            }
            .keyboardShortcut("m", modifiers: [.control, .option])
            .disabled(coordinator.state.hasActiveSession)
        case .recording:
            Button("Pause Meeting", systemImage: "pause.circle") {
                meetingCoordinator.pause()
            }
            Button("Stop Meeting", systemImage: "stop.circle") {
                meetingCoordinator.stopAndProcess()
            }
            .keyboardShortcut("m", modifiers: [.control, .option])
        case .paused:
            Button("Resume Meeting", systemImage: "play.circle") {
                meetingCoordinator.resume()
            }
            Button("Stop Meeting", systemImage: "stop.circle") {
                meetingCoordinator.stopAndProcess()
            }
            .keyboardShortcut("m", modifiers: [.control, .option])
            Button("Discard Meeting…", systemImage: "trash", role: .destructive) {
                meetingCoordinator.requestDiscard()
            }
        case .transcribing:
            Button("Transcribing", systemImage: "waveform") {}
                .disabled(true)
        case .summarizing:
            Button("Summarizing", systemImage: "text.badge.star") {}
                .disabled(true)
        case .saved:
            Button("Done", systemImage: "checkmark") {
                meetingCoordinator.openSavedMeeting()
            }
        case .failed:
            if meetingCoordinator.canRetry {
                Button("Retry Meeting", systemImage: "arrow.clockwise") {
                    meetingCoordinator.retry()
                }
            } else {
                Button("Close", systemImage: "xmark") {
                    meetingCoordinator.dismissFailure()
                }
            }
        }
    }

    private var dictationButton: some View {
        Button(
            coordinator.state.sessionID == nil ? "Start Dictation" : "Stop Dictation",
            systemImage: coordinator.state.sessionID == nil ? "mic" : "stop.circle"
        ) {
            coordinator.toggleDictation()
        }
        .disabled(coordinator.state != .ready && coordinator.state.sessionID == nil)
    }
}

private extension KeyEquivalent {
    static let modeSwitch = KeyEquivalent(Character(UnicodeScalar(NSModeSwitchFunctionKey)!))
}

private extension HoldShortcut {
    var menuKeyboardShortcut: KeyboardShortcut? {
        if kind == .functionKey {
            return KeyboardShortcut(.modeSwitch, modifiers: .command)
        }
        guard !lockModifiers.contains(.function), let keyEquivalent else { return nil }
        return KeyboardShortcut(keyEquivalent, modifiers: menuLockModifiers)
    }

    private var menuLockModifiers: EventModifiers {
        var result: EventModifiers = []
        if lockModifiers.contains(.control) { result.insert(.control) }
        if lockModifiers.contains(.option) { result.insert(.option) }
        if lockModifiers.contains(.shift) { result.insert(.shift) }
        if lockModifiers.contains(.command) { result.insert(.command) }
        return result
    }

    private var keyEquivalent: KeyEquivalent? {
        return switch keyCode {
        case 36, 76: KeyEquivalent.return
        case 48: KeyEquivalent.tab
        case 49: KeyEquivalent.space
        case 51: KeyEquivalent.delete
        case 53: KeyEquivalent.escape
        case 115: KeyEquivalent.home
        case 116: KeyEquivalent.pageUp
        case 117: KeyEquivalent.deleteForward
        case 119: KeyEquivalent.end
        case 121: KeyEquivalent.pageDown
        case 123: KeyEquivalent.leftArrow
        case 124: KeyEquivalent.rightArrow
        case 125: KeyEquivalent.downArrow
        case 126: KeyEquivalent.upArrow
        case 122: Self.functionKeyEquivalent(NSF1FunctionKey)
        case 120: Self.functionKeyEquivalent(NSF2FunctionKey)
        case 99: Self.functionKeyEquivalent(NSF3FunctionKey)
        case 118: Self.functionKeyEquivalent(NSF4FunctionKey)
        case 96: Self.functionKeyEquivalent(NSF5FunctionKey)
        case 97: Self.functionKeyEquivalent(NSF6FunctionKey)
        case 98: Self.functionKeyEquivalent(NSF7FunctionKey)
        case 100: Self.functionKeyEquivalent(NSF8FunctionKey)
        case 101: Self.functionKeyEquivalent(NSF9FunctionKey)
        case 109: Self.functionKeyEquivalent(NSF10FunctionKey)
        case 103: Self.functionKeyEquivalent(NSF11FunctionKey)
        case 111: Self.functionKeyEquivalent(NSF12FunctionKey)
        default:
            keyLabel.count == 1 ? keyLabel.lowercased().first.map { KeyEquivalent($0) } : nil
        }
    }

    private static func functionKeyEquivalent(_ value: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(value)!))
    }
}

private enum KeyerMenuBarIcon {
    static let image: NSImage = {
        let fallback = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Keyer") ?? NSImage()
        guard let url = Bundle.main.url(
            forResource: "chat-voice-fill",
            withExtension: "svg",
            subdirectory: "RemixIcons"
        ),
              let image = NSImage(contentsOf: url) else {
            return fallback
        }
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        image.accessibilityDescription = "Keyer"
        return image
    }()
}
