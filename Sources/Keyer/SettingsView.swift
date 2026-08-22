import AppKit
import SwiftUI
import WaveCore

private enum SettingsTab: String, CaseIterable {
    case general
    case permissions
    case transcription
}

struct SettingsView: View {
    @ObservedObject var coordinator: DictationCoordinator
    @AppStorage("selected-settings-tab") private var selectedTab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general.rawValue) {
                GeneralSettings(coordinator: coordinator)
            }

            Tab("Permissions", systemImage: "lock.shield", value: SettingsTab.permissions.rawValue) {
                PermissionsSettings(coordinator: coordinator)
            }

            Tab("Transcription", systemImage: "waveform", value: SettingsTab.transcription.rawValue) {
                LocalModelSettings(coordinator: coordinator)
            }
        }
        .frame(minWidth: 620, minHeight: 560)
    }
}

private struct LocalModelSettings: View {
    @ObservedObject var coordinator: DictationCoordinator
    @State private var confirmsRemoval = false

    var body: some View {
        Form {
            Section("Speech model") {
                LabeledContent("Model") {
                    Text(LocalTranscriptionService.modelDisplayName)
                }
                LabeledContent("Language") {
                    Text("Automatic")
                }
                LabeledContent("Status") {
                    statusLabel
                }

                switch coordinator.localModelStatus {
                case .notDownloaded, .failed:
                    Button("Download Model") {
                        coordinator.downloadLocalModel()
                    }
                    .buttonStyle(.borderedProminent)
                case .downloading, .preparing:
                    ProgressView()
                        .controlSize(.small)
                case .downloaded, .ready:
                    Button("Remove Downloaded Model…", role: .destructive) {
                        confirmsRemoval = true
                    }
                }
            }

            Section {
                Label {
                    Text("Keyer downloads \(LocalTranscriptionService.downloadSizeLabel) on first use, then transcribes privately on this Mac. The model stays warm for fast results and uses no CPU while idle.")
                } icon: {
                    Image(systemName: "lock.shield")
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove the speech model?", isPresented: $confirmsRemoval) {
            Button("Remove Model", role: .destructive) {
                coordinator.removeLocalModel()
            }
        } message: {
            Text("Keyer will download it again the next time you dictate")
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch coordinator.localModelStatus {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .downloaded:
            Label("Downloaded", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .downloading, .preparing:
            Label(coordinator.localModelStatus.label, systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .notDownloaded, .failed:
            Label(coordinator.localModelStatus.label, systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var coordinator: DictationCoordinator

    var body: some View {
        Form {
            Section("App") {
                Toggle("Open Keyer at login", isOn: Binding(
                    get: { coordinator.launchAtLogin },
                    set: { coordinator.setLaunchAtLogin($0) }
                ))
                Toggle("Show Keyer in the Dock", isOn: $coordinator.showDockIcon)

                if coordinator.launchAtLoginNeedsApproval {
                    LabeledContent("Login item") {
                        Button("Open System Settings…") {
                            coordinator.openLoginItemsSettings()
                        }
                    }
                } else if !coordinator.launchAtLoginMessage.isEmpty {
                    Text(coordinator.launchAtLoginMessage)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Dictation") {
                ShortcutRecorder(shortcut: $coordinator.holdShortcut)

                Picker("Microphone", selection: $coordinator.inputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(coordinator.inputDevices) { device in
                        Text(device.isSystemDefault ? "\(device.name) — Default" : device.name)
                            .tag(device.id)
                    }
                    if !coordinator.inputDeviceUID.isEmpty,
                       !coordinator.inputDevices.contains(where: { $0.id == coordinator.inputDeviceUID }) {
                        Text("Unavailable Microphone")
                            .tag(coordinator.inputDeviceUID)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Writing") {
                Toggle("Clean up spoken text", isOn: $coordinator.cleanUpSpokenText)
                Text("Locally removes filler words, repeated starts, and common spoken corrections. Keeps your language, meaning, and tone.")
                    .foregroundStyle(.secondary)
            }

            Section("iCloud History") {
                LabeledContent("Status") {
                    Label(coordinator.transcriptArchiveStatus.label,
                          systemImage: coordinator.transcriptArchiveStatus.isAvailable
                            ? "checkmark.icloud.fill" : "icloud.slash")
                        .foregroundStyle(coordinator.transcriptArchiveStatus.isAvailable
                            ? .green : .secondary)
                }

                HStack {
                    Button("Open in iCloud Drive") {
                        coordinator.openTranscriptArchive()
                    }
                    Button("Try Again") {
                        coordinator.retryTranscriptArchiveSync()
                    }
                    .disabled(coordinator.transcriptArchiveStatus == .checking)
                }

                Text("Every completed dictation is saved as a Markdown document. If iCloud Drive is unavailable, Keyer keeps a local pending copy and syncs it later.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Hold the shortcut while you speak. Keyer records only while the shortcut is down.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            coordinator.refreshInputDevices()
            coordinator.refreshLaunchAtLoginStatus()
        }
    }
}

private struct PermissionsSettings: View {
    @ObservedObject var coordinator: DictationCoordinator

    var body: some View {
        Form {
            Section("Required permissions") {
                PermissionRow(title: "Microphone", systemImage: "mic",
                              granted: coordinator.microphoneGranted,
                              actionTitle: "Allow…") {
                    Task { await coordinator.requestMicrophonePermission() }
                }
                PermissionRow(title: "Accessibility", systemImage: "accessibility",
                              granted: coordinator.accessibilityGranted,
                              actionTitle: "Open System Settings…") {
                    coordinator.requestAccessibilityPermission()
                }
                PermissionRow(title: "Input Monitoring", systemImage: "keyboard",
                              granted: coordinator.inputMonitoringGranted && coordinator.hotkeyOperational,
                              actionTitle: "Open System Settings…") {
                    coordinator.requestInputMonitoringPermission()
                }
            }

            Section {
                Label {
                    Text("Microphone captures speech only while a shortcut is held. Accessibility inserts text, and Input Monitoring detects the shortcut globally.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let title: String
    let systemImage: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

private struct ShortcutRecorder: View {
    @Binding var shortcut: HoldShortcut
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var validationMessage = ""

    var body: some View {
        LabeledContent("Hold-to-talk shortcut") {
            HStack(spacing: 10) {
                ShortcutKeycaps(tokens: shortcut.displayTokens)

                Button(isRecording ? "Cancel" : "Change…") {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }
                .onDisappear { stopRecording() }
            }
        }

        if isRecording {
            Text("Press Fn, or press a modifier and another key. Press Escape to cancel.")
                .foregroundStyle(.secondary)
        } else if !validationMessage.isEmpty {
            Text(validationMessage)
                .foregroundStyle(.red)
        }
    }

    private func startRecording() {
        validationMessage = ""
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            capture(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func capture(_ event: NSEvent) {
        if event.type == .flagsChanged, event.modifierFlags.contains(.function) {
            shortcut = .functionKey
            stopRecording()
            return
        }

        guard event.type == .keyDown else { return }
        if event.keyCode == 53 {
            stopRecording()
            return
        }

        let modifiers = shortcutModifiers(from: event.modifierFlags)
        guard !modifiers.isEmpty else {
            validationMessage = "Include at least one modifier key"
            stopRecording()
            return
        }

        guard let label = keyLabel(for: event) else {
            validationMessage = "That key can’t be used as a shortcut"
            stopRecording()
            return
        }

        shortcut = HoldShortcut(keyCode: event.keyCode, modifiers: modifiers, keyLabel: label)
        stopRecording()
    }

    private func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.function) { modifiers.insert(.function) }
        return modifiers
    }

    private func keyLabel(for event: NSEvent) -> String? {
        let namedKeys: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            76: "Enter", 115: "Home", 116: "Page Up", 117: "Forward Delete",
            119: "End", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        if let named = namedKeys[event.keyCode] { return named }
        guard let characters = event.charactersIgnoringModifiers?.uppercased(),
              characters.count == 1 else { return nil }
        return characters
    }
}

private struct ShortcutKeycaps: View {
    let tokens: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Text(token)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, token.count > 1 ? 8 : 6)
                    .frame(minHeight: 24)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.separator.opacity(0.65), lineWidth: 0.5)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current shortcut: \(tokens.joined(separator: " "))")
    }
}
