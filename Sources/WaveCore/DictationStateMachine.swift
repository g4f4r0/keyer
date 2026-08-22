import Foundation

public enum WaveState: Equatable, Sendable {
    case launching
    case missingPermissions
    case ready
    case preparing(UUID)
    case recording(UUID)
    case finalizingAudio(UUID)
    case preparingTranscription(UUID)
    case transcribing(UUID)
    case inserting(UUID)
    case recovering(UUID)
    case cancelled(UUID?)
    case failed(UUID?, WaveFailure)

    public var sessionID: UUID? {
        switch self {
        case let .preparing(id), let .recording(id), let .finalizingAudio(id),
             let .preparingTranscription(id), let .transcribing(id), let .inserting(id),
             let .recovering(id): id
        case let .cancelled(id), let .failed(id, _): id
        default: nil
        }
    }

    public var hasActiveSession: Bool {
        switch self {
        case .preparing, .recording, .finalizingAudio, .preparingTranscription,
             .transcribing, .inserting, .recovering:
            true
        default:
            false
        }
    }

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

public enum WaveFailure: String, Equatable, Sendable {
    case microphoneUnavailable
    case recordingTooShort
    case droppedAudio
    case offline
    case emptyTranscript
    case insertionFailed
    case cancelled
    case unknown
}

public enum WaveEvent: Equatable, Sendable {
    case permissionsMissing
    case prerequisitesReady
    case begin(UUID)
    case captureStarted(UUID)
    case release(UUID)
    case audioReady(UUID)
    case transcriptionStarted(UUID)
    case transcriptionCompleted(UUID)
    case transcriptReady(UUID)
    case insertionSucceeded(UUID)
    case insertionNeedsRecovery(UUID)
    case recovered(UUID)
    case cancel(UUID?)
    case fail(UUID?, WaveFailure)
    case reset
}

public enum StateTransitionError: Error, Equatable, Sendable {
    case invalid(from: WaveState, event: WaveEvent)
    case stale(expected: UUID, received: UUID)
}

public struct DictationStateMachine: Sendable {
    public private(set) var state: WaveState

    public init(state: WaveState = .launching) {
        self.state = state
    }

    public mutating func apply(_ event: WaveEvent) throws {
        if let expected = state.sessionID, let received = event.sessionID, expected != received {
            throw StateTransitionError.stale(expected: expected, received: received)
        }

        let next: WaveState
        switch (state, event) {
        case (_, .permissionsMissing): next = .missingPermissions
        case (.launching, .prerequisitesReady), (.missingPermissions, .prerequisitesReady),
             (.cancelled, .prerequisitesReady), (.failed, .prerequisitesReady): next = .ready
        case (.ready, let .begin(id)): next = .preparing(id)
        case (.preparing, let .captureStarted(id)): next = .recording(id)
        case (.recording, let .release(id)): next = .finalizingAudio(id)
        case (.finalizingAudio, let .audioReady(id)): next = .preparingTranscription(id)
        case (.preparingTranscription, let .transcriptionStarted(id)): next = .transcribing(id)
        case (.transcribing, let .transcriptionCompleted(id)): next = .inserting(id)
        case (.inserting, let .transcriptReady(id)): next = .inserting(id)
        case (.inserting, .insertionSucceeded): next = .ready
        case (.inserting, let .insertionNeedsRecovery(id)): next = .recovering(id)
        case (.recovering, .recovered): next = .ready
        case (_, let .cancel(id)): next = .cancelled(id)
        case (_, let .fail(id, failure)): next = .failed(id, failure)
        case (.ready, .reset), (.cancelled, .reset), (.failed, .reset): next = .ready
        default: throw StateTransitionError.invalid(from: state, event: event)
        }
        state = next
    }
}

private extension WaveEvent {
    var sessionID: UUID? {
        switch self {
        case let .begin(id), let .captureStarted(id), let .release(id), let .audioReady(id),
             let .transcriptionStarted(id), let .transcriptionCompleted(id), let .transcriptReady(id),
             let .insertionSucceeded(id), let .insertionNeedsRecovery(id), let .recovered(id): id
        case let .cancel(id), let .fail(id, _): id
        default: nil
        }
    }
}
