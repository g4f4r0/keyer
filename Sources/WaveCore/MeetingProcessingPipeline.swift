import Foundation

public enum MeetingProcessingStage: Equatable, Sendable {
    case transcribing
    case summarizing
}

public struct MeetingProcessingResult: Equatable, Sendable {
    public let transcription: SpeechTranscription
    public let transcriptionProvider: ModelProviderDescriptor
    public let intelligence: MeetingSummaryResult
    public let document: MeetingDocument
    public let durationSeconds: Double

    public init(transcription: SpeechTranscription, transcriptionProvider: ModelProviderDescriptor,
                intelligence: MeetingSummaryResult, document: MeetingDocument,
                durationSeconds: Double) {
        self.transcription = transcription
        self.transcriptionProvider = transcriptionProvider
        self.intelligence = intelligence
        self.document = document
        self.durationSeconds = durationSeconds
    }

    public func archiveRecord(id: UUID, createdAt: Date = .now) -> TranscriptArchiveRecord {
        // The transcript is archival source data, so always rebuild the saved document from
        // the raw STT result instead of trusting a separately constructed presentation value.
        let archivedDocument = MeetingDocument(
            intelligence: intelligence.value,
            transcript: transcription.text
        )
        return TranscriptArchiveRecord(
            id: id,
            kind: .meeting,
            createdAt: createdAt,
            languages: transcription.languages,
            originalText: transcription.text,
            finalText: archivedDocument.markdown,
            model: "\(transcription.model ?? transcriptionProvider.identifier)+\(intelligence.provider.identifier)",
            audioDurationSeconds: durationSeconds
        )
    }
}

public actor MeetingProcessingPipeline {
    private let transcriber: any SpeechTranscriptionProvider
    private let summarizer: MeetingSummaryPipeline

    public init(transcriber: any SpeechTranscriptionProvider, summarizer: MeetingSummaryPipeline) {
        self.transcriber = transcriber
        self.summarizer = summarizer
    }

    public func process(
        fileURL: URL,
        durationSeconds: Double,
        onStage: @Sendable (MeetingProcessingStage) -> Void = { _ in }
    ) async throws -> MeetingProcessingResult {
        onStage(.transcribing)
        let transcription: SpeechTranscription
        do {
            transcription = try await transcriber.transcribe(fileURL: fileURL)
        } catch {
            await transcriber.unload()
            throw error
        }
        await transcriber.unload()

        onStage(.summarizing)
        let intelligence: MeetingSummaryResult
        do {
            intelligence = try await summarizer.process(MeetingSummaryRequest(
                transcript: transcription.text,
                languages: transcription.languages,
                durationSeconds: durationSeconds
            ))
        } catch {
            await summarizer.unload()
            throw error
        }
        await summarizer.unload()

        return MeetingProcessingResult(
            transcription: transcription,
            transcriptionProvider: transcriber.descriptor,
            intelligence: intelligence,
            document: MeetingDocument(
                intelligence: intelligence.value,
                transcript: transcription.text
            ),
            durationSeconds: durationSeconds
        )
    }
}
