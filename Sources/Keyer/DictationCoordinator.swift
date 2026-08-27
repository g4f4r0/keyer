import AppKit
import Combine
import Foundation
import os
import ServiceManagement
import WaveCore

@MainActor
final class DictationCoordinator: ObservableObject {
    var canBeginDictation: () -> Bool = { true }
    var providerReady: () -> Bool = { true }
    var meetingToggleHandler: () -> Void = {}

    @Published private(set) var state: WaveState = .launching
    @Published private(set) var microphoneGranted = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var hotkeyOperational = false
    @Published private(set) var dictationLocked = false
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published var holdShortcut: HoldShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(holdShortcut) {
                UserDefaults.standard.set(data, forKey: "hold-shortcut")
            }
            hotkey.updateBinding(holdShortcut)
        }
    }
    @Published var inputDeviceUID: String {
        didSet {
            UserDefaults.standard.set(inputDeviceUID, forKey: "input-device-uid")
            audio.selectInputDevice(uid: inputDeviceUID)
            prewarmAudioIfPossible()
        }
    }
    @Published var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: "show-dock-icon")
            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        }
    }
    @Published var cleanUpSpokenText: Bool {
        didSet { UserDefaults.standard.set(cleanUpSpokenText, forKey: "clean-up-spoken-text") }
    }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published private(set) var launchAtLoginMessage = ""

    private var machine = DictationStateMachine()
    private let speechTranscriber: any SpeechTranscriptionProvider
    private let textCleanup: TextCleanupPipeline
    private let audio = AudioCaptureService()
    private let hotkey = HotkeyService()
    private let permissions = PermissionService()
    private let inserter = TextInsertionService()
    private let transcriptStore: RemoteTranscriptStore
    private let hudModel = WaveHUDModel()
    private lazy var hud = WaveHUDPanel(model: hudModel)
    private var destination: TextInsertionService.Destination?
    private var activeTask: Task<Void, Never>?
    private var transientHUDTask: Task<Void, Never>?
    private var modelPreparationTask: Task<Void, Error>?
    private var recordingLimitWarningTask: Task<Void, Never>?
    private var hotkeyWatchdog: Task<Void, Never>?
    private var sessionStartedAt: ContinuousClock.Instant?
    private var signpostIDs: [UUID: OSSignpostID] = [:]
    private let performanceLog = OSLog(subsystem: "com.keyer.app", category: "pipeline")
    private let logger = Logger(subsystem: "com.keyer.app", category: "app")
    private let levelRelay = LevelRelay()
    private(set) var metrics = MetricsBuffer()

    init(
        speechTranscriber: any SpeechTranscriptionProvider,
        textCleanup: TextCleanupPipeline,
        transcriptStore: RemoteTranscriptStore
    ) {
        self.speechTranscriber = speechTranscriber
        self.textCleanup = textCleanup
        self.transcriptStore = transcriptStore
        holdShortcut = Self.savedShortcut()
        inputDeviceUID = UserDefaults.standard.string(forKey: "input-device-uid") ?? ""
        showDockIcon = UserDefaults.standard.bool(forKey: "show-dock-icon")
        cleanUpSpokenText = UserDefaults.standard.object(forKey: "clean-up-spoken-text") as? Bool ?? true
        refreshLaunchAtLoginStatus()
    }

    func start() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        _ = hud
        audio.selectInputDevice(uid: inputDeviceUID)
        refreshInputDevices()
        hotkey.handler = { [weak self] action in
            MainActor.assumeIsolated { self?.handle(action) }
        }
        audio.onLevel = { [weak self] level in self?.levelRelay.offer(level) }
        audio.onLimitReached = { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishDictation(reachedLimit: true)
            }
        }
        levelRelay.handler = { [weak self] level in
            Task { @MainActor in self?.hudModel.level = level }
        }
        hotkey.updateBinding(holdShortcut)
        hotkeyOperational = hotkey.start()
        startHotkeyWatchdog()
        refreshReadiness()
        Task(priority: .utility) { [speechTranscriber] in
            try? await speechTranscriber.prepare()
        }
    }

    func stop() {
        activeTask?.cancel()
        transientHUDTask?.cancel()
        transientHUDTask = nil
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        recordingLimitWarningTask?.cancel()
        recordingLimitWarningTask = nil
        hotkeyWatchdog?.cancel()
        hotkeyWatchdog = nil
        audio.cancel()
        hotkey.stop()
    }

    func toggleDictation() {
        if case .recording = state {
            dictationLocked = false
            finishDictation(reachedLimit: false)
        } else if state == .ready, canBeginDictation() {
            dictationLocked = true
            beginDictation()
        }
    }

    func prepareForMeetingProcessing() async {
        guard !state.hasActiveSession else { return }
        await speechTranscriber.unload()
        await textCleanup.unload()
    }

    func requestMicrophonePermission() async {
        _ = await permissions.requestMicrophone()
        refreshReadiness()
    }

    func refreshInputDevices() {
        inputDevices = AudioInputDevices.available()
    }

    func requestAccessibilityPermission() {
        permissions.requestAccessibility()
        refreshReadiness()
    }


    func requestInputMonitoringPermission() {
        if !permissions.requestInputMonitoring() {
            permissions.openInputMonitoringSettings()
        }
        refreshReadiness()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                switch service.status {
                case .enabled, .requiresApproval:
                    break
                default:
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            refreshLaunchAtLoginStatus()
            launchAtLoginMessage = launchAtLoginNeedsApproval
                ? "Approval is required in System Settings"
                : ""
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginMessage = "Couldn’t update the login item"
            logger.error("Launch-at-login update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        launchAtLoginNeedsApproval = status == .requiresApproval
        if !launchAtLoginNeedsApproval, launchAtLoginMessage == "Approval is required in System Settings" {
            launchAtLoginMessage = ""
        }
    }

    func refreshReadiness() {
        microphoneGranted = permissions.microphone == .granted
        accessibilityGranted = permissions.accessibility == .granted
        inputMonitoringGranted = permissions.inputMonitoring == .granted
        do {
            if !microphoneGranted || !accessibilityGranted || !inputMonitoringGranted || !hotkeyOperational {
                try machine.apply(.permissionsMissing)
            } else if !machine.state.hasActiveSession, machine.state != .ready {
                try machine.apply(.prerequisitesReady)
            }
            publishState()
            if accessibilityGranted && inputMonitoringGranted {
                hotkeyOperational = hotkey.start()
            }
            prewarmAudioIfPossible()
        } catch { logger.error("Readiness transition rejected") }
    }

    private func prewarmAudioIfPossible() {
        guard microphoneGranted else { return }
        Task.detached(priority: .utility) { [audio] in try? audio.prepare() }
    }

    private func startHotkeyWatchdog() {
        hotkeyWatchdog?.cancel()
        hotkeyWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                let operational = self.hotkey.start()
                if self.hotkeyOperational != operational {
                    self.hotkeyOperational = operational
                    self.refreshReadiness()
                }
            }
        }
    }

    private func handle(_ action: HotkeyService.Action) {
        switch action {
        case .pressed:
            guard !dictationLocked else { return }
            beginDictation()
        case .released:
            guard !dictationLocked else { return }
            finishDictation(reachedLimit: false)
        case .lockToggled:
            toggleDictationLock()
        case .meetingToggled:
            meetingToggleHandler()
        case .cancelled: cancelRecording()
        }
    }

    private func toggleDictationLock() {
        if dictationLocked {
            dictationLocked = false
            finishDictation(reachedLimit: false)
        } else if state == .ready {
            dictationLocked = true
            beginDictation()
        } else if state.isRecording {
            dictationLocked = true
        }
    }

    private func cancelRecording() {
        guard case let .recording(id) = state else { return }
        event("escapeCancelled", id: id)
        cancelActive(id: id)
    }

    private func beginDictation() {
        guard state == .ready, canBeginDictation() else { return }
        guard providerReady() else {
            showTransientMessage("Add an OpenRouter key", tone: .warning)
            return
        }
        transientHUDTask?.cancel()
        transientHUDTask = nil
        let id = UUID()
        let signpostID = OSSignpostID(log: performanceLog)
        signpostIDs[id] = signpostID
        event("hotkeyReceived", id: id)
        sessionStartedAt = .now
        do {
            try machine.apply(.begin(id))
            event("recordingRequested", id: id)
            if hudModel.message != nil { hud.hide() }
            hudModel.message = nil
            hudModel.approachingLimit = false
            publishState()
            hud.showRecording()
            event("hudPresented", id: id)
            try audio.start()
            event("audioEngineStarted", id: id)
            try machine.apply(.captureStarted(id))
            publishState()
            destination = inserter.captureDestination()
            event("destinationCaptured", id: id)
            modelPreparationTask = Task(priority: .userInitiated) { [speechTranscriber] in
                try await speechTranscriber.prepare()
            }
            recordingLimitWarningTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(DictationRecordingPolicy.warningStartSeconds))
                } catch {
                    return
                }
                guard let self, case let .recording(activeID) = self.state, activeID == id else { return }
                self.hudModel.approachingLimit = true
            }
        } catch {
            audio.cancel()
            fail(id: id, error: error)
        }
    }

    private func finishDictation(reachedLimit: Bool) {
        guard case let .recording(id) = state else { return }
        dictationLocked = false
        if reachedLimit {
            event("recordingLimitReached", id: id)
        } else {
            event("keyReleaseReceived", id: id)
        }
        do {
            try machine.apply(.release(id))
        } catch { return }
        recordingLimitWarningTask?.cancel()
        recordingLimitWarningTask = nil

        let stopTask = Task.detached(priority: .userInitiated) { [audio] in try audio.stop() }

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let captured = try await stopTask.value
                guard self.machine.state.sessionID == id else { return }
                Task.detached(priority: .utility) { [audio] in audio.prepareForNextCapture() }
                self.event("audioEngineStopped", id: id)
                self.event("wavReady", id: id)
                try self.machine.apply(.audioReady(id))
                try await self.modelPreparationTask?.value
                try self.machine.apply(.transcriptionStarted(id))
                self.publishState()
                self.event("transcriptionStarted", id: id)
                let result = try await self.speechTranscriber.transcribe(wav: captured.wav)
                let resultModel = result.model ?? self.speechTranscriber.descriptor.identifier
                guard self.machine.state.sessionID == id else { return }
                self.event("transcriptReceived", id: id)
                try self.machine.apply(.transcriptionCompleted(id))
                self.publishState()
                let normalizationStart = ContinuousClock.now
                let normalizedTranscript = TextNormalizer.normalize(result.text)
                let transcript: String
                if self.cleanUpSpokenText,
                   TextNormalizer.needsSpokenCleanup(normalizedTranscript) {
                    do {
                        transcript = try await self.textCleanup.process(TextCleanupRequest(
                            text: normalizedTranscript,
                            languages: result.languages
                        )).text
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        transcript = normalizedTranscript
                        self.logger.notice("Text cleanup unavailable; delivering the raw transcript")
                    }
                } else {
                    transcript = normalizedTranscript
                }
                let normalizationMS = self.elapsedMS(since: normalizationStart)
                guard !transcript.isEmpty else { throw CloudProviderError.invalidResponse }
                self.event("normalizationCompleted", id: id)
                try self.machine.apply(.transcriptReady(id))
                let archiveRecord = TranscriptArchiveRecord(
                    id: id,
                    kind: .dictation,
                    languages: TextNormalizer.detectedLanguages(
                        in: transcript,
                        fallback: result.languages
                    ),
                    originalText: result.text,
                    finalText: transcript,
                    model: resultModel,
                    audioDurationSeconds: captured.durationSeconds
                )
                try await self.transcriptStore.sync(archiveRecord)
                let insertionStart = ContinuousClock.now
                self.event("insertionStarted", id: id)
                let insertion = await self.inserter.insert(transcript, at: self.destination)
                let insertionMS = self.elapsedMS(since: insertionStart)
                if insertion.inserted {
                    try self.machine.apply(.insertionSucceeded(id))
                    self.event("pasteDispatched", id: id)
                } else {
                    try self.machine.apply(.insertionNeedsRecovery(id))
                    try self.machine.apply(.recovered(id))
                    self.showTransientMessage("Copied to clipboard", tone: .warning)
                }
                let total = self.sessionStartedAt.map(self.elapsedMS(since:)) ?? 0
                self.metrics.append(.init(sessionID: id, totalMilliseconds: total,
                                          audioFinalizationMilliseconds: captured.finalizationMilliseconds,
                                          audioDecodingMilliseconds: result.timing.audioDecodingMilliseconds,
                                          modelPreparationMilliseconds: result.timing.modelPreparationMilliseconds,
                                          inferenceMilliseconds: result.timing.inferenceMilliseconds,
                                          normalizationMilliseconds: normalizationMS,
                                          insertionMilliseconds: insertionMS,
                                          payloadBytes: captured.wav.count,
                                          audioDurationSeconds: captured.durationSeconds,
                                          droppedBuffers: captured.droppedBuffers,
                                          model: resultModel))
                self.complete(id: id)
            } catch AudioCaptureError.tooShort {
                self.fail(id: id, error: AudioCaptureError.tooShort)
            } catch is CancellationError {
                self.cancelActive(id: id)
            } catch {
                self.fail(id: id, error: error)
            }
        }
        publishState()
    }

    private func complete(id: UUID) {
        dictationLocked = false
        destination = nil
        activeTask = nil
        modelPreparationTask = nil
        recordingLimitWarningTask?.cancel()
        recordingLimitWarningTask = nil
        hudModel.approachingLimit = false
        if hudModel.message == nil {
            hud.hide()
            event("hudDismissed", id: id)
        }
        event("sessionReleased", id: id)
        signpostIDs[id] = nil
        publishState()
    }

    private func cancelActive(id: UUID) {
        dictationLocked = false
        audio.cancel()
        try? machine.apply(.cancel(id))
        hud.hide()
        transientHUDTask?.cancel()
        transientHUDTask = nil
        hudModel.message = nil
        hudModel.approachingLimit = false
        destination = nil
        activeTask = nil
        modelPreparationTask = nil
        recordingLimitWarningTask?.cancel()
        recordingLimitWarningTask = nil
        signpostIDs[id] = nil
        refreshReadiness()
    }

    private func fail(id: UUID, error: Error) {
        dictationLocked = false
        audio.cancel()
        try? machine.apply(.fail(id, failure(for: error)))
        publishState()
        let failure = failure(for: error)
        showTransientMessage(userMessage(for: failure), tone: messageTone(for: failure))
        destination = nil
        activeTask = nil
        modelPreparationTask = nil
        recordingLimitWarningTask?.cancel()
        recordingLimitWarningTask = nil
        hudModel.approachingLimit = false
        signpostIDs[id] = nil
    }

    private func publishState() {
        state = machine.state
        hudModel.state = state
        hotkey.setCancellationEnabled(state.isRecording)
        if state.hasActiveSession { hudModel.message = nil }
    }

    private func showTransientError(_ message: String) {
        showTransientMessage(message, tone: .error)
    }

    private func showTransientMessage(_ message: String, tone: WaveHUDModel.MessageTone) {
        let cleanMessage = message.withoutTerminalPeriods
        transientHUDTask?.cancel()
        hudModel.messageTone = tone
        hudModel.message = cleanMessage
        hud.show()
        transientHUDTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.hudModel.message == cleanMessage else { return }
            self.hud.hide()
            self.hudModel.message = nil
            self.transientHUDTask = nil
            self.refreshReadiness()
        }
    }

    private func failure(for error: Error) -> WaveFailure {
        switch error {
        case AudioCaptureError.tooShort: .recordingTooShort
        case AudioCaptureError.droppedAudio: .droppedAudio
        case CloudProviderError.missingAPIKey, CloudProviderError.unauthorized: .offline
        case CloudProviderError.invalidResponse: .emptyTranscript
        default: .unknown
        }
    }

    private func userMessage(for error: Error) -> String {
        userMessage(for: failure(for: error))
    }

    private func userMessage(for failure: WaveFailure) -> String {
        switch failure {
        case .recordingTooShort: "Recording too short"
        case .droppedAudio: "Audio interrupted"
        case .offline: "Check your OpenRouter key"
        case .emptyTranscript: "No speech detected"
        default: "Dictation failed"
        }
    }

    private func messageTone(for failure: WaveFailure) -> WaveHUDModel.MessageTone {
        switch failure {
        case .recordingTooShort, .emptyTranscript, .insertionFailed: .warning
        default: .error
        }
    }

    private func event(_ name: StaticString, id: UUID) {
        guard let signpostID = signpostIDs[id] else { return }
        os_signpost(.event, log: performanceLog, name: name, signpostID: signpostID)
    }

    private func elapsedMS(since instant: ContinuousClock.Instant) -> Double {
        let duration = instant.duration(to: .now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func savedShortcut() -> HoldShortcut {
        guard let data = UserDefaults.standard.data(forKey: "hold-shortcut"),
              let shortcut = try? JSONDecoder().decode(HoldShortcut.self, from: data) else {
            return .functionKey
        }
        return shortcut
    }
}

private extension String {
    var withoutTerminalPeriods: String {
        var result = trimmingCharacters(in: .whitespacesAndNewlines)
        while result.last == "." { result.removeLast() }
        return result
    }
}

private final class LevelRelay: @unchecked Sendable {
    private struct State: Sendable { var lastNanoseconds: UInt64 = 0 }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    var handler: (@Sendable (Float) -> Void)?

    func offer(_ level: Float) {
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldSend = lock.withLockIfAvailable { state -> Bool in
            guard now &- state.lastNanoseconds >= 33_333_333 else { return false }
            state.lastNanoseconds = now
            return true
        } ?? false
        if shouldSend { handler?(level) }
    }
}
