import AppKit
import CoreML
import os
import SwiftUI
import WaveCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let providerSettings: CloudProviderSettings
    let coordinator: DictationCoordinator
    let meetingCoordinator: MeetingCoordinator
    private let openRouterClient: OpenRouterClient
    private let speechProvider: OpenRouterSpeechTranscriptionProvider
    private let languageProvider: OpenRouterLanguageModelProvider
    private var diagnosticAudio: AudioCaptureService?
    private var diagnosticMeetingAudio: MeetingAudioCaptureService?
    private var diagnosticHotkey: HotkeyService?
    private var diagnosticHUDModel: WaveHUDModel?
    private var diagnosticHUD: WaveHUDPanel?
    private var diagnosticSettingsWindow: NSWindow?
    private let diagnosticPeak = OSAllocatedUnfairLock(initialState: Float.zero)

    override init() {
        KeyerConfiguration.shared.registerDefaults()
        let providerSettings = CloudProviderSettings()
        let client = OpenRouterClient(configuration: providerSettings.configuration)
        let speech = OpenRouterSpeechTranscriptionProvider(
            client: client,
            configuration: providerSettings.configuration
        )
        let meetingSpeech = OpenRouterSpeechTranscriptionProvider(
            client: client,
            configuration: providerSettings.configuration,
            modelOverride: KeyerConfiguration.shared.string(
                "models.meeting_speech", default: "openai/gpt-transcribe:nitro"
            )
        )
        let language = OpenRouterLanguageModelProvider(
            client: client,
            configuration: providerSettings.configuration
        )
        let transcriptStore = RemoteTranscriptStore()
        self.providerSettings = providerSettings
        openRouterClient = client
        speechProvider = speech
        languageProvider = language
        coordinator = DictationCoordinator(
            speechTranscriber: speech,
            textCleanup: TextCleanupPipeline(providers: [language]),
            transcriptStore: transcriptStore
        )
        meetingCoordinator = MeetingCoordinator(
            transcriber: meetingSpeech,
            summarizer: language,
            transcriptStore: transcriptStore
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--diagnose-settings") {
            runSettingsDiagnostic()
            return
        }
        if let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--diagnose-history-write=")
        }) {
            runHistoryWriteDiagnostic(String(argument.dropFirst("--diagnose-history-write=".count)))
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--diagnose-history") {
            runHistoryDiagnostic()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--diagnose-recording-escape") {
            runRecordingEscapeDiagnostic()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--diagnose-recording-lock") {
            runRecordingLockDiagnostic()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--diagnose-escape") {
            runEscapeDiagnostic()
            return
        }
        if let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--diagnose-hud=")
        }) {
            runHUDDiagnostic(String(argument.dropFirst("--diagnose-hud=".count)))
            return
        }
        if let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--diagnose-insertion=")
        }) {
            runInsertionDiagnostic(String(argument.dropFirst("--diagnose-insertion=".count)))
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--diagnose-audio") {
            runAudioDiagnostic()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--diagnose-meeting-audio") {
            runMeetingAudioDiagnostic()
            return
        }
        if let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--diagnose-meeting-controls=")
        }) {
            meetingCoordinator.start()
            meetingCoordinator.showDiagnosticControls(
                String(argument.dropFirst("--diagnose-meeting-controls=".count))
            )
            return
        }
        coordinator.canBeginDictation = { [weak meetingCoordinator] in
            meetingCoordinator?.state.isCapturing != true && meetingCoordinator?.state.isProcessing != true
        }
        coordinator.providerReady = { [weak providerSettings] in
            providerSettings?.hasAPIKey == true
        }
        coordinator.meetingToggleHandler = { [weak meetingCoordinator] in
            meetingCoordinator?.toggleMeeting()
        }
        meetingCoordinator.canStart = { [weak coordinator] in
            coordinator?.state.hasActiveSession != true
        }
        meetingCoordinator.providerReady = { [weak providerSettings] in
            providerSettings?.hasAPIKey == true
        }
        meetingCoordinator.inputDeviceUID = { [weak coordinator] in
            coordinator?.inputDeviceUID ?? ""
        }
        meetingCoordinator.beforeProcessing = { [weak coordinator] in
            await coordinator?.prepareForMeetingProcessing()
        }
        coordinator.start()
        meetingCoordinator.start()
        if ProcessInfo.processInfo.arguments.contains("--diagnose-hotkey") {
            let fields = [
                "microphone=\(coordinator.microphoneGranted)",
                "accessibility=\(coordinator.accessibilityGranted)",
                "inputMonitoring=\(coordinator.inputMonitoringGranted)",
                "eventTap=\(coordinator.hotkeyOperational)",
                "shortcut=\(coordinator.holdShortcut.displayTokens.joined())",
                "microphones=\(coordinator.inputDevices.count)",
                "selectedMicrophone=\(coordinator.inputDeviceUID.isEmpty ? "system-default" : "custom")",
                "launchAtLogin=\(coordinator.launchAtLogin)",
                "spokenCleanup=\(coordinator.cleanUpSpokenText)",
            ]
            print(fields.joined(separator: " "))
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        meetingCoordinator.stop()
        coordinator.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator.refreshInputDevices()
        coordinator.refreshReadiness()
        coordinator.refreshLaunchAtLoginStatus()
    }

    private func runHistoryDiagnostic() {
        Task {
            let service = TranscriptArchiveService()
            let available = await service.documentsURL() != nil
            writeDiagnostic("history_status=\(available ? "Saved locally" : "Unavailable") local_available=\(available)\n")
            NSApp.terminate(nil)
        }
    }

    private func runSettingsDiagnostic() {
        coordinator.start()
        let controller = NSHostingController(rootView: SettingsView(
            coordinator: coordinator,
            meetingCoordinator: meetingCoordinator,
            providerSettings: providerSettings
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keyer Settings"
        window.contentViewController = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        diagnosticSettingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func runHistoryWriteDiagnostic(_ text: String) {
        Task {
            let service = TranscriptArchiveService()
            let record = TranscriptArchiveRecord(
                id: UUID(), kind: .dictation, languages: TextNormalizer.detectedLanguages(in: text),
                originalText: text, finalText: text,
                model: "diagnostic", audioDurationSeconds: 0
            )
            do {
                let stageStart = ContinuousClock.now
                let staged = try await service.stage(record)
                let stageMS = elapsedMilliseconds(since: stageStart)
                let syncStart = ContinuousClock.now
                let localURL = await service.documentURL(for: record)
                let syncMS = elapsedMilliseconds(since: syncStart)
                let relativePath = (record.relativeDirectoryComponents + [record.documentFilename])
                    .joined(separator: "/")
                writeDiagnostic("history_write=true status=\(staged.label) local_file=\(localURL != nil) stage_ms=\(stageMS) lookup_ms=\(syncMS) path=\(relativePath) id=\(record.id.uuidString.lowercased())\n")
            } catch {
                writeDiagnostic("history_write=false error=\(error.localizedDescription)\n")
            }
            NSApp.terminate(nil)
        }
    }

    private func runAudioDiagnostic() {
        let audio = AudioCaptureService()
        audio.selectInputDevice(uid: coordinator.inputDeviceUID)
        audio.onLevel = { [diagnosticPeak] level in
            diagnosticPeak.withLock { $0 = max($0, level) }
        }
        diagnosticAudio = audio
        let preparationStart = ContinuousClock.now
        do {
            try audio.prepare()
            let preparationMS = elapsedMilliseconds(since: preparationStart)
            let startInstant = ContinuousClock.now
            try audio.start()
            let startupMS = elapsedMilliseconds(since: startInstant)
            let timing = audio.lastStartupTiming()
            writeDiagnostic("audio_prepare_ms=\(preparationMS) audio_start_ms=\(startupMS) configuration_ms=\(timing?.configurationMilliseconds ?? -1) accumulator_ms=\(timing?.accumulatorMilliseconds ?? -1) tap_ms=\(timing?.tapInstallationMilliseconds ?? -1) engine_ms=\(timing?.engineStartMilliseconds ?? -1)\n")
        } catch {
            writeDiagnostic("audio_start_error=\(error)\n")
            NSApp.terminate(nil)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let cycles = ProcessInfo.processInfo.arguments.first(where: {
                $0.hasPrefix("--diagnose-audio-cycles=")
            }).flatMap { Int($0.dropFirst("--diagnose-audio-cycles=".count)) }.map { max(1, min($0, 100)) } ?? 1
            for cycle in 1...cycles {
                if cycle > 1 {
                    let startInstant = ContinuousClock.now
                    do {
                        try audio.start()
                        let timing = audio.lastStartupTiming()
                        writeDiagnostic("cycle=\(cycle) audio_start_ms=\(elapsedMilliseconds(since: startInstant)) engine_ms=\(timing?.engineStartMilliseconds ?? -1)\n")
                    } catch {
                        writeDiagnostic("cycle=\(cycle) audio_start_error=\(error)\n")
                        break
                    }
                }
                try? await Task.sleep(for: cycles == 1 ? .seconds(3) : .milliseconds(350))
                do {
                    let capture = try audio.stop()
                    let peak = diagnosticPeak.withLock { $0 }
                    writeDiagnostic("cycle=\(cycle) duration=\(capture.durationSeconds) first_buffer_ms=\(audio.firstBufferMilliseconds() ?? -1) peak=\(peak) wavBytes=\(capture.wav.count) dropped=\(capture.droppedBuffers) finalization_ms=\(capture.finalizationMilliseconds) engine_stop_ms=\(capture.engineStopMilliseconds) accumulator_ms=\(capture.accumulatorFinishMilliseconds) wav_ms=\(capture.wavEncodingMilliseconds)\n")
                    if cycle < cycles {
                        let reprepareStart = ContinuousClock.now
                        audio.prepareForNextCapture()
                        writeDiagnostic("cycle=\(cycle) background_reprepare_ms=\(elapsedMilliseconds(since: reprepareStart))\n")
                    }
                } catch {
                    writeDiagnostic("cycle=\(cycle) audio_stop_error=\(error) peak=\(diagnosticPeak.withLock { $0 })\n")
                    break
                }
            }
            NSApp.terminate(nil)
        }
    }

    private func runMeetingAudioDiagnostic() {
        let audio = MeetingAudioCaptureService()
        audio.selectInputDevice(uid: coordinator.inputDeviceUID)
        diagnosticMeetingAudio = audio
        do {
            try audio.prepare()
            try audio.start()
        } catch {
            writeDiagnostic("meeting_audio=false start_error=\(error)\n")
            NSApp.terminate(nil)
            return
        }

        Task {
            try? await Task.sleep(for: .seconds(1))
            audio.pause()
            try? await Task.sleep(for: .milliseconds(500))
            audio.resume()
            try? await Task.sleep(for: .seconds(1))
            do {
                let capture = try audio.stop()
                let fileSize = (try? capture.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let validHeader = (try? Data(contentsOf: capture.fileURL, options: .mappedIfSafe))
                    .map { $0.count >= 44 && String(decoding: $0.prefix(4), as: UTF8.self) == "RIFF" }
                    ?? false
                writeDiagnostic(
                    "meeting_audio=true duration=\(capture.durationSeconds) bytes=\(fileSize) "
                    + "dropped=\(capture.droppedBuffers) peak_buffer_bytes=\(capture.peakBufferBytes) "
                    + "valid_header=\(validHeader) pause_excluded=\(capture.durationSeconds < 2.35)\n"
                )
                try? FileManager.default.removeItem(at: capture.fileURL)
            } catch {
                writeDiagnostic("meeting_audio=false stop_error=\(error)\n")
            }
            NSApp.terminate(nil)
        }
    }

    private func runEscapeDiagnostic() {
        let hotkey = HotkeyService()
        diagnosticHotkey = hotkey
        hotkey.handler = { action in
            guard case .cancelled = action else { return }
            Task { @MainActor in
                FileHandle.standardOutput.write(Data("escape_cancelled=true\n".utf8))
                NSApp.terminate(nil)
            }
        }
        hotkey.setCancellationEnabled(true)
        guard hotkey.start() else {
            writeDiagnostic("escape_cancelled=false event_tap=false\n")
            NSApp.terminate(nil)
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else {
                writeDiagnostic("escape_cancelled=false event_creation=false\n")
                NSApp.terminate(nil)
                return
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .seconds(2))
            writeDiagnostic("escape_cancelled=false timeout=true\n")
            NSApp.terminate(nil)
        }
    }

    private func runRecordingEscapeDiagnostic() {
        coordinator.start()
        Task {
            for _ in 0..<30 where coordinator.state != .ready {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard coordinator.state == .ready else {
                writeDiagnostic("recording_escape=false readiness=\(coordinator.state)\n")
                NSApp.terminate(nil)
                return
            }
            coordinator.toggleDictation()
            try? await Task.sleep(for: .milliseconds(500))
            guard coordinator.state.isRecording, coordinator.dictationLocked else {
                writeDiagnostic("recording_escape=false recording_started=false locked=\(coordinator.dictationLocked) state=\(coordinator.state)\n")
                NSApp.terminate(nil)
                return
            }
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else {
                writeDiagnostic("recording_escape=false event_creation=false\n")
                NSApp.terminate(nil)
                return
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(500))
            writeDiagnostic("recording_escape=\(coordinator.state == .ready) state=\(coordinator.state)\n")
            NSApp.terminate(nil)
        }
    }

    private func runRecordingLockDiagnostic() {
        coordinator.start()
        Task {
            for _ in 0..<30 where coordinator.state != .ready {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard coordinator.state == .ready else {
                writeDiagnostic("recording_lock=false readiness=\(coordinator.state)\n")
                NSApp.terminate(nil)
                return
            }
            guard postLockShortcut() else {
                writeDiagnostic("recording_lock=false event_creation=false\n")
                NSApp.terminate(nil)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            let started = coordinator.state.isRecording && coordinator.dictationLocked
            guard postLockShortcut() else {
                writeDiagnostic("recording_lock=false second_event_creation=false\n")
                NSApp.terminate(nil)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            let stopped = !coordinator.state.isRecording && !coordinator.dictationLocked
            writeDiagnostic("recording_lock=\(started && stopped) started=\(started) stopped=\(stopped) state=\(coordinator.state)\n")
            NSApp.terminate(nil)
        }
    }

    private func postLockShortcut() -> Bool {
        let shortcut = coordinator.holdShortcut
        guard let keyCode = shortcut.kind == .functionKey ? UInt16(63) : shortcut.keyCode,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            return false
        }
        var flags: CGEventFlags = []
        if shortcut.lockModifiers.contains(.control) { flags.insert(.maskControl) }
        if shortcut.lockModifiers.contains(.option) { flags.insert(.maskAlternate) }
        if shortcut.lockModifiers.contains(.shift) { flags.insert(.maskShift) }
        if shortcut.lockModifiers.contains(.command) { flags.insert(.maskCommand) }
        if shortcut.lockModifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        down.flags = flags
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func runHUDDiagnostic(_ presentation: String) {
        let model = WaveHUDModel()
        let shouldAnimateSequence: Bool
        switch presentation {
        case "recording":
            shouldAnimateSequence = false
            model.state = .recording(UUID())
            model.level = 0.72
        case "preparing":
            shouldAnimateSequence = false
            model.state = .preparing(UUID())
            model.level = 0.03
        case "processing":
            shouldAnimateSequence = false
            model.state = .transcribing(UUID())
        case "no-speech":
            shouldAnimateSequence = false
            model.state = .failed(nil, .emptyTranscript)
            model.messageTone = .warning
            model.message = "No speech detected"
        case "error":
            shouldAnimateSequence = false
            model.state = .failed(nil, .unknown)
            model.messageTone = .error
            model.message = "Dictation failed"
        case "warning":
            shouldAnimateSequence = false
            model.state = .recording(UUID())
            model.level = 0.72
            model.approachingLimit = true
        case "sequence":
            shouldAnimateSequence = true
            model.state = .recording(UUID())
            model.level = 0.72
        default:
            writeDiagnostic("unknown_hud_presentation=\(presentation)\n")
            NSApp.terminate(nil)
            return
        }
        let hud = WaveHUDPanel(model: model)
        diagnosticHUDModel = model
        diagnosticHUD = hud
        hud.show()
        if shouldAnimateSequence {
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(800))
                    model.state = .transcribing(UUID())
                    try? await Task.sleep(for: .milliseconds(800))
                    model.state = .failed(nil, .emptyTranscript)
                    model.messageTone = .warning
                    model.message = "No speech detected"
                    try? await Task.sleep(for: .milliseconds(1_100))
                    model.message = nil
                    model.state = .recording(UUID())
                    model.level = 0.72
                }
            }
        }
    }

    private func runInsertionDiagnostic(_ text: String) {
        let inserter = TextInsertionService()
        Task {
            if let targetArgument = ProcessInfo.processInfo.arguments.first(where: {
                $0.hasPrefix("--diagnose-target=")
            }) {
                let bundleIdentifier = String(targetArgument.dropFirst("--diagnose-target=".count))
                NSWorkspace.shared.runningApplications
                    .first(where: { $0.bundleIdentifier == bundleIdentifier })?
                    .activate()
                try? await Task.sleep(for: .milliseconds(300))
            }
            if ProcessInfo.processInfo.arguments.contains("--diagnose-insertion-delay") {
                try? await Task.sleep(for: .seconds(3))
            }
            let destination = inserter.captureDestination()
            let insertionStart = ContinuousClock.now
            let result = await inserter.insert(text, at: destination)
            let insertionMS = elapsedMilliseconds(since: insertionStart)
            try? await Task.sleep(for: .milliseconds(250))
            let clipboardMatches = NSPasteboard.general.string(forType: .string) == text
            var targetValue: CFTypeRef?
            let targetContainsText = destination.map {
                AXUIElementCopyAttributeValue($0.element, kAXValueAttribute as CFString,
                                              &targetValue) == .success &&
                (targetValue as? String)?.contains(text) == true
            } ?? false
            func targetString(_ attribute: CFString) -> String {
                guard let destination else { return "none" }
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(destination.element, attribute, &value) == .success else {
                    return "unavailable"
                }
                return (value as? String)?.replacingOccurrences(of: " ", with: "_") ?? "nonstring"
            }
            writeDiagnostic("editableTarget=\(destination != nil) role=\(targetString(kAXRoleAttribute as CFString)) subrole=\(targetString(kAXSubroleAttribute as CFString)) title=\(targetString(kAXTitleAttribute as CFString)) description=\(targetString(kAXDescriptionAttribute as CFString)) identifier=\(targetString(kAXIdentifierAttribute as CFString)) postEvents=\(CGPreflightPostEventAccess()) strategy=\(result.strategy.rawValue) dispatched=\(result.inserted) insertion_ms=\(insertionMS) targetContainsText=\(targetContainsText) clipboardMatches=\(clipboardMatches)\n")
            if ProcessInfo.processInfo.arguments.contains("--diagnose-insertion-hold") { return }
            NSApp.terminate(nil)
        }
    }

    private func writeDiagnostic(_ message: String) {
        FileHandle.standardOutput.write(Data(message.utf8))
    }

    private func elapsedMilliseconds(since instant: ContinuousClock.Instant) -> Double {
        let duration = instant.duration(to: .now)
        return Double(duration.components.seconds) * 1_000 +
            Double(duration.components.attoseconds) / 1e15
    }

    private func wordAccuracy(reference: String, candidate: String) -> Double {
        func words(_ text: String) -> [String] {
            text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        }
        let expected = words(reference)
        let actual = words(candidate)
        guard !expected.isEmpty else { return actual.isEmpty ? 1 : 0 }
        guard !actual.isEmpty else { return 0 }
        var previous = Array(0...actual.count)
        for (row, expectedWord) in expected.enumerated() {
            var current = Array(repeating: 0, count: actual.count + 1)
            current[0] = row + 1
            for column in 1...actual.count {
                current[column] = min(
                    previous[column] + 1,
                    current[column - 1] + 1,
                    previous[column - 1] + (expectedWord == actual[column - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return max(0, 1 - Double(previous[actual.count]) / Double(expected.count))
    }
}
