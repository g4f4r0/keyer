import AppKit
import ApplicationServices
import Combine
import Foundation
import os
import WaveCore

enum MeetingState: Equatable, Sendable {
    case idle
    case suggested
    case recording
    case paused
    case transcribing
    case summarizing
    case saved(URL?)
    case failed(String)

    var isCapturing: Bool {
        self == .recording || self == .paused
    }

    var isProcessing: Bool {
        self == .transcribing || self == .summarizing
    }

    var showsControls: Bool { self != .idle }
}

@MainActor
final class MeetingCoordinator: ObservableObject {
    @Published private(set) var state: MeetingState = .idle
    @Published private(set) var elapsedSeconds = 0
    @Published var showControls: Bool {
        didSet {
            UserDefaults.standard.set(showControls, forKey: "show-meeting-controls")
            refreshPanel()
        }
    }
    @Published var suggestMeetings: Bool {
        didSet {
            UserDefaults.standard.set(suggestMeetings, forKey: "suggest-meetings")
            if !suggestMeetings, state == .suggested { setState(.idle) }
        }
    }

    var canStart: () -> Bool = { true }
    var providerReady: () -> Bool = { true }
    var inputDeviceUID: () -> String = { "" }
    var beforeProcessing: () async -> Void = {}

    private let audio = MeetingAudioCaptureService()
    private let archive = TranscriptArchiveService()
    private let pipeline: MeetingProcessingPipeline
    private lazy var controlsPanel = MeetingControlsPanel(coordinator: self)
    private var timerTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private static let savedVisibility = Duration.seconds(8)
    private static let failureVisibility = Duration.seconds(10)
    private var activeStartedAt: Date?
    private var accumulatedSeconds: TimeInterval = 0
    private var meetingCreatedAt: Date?
    private var retryCapture: CapturedMeetingAudio?
    private var dismissedCandidate: String?
    private var lastCandidate: String?
    private var candidateHits = 0
    private let logger = Logger(subsystem: "com.keyer.app", category: "meeting")

    var canRetry: Bool { retryCapture != nil }

    init(
        transcriber: any SpeechTranscriptionProvider,
        summarizer: any MeetingSummaryProvider
    ) {
        pipeline = MeetingProcessingPipeline(
            transcriber: transcriber,
            summarizer: MeetingSummaryPipeline(providers: [summarizer])
        )
        showControls = UserDefaults.standard.object(forKey: "show-meeting-controls") as? Bool ?? true
        suggestMeetings = UserDefaults.standard.object(forKey: "suggest-meetings") as? Bool ?? true
    }

    func start() {
        _ = controlsPanel
        audio.onLimitReached = { [weak self] in
            Task { @MainActor [weak self] in self?.stopAndProcess() }
        }
        startDetection()
    }

    func stop() {
        timerTask?.cancel()
        processingTask?.cancel()
        detectionTask?.cancel()
        completionTask?.cancel()
        audio.cancel()
        if let url = retryCapture?.fileURL { try? FileManager.default.removeItem(at: url) }
        retryCapture = nil
        controlsPanel.hide()
    }

    func startMeeting() {
        guard state == .idle || state == .suggested, canStart() else { return }
        guard providerReady() else {
            fail("Add an OpenRouter key")
            return
        }
        completionTask?.cancel()
        dismissedCandidate = lastCandidate
        audio.selectInputDevice(uid: inputDeviceUID())
        do {
            try audio.start()
            meetingCreatedAt = .now
            accumulatedSeconds = 0
            elapsedSeconds = 0
            activeStartedAt = .now
            setState(.recording)
            startElapsedTimer()
        } catch {
            fail("Couldn’t start recording")
        }
    }

    func toggleMeeting() {
        if state.isCapturing {
            stopAndProcess()
        } else if state == .idle || state == .suggested {
            startMeeting()
        }
    }

    func pause() {
        guard state == .recording else { return }
        updateAccumulatedTime()
        activeStartedAt = nil
        audio.pause()
        setState(.paused)
    }

    func resume() {
        guard state == .paused else { return }
        activeStartedAt = .now
        audio.resume()
        setState(.recording)
    }

    func stopAndProcess() {
        guard state.isCapturing else { return }
        updateAccumulatedTime()
        activeStartedAt = nil
        timerTask?.cancel()
        setState(.transcribing)
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await Task.detached(priority: .userInitiated) { [audio] in
                    try audio.stop()
                }.value
                self.retryCapture = capture
                await self.process(capture)
            } catch AudioCaptureError.tooShort {
                self.fail("Meeting was too short")
            } catch {
                self.fail("Couldn’t finish recording")
            }
        }
    }

    func retry() {
        guard case .failed = state, let retryCapture else { return }
        setState(.transcribing)
        processingTask = Task { [weak self] in
            await self?.process(retryCapture)
        }
    }

    func dismissFailure() {
        guard case .failed = state else { return }
        if let url = retryCapture?.fileURL { try? FileManager.default.removeItem(at: url) }
        retryCapture = nil
        setState(.idle)
    }

    func requestDiscard() {
        guard state == .paused else { return }
        let alert = NSAlert()
        alert.messageText = "Discard this meeting?"
        alert.informativeText = "The recording will be permanently deleted"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { discard() }
    }

    func discard() {
        guard state.isCapturing else { return }
        timerTask?.cancel()
        audio.cancel()
        activeStartedAt = nil
        accumulatedSeconds = 0
        elapsedSeconds = 0
        meetingCreatedAt = nil
        setState(.idle)
    }

    func openSavedMeeting() {
        guard case let .saved(url) = state else { return }
        if let url {
            NSWorkspace.shared.open(url)
        } else {
            Task {
                if let folder = await archive.documentsURL(for: .meeting) {
                    NSWorkspace.shared.open(folder)
                }
            }
        }
        setState(.idle)
    }

    func dismissSuggestion() {
        guard state == .suggested else { return }
        dismissedCandidate = lastCandidate
        setState(.idle)
    }

    func showDiagnosticControls(_ value: String) {
        elapsedSeconds = 125
        switch value {
        case "suggested": setState(.suggested)
        case "paused": setState(.paused)
        case "transcribing": setState(.transcribing)
        case "summarizing": setState(.summarizing)
        case "saved": setState(.saved(nil))
        case "failed": setState(.failed("Meeting processing failed"))
        default: setState(.recording)
        }
    }

    private func process(_ capture: CapturedMeetingAudio) async {
        do {
            await beforeProcessing()
            let result = try await pipeline.process(
                fileURL: capture.fileURL,
                durationSeconds: capture.durationSeconds
            ) { [weak self] stage in
                Task { @MainActor [weak self] in
                    self?.setState(stage == .transcribing ? .transcribing : .summarizing)
                }
            }
            let record = result.archiveRecord(
                id: UUID(),
                createdAt: meetingCreatedAt ?? .now
            )
            _ = try await archive.stage(record)
            let documentURL = await archive.documentURL(for: record)
            try? FileManager.default.removeItem(at: capture.fileURL)
            retryCapture = nil
            setState(.saved(documentURL))
        } catch is CancellationError {
            return
        } catch {
            logger.error("Meeting processing failed: \(String(describing: error), privacy: .public)")
            fail("Meeting processing failed")
        }
    }

    private func startElapsedTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshElapsedTime()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func refreshElapsedTime() {
        let active = activeStartedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        let previousUsesHours = elapsedSeconds >= 3_600
        elapsedSeconds = max(0, Int((accumulatedSeconds + active).rounded(.down)))
        if previousUsesHours != (elapsedSeconds >= 3_600) {
            refreshPanel()
        }
    }

    private func updateAccumulatedTime() {
        if let activeStartedAt {
            accumulatedSeconds += Date.now.timeIntervalSince(activeStartedAt)
        }
        refreshElapsedTime()
    }

    private func fail(_ message: String) {
        timerTask?.cancel()
        activeStartedAt = nil
        setState(.failed(message))
    }

    private func setState(_ newState: MeetingState) {
        state = newState
        refreshPanel()
        scheduleTerminalDismissal(for: newState)
    }

    private func scheduleTerminalDismissal(for state: MeetingState) {
        completionTask?.cancel()
        completionTask = nil

        let delay: Duration
        switch state {
        case .saved:
            delay = Self.savedVisibility
        case .failed:
            delay = Self.failureVisibility
        default:
            return
        }

        completionTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.state == state else { return }
            self.completionTask = nil
            if case .failed = state {
                if let url = self.retryCapture?.fileURL {
                    try? FileManager.default.removeItem(at: url)
                }
                self.retryCapture = nil
            }
            self.state = .idle
            self.refreshPanel()
        }
    }

    private func refreshPanel() {
        if showControls, state.showsControls {
            controlsPanel.show()
        } else {
            controlsPanel.hide()
        }
    }

    private func startDetection() {
        detectionTask?.cancel()
        detectionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.checkForMeeting()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func checkForMeeting() {
        guard suggestMeetings, state == .idle, let candidate = Self.meetingCandidate() else {
            lastCandidate = nil
            candidateHits = 0
            return
        }
        guard candidate != dismissedCandidate else { return }
        if candidate == lastCandidate {
            candidateHits += 1
        } else {
            lastCandidate = candidate
            candidateHits = 1
        }
        if candidateHits >= 2 { setState(.suggested) }
    }

    private static func meetingCandidate() -> String? {
        let meetingBundleFragments = ["zoom.us", "msteams", "teams2", "webex"]
        if let match = NSWorkspace.shared.runningApplications.compactMap({ app -> String? in
            guard let id = app.bundleIdentifier?.lowercased() else { return nil }
            guard meetingBundleFragments.contains(where: id.contains) else { return nil }
            let titles = windowTitles(for: app.processIdentifier).map { $0.lowercased() }
            let looksActive = titles.contains { title in
                ["meeting", "call", "webinar"].contains(where: title.contains)
                    && !title.contains("schedule")
            }
            return looksActive ? "\(id):\(titles.joined(separator: "|"))" : nil
        }).first {
            return match
        }

        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier?.lowercased(),
              ["safari", "chrome", "chromium", "arc", "edge", "firefox"].contains(where: bundle.contains),
              let title = focusedWindowTitle(for: app.processIdentifier)?.lowercased() else { return nil }
        let meetingTitles = ["google meet", "meet.google.com", "zoom meeting", "microsoft teams", "webex"]
        guard meetingTitles.contains(where: title.contains) else { return nil }
        return "\(bundle):\(title)"
    }

    private static func focusedWindowTitle(for pid: pid_t) -> String? {
        let application = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success, let windowValue else { return nil }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            windowValue as! AXUIElement,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success else { return nil }
        return titleValue as? String
    }

    private static func windowTitles(for pid: pid_t) -> [String] {
        let application = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success, let windows = windowsValue as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window,
                kAXTitleAttribute as CFString,
                &titleValue
            ) == .success else { return nil }
            return titleValue as? String
        }
    }
}
