import AppKit
import SwiftUI
import WaveCore

private enum SettingsTab: String, CaseIterable {
    case general
    case permissions
    case models
}

struct SettingsView: View {
    @ObservedObject var coordinator: DictationCoordinator
    @ObservedObject var meetingCoordinator: MeetingCoordinator
    @ObservedObject var providerSettings: CloudProviderSettings
    @AppStorage("selected-settings-tab") private var selectedTab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general.rawValue) {
                GeneralSettings(
                    coordinator: coordinator,
                    meetingCoordinator: meetingCoordinator
                )
            }

            Tab("Permissions", systemImage: "lock.shield", value: SettingsTab.permissions.rawValue) {
                PermissionsSettings(coordinator: coordinator)
            }

            Tab("Models", systemImage: "cloud", value: SettingsTab.models.rawValue) {
                ProviderSettings(settings: providerSettings)
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .onAppear {
            if selectedTab == "transcription" { selectedTab = SettingsTab.models.rawValue }
        }
    }
}

private struct ProviderSettings: View {
    @ObservedObject var settings: CloudProviderSettings
    @State private var apiKey = ""

    private let speechModels = [
        ModelChoice("Qwen3 ASR 1.7B", "qwen/qwen3-asr-1.7b", "Quality candidate"),
        ModelChoice("Qwen3 ASR 0.6B", "qwen/qwen3-asr-0.6b", "Speed candidate"),
        ModelChoice("Nemotron 3.5 ASR 0.6B", "nvidia/nemotron-3.5-asr-streaming-multilingual-0.6b", "Latency candidate"),
        ModelChoice("GPT Transcribe", "openai/gpt-transcribe", "Accuracy candidate"),
        ModelChoice("Voxtral Mini Transcribe", "mistralai/voxtral-mini-transcribe", "Meeting candidate"),
    ]

    private let textModels = [
        ModelChoice("GPT-5.6 Luna", "openai/gpt-5.6-luna", "Fast structured output"),
        ModelChoice("GPT-5 Nano", "openai/gpt-5-nano", "Low latency and cost"),
        ModelChoice("Gemini 3.7 Flash", "google/gemini-3.7-flash", "Fast long context"),
        ModelChoice("Nemotron 3.5 Lightning", "nvidia/nemotron-3.5-lightning", "Low cost candidate"),
    ]

    var body: some View {
        Form {
            Section("OpenRouter") {
                LabeledContent("API key") {
                    if settings.hasAPIKey {
                        HStack(spacing: 8) {
                            Label("Configured", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("Remove", role: .destructive) {
                                Task { await settings.removeAPIKey() }
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            SecureField("sk-or-v1-…", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 250)
                            Button("Save") {
                                let value = apiKey
                                apiKey = ""
                                Task { await settings.saveAPIKey(value) }
                            }
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                if !settings.credentialMessage.isEmpty {
                    Text(settings.credentialMessage)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Speech to text") {
                Picker("Model", selection: $settings.speechModel) {
                    ForEach(speechChoices) { choice in
                        VStack(alignment: .leading) {
                            Text(choice.name)
                            Text(choice.note).foregroundStyle(.secondary)
                        }
                        .tag(choice.identifier)
                    }
                }
                .pickerStyle(.menu)

                LabeledContent("Language") {
                    Text("Automatic")
                }

                Text("Used for dictations and meeting transcripts")
                    .foregroundStyle(.secondary)
            }

            Section("Writing and summaries") {
                Picker("Model", selection: $settings.textModel) {
                    ForEach(textChoices) { choice in
                        VStack(alignment: .leading) {
                            Text(choice.name)
                            Text(choice.note).foregroundStyle(.secondary)
                        }
                        .tag(choice.identifier)
                    }
                }
                .pickerStyle(.menu)

                Text("Used for spoken-text cleanup, meeting titles, summaries, and actions")
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Models are independent so each task can be optimized for quality, price, and latency. Your API key stays in this Mac’s Keychain")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var speechChoices: [ModelChoice] {
        choices(speechModels, current: settings.speechModel)
    }

    private var textChoices: [ModelChoice] {
        choices(textModels, current: settings.textModel)
    }

    private func choices(_ choices: [ModelChoice], current: String) -> [ModelChoice] {
        if choices.contains(where: { $0.identifier == current }) { return choices }
        return [ModelChoice(current, current, "Custom model")] + choices
    }

    private struct ModelChoice: Identifiable {
        let name: String
        let identifier: String
        let note: String
        var id: String { identifier }

        init(_ name: String, _ identifier: String, _ note: String) {
            self.name = name
            self.identifier = identifier
            self.note = note
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var coordinator: DictationCoordinator
    @ObservedObject var meetingCoordinator: MeetingCoordinator
    @AppStorage("show-menu-bar-icon") private var showMenuBarIcon = true

    var body: some View {
        Form {
            Section("App") {
                Toggle("Open Keyer at login", isOn: Binding(
                    get: { coordinator.launchAtLogin },
                    set: { coordinator.setLaunchAtLogin($0) }
                ))
                Toggle("Show Keyer in the menu bar", isOn: Binding(
                    get: { showMenuBarIcon },
                    set: { isVisible in
                        if !isVisible, !coordinator.showDockIcon {
                            coordinator.showDockIcon = true
                        }
                        showMenuBarIcon = isVisible
                    }
                ))
                Toggle("Show Keyer in the Dock", isOn: Binding(
                    get: { coordinator.showDockIcon },
                    set: { isVisible in
                        if !isVisible, !showMenuBarIcon {
                            showMenuBarIcon = true
                        }
                        coordinator.showDockIcon = isVisible
                    }
                ))

                Text("Keyer keeps at least one app icon visible")
                    .foregroundStyle(.secondary)

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

                LabeledContent("Locked dictation") {
                    ShortcutKeycaps(tokens: coordinator.holdShortcut.lockDisplayTokens)
                }

                Text("Tap the lock shortcut to start or stop hands-free recording. Escape cancels.")
                    .foregroundStyle(.secondary)

                Picker("Microphone", selection: $coordinator.inputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(coordinator.inputDevices) { device in
                        Text(device.isSystemDefault ? "\(device.name) (Default)" : device.name)
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

            Section("Meetings") {
                Toggle("Show meeting controls", isOn: $meetingCoordinator.showControls)
                Toggle("Suggest meetings", isOn: $meetingCoordinator.suggestMeetings)
                Text("Keyer can suggest recording when a meeting app is active. Recording only starts when you choose Play.")
                    .foregroundStyle(.secondary)
            }

            Section("Writing") {
                Toggle("Clean up spoken text", isOn: $coordinator.cleanUpSpokenText)
                Text("Locally removes filler words, repeated starts, and common spoken corrections. Keeps your language, meaning, and tone.")
                    .foregroundStyle(.secondary)
            }

            Section("Local History") {
                LabeledContent("Status") {
                    Label(coordinator.transcriptArchiveStatus.label,
                          systemImage: coordinator.transcriptArchiveStatus.isAvailable
                            ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(coordinator.transcriptArchiveStatus.isAvailable
                            ? .green : .secondary)
                }

                Button("Open Keyer History") {
                    coordinator.openTranscriptArchive()
                }

                Text("Completed dictations and meetings are saved as readable Markdown files in Documents/Keyer")
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Hold the shortcut for push-to-talk, or use locked dictation for longer recordings.")
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
