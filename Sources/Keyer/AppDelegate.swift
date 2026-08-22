import AppKit
import CoreML
import os
import SwiftUI
import WaveCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = DictationCoordinator()
    private var diagnosticAudio: AudioCaptureService?
    private var diagnosticHotkey: HotkeyService?
    private var diagnosticHUDModel: WaveHUDModel?
    private var diagnosticHUD: WaveHUDPanel?
    private var diagnosticSettingsWindow: NSWindow?
    private let diagnosticPeak = OSAllocatedUnfairLock(initialState: Float.zero)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--diagnose-model-cancellation") {
            runModelCancellationDiagnostic()
            return
        }
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
        if let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--diagnose-transcription=")
        }) {
            runTranscriptionDiagnostic(String(argument.dropFirst("--diagnose-transcription=".count)))
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--diagnose-recording-escape") {
            runRecordingEscapeDiagnostic()
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
        coordinator.start()
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
        coordinator.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator.refreshInputDevices()
        coordinator.refreshReadiness()
        coordinator.refreshLaunchAtLoginStatus()
    }

    private func runModelCancellationDiagnostic() {
        Task {
            let service = LocalTranscriptionService { _ in }
            let preparation = Task { try await service.prepare() }
            try? await Task.sleep(for: .milliseconds(100))
            let unloadStart = ContinuousClock.now
            await service.unload()
            let unloadMS = elapsedMilliseconds(since: unloadStart)
            let preparationOutcome: String
            switch await preparation.result {
            case .success:
                preparationOutcome = "success"
            case let .failure(error):
                preparationOutcome = error is CancellationError
                    ? "cancelled"
                    : "failed_\(String(describing: type(of: error)))"
            }
            let status = await service.currentStatus()
            writeDiagnostic("model_cancellation=true preparation_outcome=\(preparationOutcome) status=\(status.label.replacingOccurrences(of: " ", with: "_")) ready=\(status == .ready) unload_ms=\(unloadMS)\n")
            NSApp.terminate(nil)
        }
    }

    private func runHistoryDiagnostic() {
        Task {
            let service = TranscriptArchiveService()
            let status = await service.synchronize()
            writeDiagnostic("history_status=\(status.label) iCloud_available=\(status.isAvailable)\n")
            NSApp.terminate(nil)
        }
    }

    private func runSettingsDiagnostic() {
        coordinator.start()
        let controller = NSHostingController(rootView: SettingsView(coordinator: coordinator))
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
                let synchronized = await service.synchronize()
                let syncMS = elapsedMilliseconds(since: syncStart)
                let relativePath = (record.relativeDirectoryComponents + [record.documentFilename])
                    .joined(separator: "/")
                writeDiagnostic("history_write=true staged=\(staged.label) synchronized=\(synchronized.label) stage_ms=\(stageMS) sync_ms=\(syncMS) path=\(relativePath) id=\(record.id.uuidString.lowercased())\n")
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

    private func runTranscriptionDiagnostic(_ path: String) {
        Task {
            do {
                let fileURL = URL(fileURLWithPath: path)
                let payloadBytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let useGPU = ProcessInfo.processInfo.arguments.contains("--diagnose-encoder-gpu")
                let parallel = ProcessInfo.processInfo.arguments.first(where: {
                    $0.hasPrefix("--diagnose-parallel=")
                }).flatMap { Int($0.dropFirst("--diagnose-parallel=".count)) } ?? 4
                let dualDecode = ProcessInfo.processInfo.arguments.contains("--diagnose-dual-decode")
                let seamGapRepair = !ProcessInfo.processInfo.arguments.contains("--diagnose-no-seam-repair")
                let useDataPath = ProcessInfo.processInfo.arguments.contains("--diagnose-transcription-data")
                let service = LocalTranscriptionService(
                    statusReporter: { [weak self] status in
                        if case let .downloading(progress) = status {
                            Task { @MainActor in
                                self?.writeDiagnostic("model_download_progress=\(progress)\n")
                            }
                        }
                    },
                    encoderComputeUnits: useGPU ? .cpuAndGPU : .cpuAndNeuralEngine,
                    parallelChunkConcurrency: parallel,
                    dualDecodeArbitration: dualDecode,
                    seamGapRepair: seamGapRepair
                )
                let warmupStart = ContinuousClock.now
                try await service.prepare()
                let warmupMS = elapsedMilliseconds(since: warmupStart)
                let expected = ProcessInfo.processInfo.arguments.first(where: {
                    $0.hasPrefix("--diagnose-transcription-expected=")
                }).map { String($0.dropFirst("--diagnose-transcription-expected=".count)) }
                let runs = ProcessInfo.processInfo.arguments.first(where: {
                    $0.hasPrefix("--diagnose-transcription-runs=")
                }).flatMap { Int($0.dropFirst("--diagnose-transcription-runs=".count)) }
                    .map { max(1, min($0, 100)) } ?? 1
                for run in 1...runs {
                    let result = if useDataPath {
                        try await service.transcribe(wav: Data(contentsOf: fileURL))
                    } else {
                        try await service.transcribe(fileURL: fileURL)
                    }
                    let accuracy = expected.map { wordAccuracy(reference: $0, candidate: result.text) }
                    let wordCount = result.text.split(whereSeparator: { $0.isWhitespace }).count
                    writeDiagnostic("transcription=true run=\(run) model=\(LocalTranscriptionService.modelIdentifier) encoder=\(useGPU ? "gpu" : "ane") parallel=\(parallel) dual_decode=\(dualDecode) seam_repair=\(seamGapRepair) input=\(useDataPath ? "data" : "file") languages=\(result.languages.joined(separator: ",")) audio_segments=\(result.timing.audioSegmentCount) warmup_ms=\(run == 1 ? warmupMS : 0) inference_ms=\(result.timing.inferenceMilliseconds) audio_decode_ms=\(result.timing.audioDecodingMilliseconds) payload_bytes=\(payloadBytes) text_characters=\(result.text.count) words=\(wordCount) text_nonempty=\(!result.text.isEmpty) word_accuracy=\(accuracy ?? -1)\n")
                    if ProcessInfo.processInfo.arguments.contains("--diagnose-transcription-print-text") {
                        writeDiagnostic("transcript=\(result.text.replacingOccurrences(of: "\n", with: " "))\n")
                    }
                }
            } catch {
                writeDiagnostic("transcription=false error=\(error)\n")
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
            guard coordinator.state.isRecording else {
                writeDiagnostic("recording_escape=false recording_started=false state=\(coordinator.state)\n")
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

    private func runHUDDiagnostic(_ presentation: String) {
        let model = WaveHUDModel()
        let shouldAnimateSequence: Bool
        switch presentation {
        case "recording":
            shouldAnimateSequence = false
            model.state = .recording(UUID())
            model.level = 0.72
        case "processing":
            shouldAnimateSequence = false
            model.state = .transcribing(UUID())
        case "no-speech":
            shouldAnimateSequence = false
            model.state = .failed(nil, .emptyTranscript)
            model.message = "No speech detected"
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
