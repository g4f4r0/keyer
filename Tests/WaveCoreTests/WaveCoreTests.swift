import Foundation
import os
import Testing
@testable import WaveCore

@Test func completeStateMachineFlow() throws {
    let id = UUID()
    var machine = DictationStateMachine()
    try machine.apply(.prerequisitesReady)
    try machine.apply(.begin(id))
    try machine.apply(.captureStarted(id))
    try machine.apply(.release(id))
    try machine.apply(.audioReady(id))
    try machine.apply(.transcriptionStarted(id))
    try machine.apply(.transcriptionCompleted(id))
    try machine.apply(.transcriptReady(id))
    try machine.apply(.insertionSucceeded(id))
    #expect(machine.state == .ready)
}

@Test func staleSessionIsRejected() throws {
    let active = UUID()
    var machine = DictationStateMachine(state: .recording(active))
    #expect(throws: StateTransitionError.self) {
        try machine.apply(.release(UUID()))
    }
    #expect(machine.state == .recording(active))
}

@Test func invalidTransitionDoesNotMutateState() {
    var machine = DictationStateMachine(state: .ready)
    #expect(throws: StateTransitionError.self) {
        try machine.apply(.audioReady(UUID()))
    }
    #expect(machine.state == .ready)
}

@Test func normalizationPreservesLanguageAndMeaning() {
    let input = "  ¿Mándale  el pull request  a James ?\nNo quiero 15 ; quiero 50 .  "
    #expect(TextNormalizer.normalize(input) == "¿Mándale el pull request a James?\nNo quiero 15; quiero 50.")
}

@Test func normalizationPreservesNumericSeparators() {
    #expect(TextNormalizer.normalize("Budget: 42,500 euros at 10:30. Latency: 2.5 ms.")
        == "Budget: 42,500 euros at 10:30. Latency: 2.5 ms.")
}

@Test func spokenCleanupDetectionFindsCorrectionsAndRepetition() {
    #expect(TextNormalizer.needsSpokenCleanup("No, no, I I meant to say X, Y, or Z"))
    #expect(TextNormalizer.needsSpokenCleanup("Um, send that to James"))
    #expect(TextNormalizer.needsSpokenCleanup("Like, we should ship it today"))
    #expect(TextNormalizer.needsSpokenCleanup("We should, you know, ship it today"))
    #expect(TextNormalizer.needsSpokenCleanup("No, no, quiero decir el jueves"))
    #expect(TextNormalizer.needsSpokenCleanup(
        "First update settings, second verify the microphone, and third ship the build"
    ))
    #expect(!TextNormalizer.needsSpokenCleanup("Send the pull request to James on Thursday"))
}

@Test func simpleStuttersAreCleanedLocally() {
    let cleaned = TextNormalizer.removeSimpleStutters("I I want to send send this today")
    #expect(cleaned == "I want to send this today")
    #expect(!TextNormalizer.needsSpokenCleanup(cleaned))
    #expect(TextNormalizer.needsSpokenCleanup(
        TextNormalizer.removeSimpleStutters("No no, I I meant Friday")
    ))
}

@Test func commonSpokenCorrectionsAreCleanedLocally() {
    #expect(TextNormalizer.cleanSpokenTextLocally(
        "No, no, I I meant to say send the Keyer release on Friday"
    ) == "send the Keyer release on Friday")
    #expect(TextNormalizer.cleanSpokenTextLocally(
        "No no, quiero decir envía la versión de Keyer el viernes"
    ) == "envía la versión de Keyer el viernes")
    #expect(TextNormalizer.cleanSpokenTextLocally("Um, send send this today") == "send this today")
    #expect(TextNormalizer.cleanSpokenTextLocally("We should, you know, ship today") ==
            "We should, ship today")
}

@Test func localCleanupAvoidsLongDashes() {
    #expect(TextNormalizer.cleanSpokenTextLocally("Keep this — but make it simple") ==
            "Keep this, but make it simple")
}

@Test func wavHeaderIsValid() throws {
    let wav = try WAVEncoder.encodePCM16Mono(Data([0, 0, 1, 0]))
    #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
    #expect(wav.count == 48)
}

@Test func wavHeaderCarriesSampleRateAndPayloadLength() throws {
    let wav = try WAVEncoder.encodePCM16Mono(Data(repeating: 0, count: 320), sampleRate: 16_000)
    let sampleRate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    let payloadSize = wav[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    #expect(UInt32(littleEndian: sampleRate) == 16_000)
    #expect(UInt32(littleEndian: payloadSize) == 320)
}

@Test func wavHeaderCanFinalizeAStreamedPCMFile() throws {
    let header = try WAVEncoder.header(pcmByteCount: 64_000, sampleRate: 16_000)
    #expect(header.count == 44)
    #expect(Array(header[0..<4]) == Array("RIFF".utf8))
    #expect(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self) }.littleEndian == 64_000)
}

@Test func pcmWAVRoundTripsIntoNormalizedSamples() throws {
    var pcm = Data()
    for sample in [Int16.min, 0, Int16.max] {
        var littleEndian = sample.littleEndian
        withUnsafeBytes(of: &littleEndian) { pcm.append(contentsOf: $0) }
    }
    let decoded = try PCM16WAVDecoder.decode(WAVEncoder.encodePCM16Mono(pcm))
    #expect(decoded.count == 3)
    #expect(decoded[0] == -1)
    #expect(decoded[1] == 0)
    #expect(abs(decoded[2] - 0.9999695) < 0.000001)
}

@Test func pcmWAVDecoderRejectsMalformedInput() {
    #expect(throws: PCM16WAVDecoderError.self) {
        try PCM16WAVDecoder.decode(Data("not audio".utf8))
    }
}

@Test func transcriptLanguageDetectionReturnsLanguagesInTextOrder() {
    let text = "Tomorrow we review the launch. Pero antes hablamos del presupuesto. Then we ship."
    #expect(TextNormalizer.detectedLanguages(in: text) == ["en", "es"])
}

@Test func overlappingTranscriptionChunksAreJoinedWithoutRepeatedWords() {
    let chunks = [
        "Tomorrow we review the launch plan.",
        "Launch plan. Pero antes hablamos del presupuesto.",
        "del presupuesto. Then we ship.",
    ]
    #expect(TextNormalizer.joinTranscriptionChunks(chunks) ==
            "Tomorrow we review the launch plan. Pero antes hablamos del presupuesto. Then we ship.")
}

@Test func dictationRecordingPolicyWarnsBeforeFifteenMinuteAutoFinalize() {
    #expect(DictationRecordingPolicy.maximumDurationSeconds == 900)
    #expect(DictationRecordingPolicy.warningLeadTimeSeconds == 60)
    #expect(DictationRecordingPolicy.warningStartSeconds == 840)
}

@Test func shortcutDisplaysModifiersInAppleOrder() {
    let shortcut = HoldShortcut(
        keyCode: 49,
        modifiers: [.command, .shift, .option, .control],
        keyLabel: "Space"
    )
    #expect(shortcut.displayTokens == ["⌃", "⌥", "⇧", "⌘", "Space"])
}

@Test func shortcutRoundTripsThroughPersistence() throws {
    let shortcut = HoldShortcut(keyCode: 49, modifiers: [.command, .shift], keyLabel: "Space")
    let restored = try JSONDecoder().decode(HoldShortcut.self, from: JSONEncoder().encode(shortcut))
    #expect(restored == shortcut)
    #expect(HoldShortcut.functionKey.displayTokens == ["fn"])
    #expect(HoldShortcut.functionKey.lockDisplayTokens == ["⌘", "fn"])
    #expect(restored.lockDisplayTokens == ["⌥", "⇧", "⌘", "Space"])
}

@Test func rapidTapCancellationStress() throws {
    var machine = DictationStateMachine(state: .ready)
    for _ in 0..<100_000 {
        let id = UUID()
        try machine.apply(.begin(id))
        try machine.apply(.captureStarted(id))
        try machine.apply(.release(id))
        try machine.apply(.cancel(id))
        try machine.apply(.prerequisitesReady)
    }
    #expect(machine.state == .ready)
}

@Test func terminalSessionCanReturnToReady() throws {
    let cancelledID = UUID()
    var cancelled = DictationStateMachine(state: .recording(cancelledID))
    try cancelled.apply(.cancel(cancelledID))
    #expect(!cancelled.state.hasActiveSession)
    try cancelled.apply(.prerequisitesReady)
    #expect(cancelled.state == .ready)

    let failedID = UUID()
    var failed = DictationStateMachine(state: .transcribing(failedID))
    try failed.apply(.fail(failedID, .emptyTranscript))
    #expect(!failed.state.hasActiveSession)
    try failed.apply(.prerequisitesReady)
    #expect(failed.state == .ready)
}

@Test func recordingCancellationStress() throws {
    var machine = DictationStateMachine(state: .ready)
    for _ in 0..<100_000 {
        let id = UUID()
        try machine.apply(.begin(id))
        try machine.apply(.captureStarted(id))
        try machine.apply(.cancel(id))
        try machine.apply(.prerequisitesReady)
    }
    #expect(machine.state == .ready)
}

@Test func metricsAreBoundedAndPercentilesAreHonest() {
    var metrics = MetricsBuffer(capacity: 3)
    for value in [10.0, 20, 30, 40] {
        metrics.append(.init(sessionID: UUID(), totalMilliseconds: value,
                             audioFinalizationMilliseconds: 1, audioDecodingMilliseconds: 1,
                             modelPreparationMilliseconds: 1, inferenceMilliseconds: 1,
                             normalizationMilliseconds: 1,
                             insertionMilliseconds: 1, payloadBytes: 1, audioDurationSeconds: 1,
                             droppedBuffers: 0, model: "test"))
    }
    #expect(metrics.values.count == 3)
    #expect(metrics.percentile(0.5) == 30)
    #expect(metrics.percentile(0.95) == 40)
}

@Test func transcriptArchiveRecordCreatesStableHumanReadableDocument() throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = try #require(formatter.date(from: "2026-08-22T16:30:00.123Z"))
    let id = UUID(uuidString: "3F6D608F-DBD4-4B5D-9CBA-D8EB7E44F15F")!
    let record = TranscriptArchiveRecord(
        id: id,
        kind: .dictation,
        createdAt: date,
        languages: ["en", "es"],
        originalText: "I I meant Friday",
        finalText: "I meant Friday",
        model: "whisper-small-216MB-local",
        audioDurationSeconds: 1.25,
        sourceApplication: "Messages"
    )

    #expect(record.relativeDirectoryComponents == ["Dictations", "2026", "08"])
    #expect(record.documentFilename == "2026-08-22T16-30-00.123Z.md")
    #expect(record.markdown == """
    ---
    id: "3f6d608f-dbd4-4b5d-9cba-d8eb7e44f15f"
    type: dictation
    date: "2026-08-22T16:30:00.123Z"
    languages:
      - "en"
      - "es"
    duration: 1.250
    ---

    I meant Friday

    """)
}

@Test func transcriptArchiveRecordDecodesPendingDocumentsFromBeforeLanguageMetadata() throws {
    let record = TranscriptArchiveRecord(
        id: UUID(), kind: .dictation, originalText: "Hola", finalText: "Hola",
        model: "test", audioDurationSeconds: 0.5
    )
    let encoded = try JSONEncoder().encode(record)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "languages")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(TranscriptArchiveRecord.self, from: legacyData)

    #expect(decoded.languages == ["und"])
    #expect(decoded.finalText == "Hola")
}

@Test func meetingArchiveRecordUsesSeparateFolderWithoutChangingStorageFormat() {
    let record = TranscriptArchiveRecord(
        id: UUID(), kind: .meeting, originalText: "Raw meeting", finalText: "Summary",
        model: "test", audioDurationSeconds: 120
    )
    #expect(record.relativeDirectoryComponents.first == "Meetings")
    #expect(record.markdown.contains("type: meeting"))
    #expect(record.markdown.hasSuffix("---\n\nSummary\n"))
}

@Test func transcriptArchiveWritesMarkdownLocally() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyer-archive-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let service = TranscriptArchiveService(historyURL: root)
    let date = try #require(ISO8601DateFormatter().date(from: "2026-08-22T16:30:00Z"))
    let id = UUID(uuidString: "3F6D608F-DBD4-4B5D-9CBA-D8EB7E44F15F")!
    let record = TranscriptArchiveRecord(
        id: id, kind: .dictation, createdAt: date, originalText: "raw", finalText: "Final",
        model: "test", audioDurationSeconds: 1
    )

    #expect(try await service.stage(record) == .ready)
    let document = root.appendingPathComponent("Dictations/2026/08")
        .appendingPathComponent(record.documentFilename)
    #expect(FileManager.default.fileExists(atPath: document.path))
    let markdown = try String(contentsOf: document, encoding: .utf8)
    #expect(markdown.contains("type: dictation"))
    #expect(markdown.hasSuffix("---\n\nFinal\n"))
}

@Test func transcriptArchiveCreatesKindSpecificHistoryFolders() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyer-history-folders-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = TranscriptArchiveService(historyURL: root)

    let meetings = try #require(await service.documentsURL(for: .meeting))
    let dictations = try #require(await service.documentsURL(for: .dictation))

    #expect(meetings.lastPathComponent == "Meetings")
    #expect(dictations.lastPathComponent == "Dictations")
    #expect(FileManager.default.fileExists(atPath: meetings.path))
    #expect(FileManager.default.fileExists(atPath: dictations.path))
}

@Test func transcriptArchiveAvoidsTimestampFilenameCollisionsWithoutIDs() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyer-archive-collision-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = TranscriptArchiveService(historyURL: root)
    let date = Date(timeIntervalSince1970: 1_777_777_777.123)
    let first = TranscriptArchiveRecord(
        id: UUID(), kind: .dictation, createdAt: date, originalText: "First", finalText: "First",
        model: "test", audioDurationSeconds: 1
    )
    let second = TranscriptArchiveRecord(
        id: UUID(), kind: .dictation, createdAt: date, originalText: "Second", finalText: "Second",
        model: "test", audioDurationSeconds: 1
    )

    _ = try await service.stage(first)
    _ = try await service.stage(second)
    let directory = first.relativeDirectoryComponents.reduce(root) {
        $0.appendingPathComponent($1, isDirectory: true)
    }
    let filenames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(Set(filenames) == Set([
        first.documentFilename,
        first.documentFilename.replacingOccurrences(of: ".md", with: "-001.md"),
    ]))
    #expect(!filenames.contains(where: { $0.contains(first.id.uuidString.lowercased()) }))
    #expect(!filenames.contains(where: { $0.contains(second.id.uuidString.lowercased()) }))
}

@Test func meetingSummaryUsesOneStringAndActionArray() throws {
    let value = MeetingSummary(
        title: "Release review",
        summary: "We reviewed the release.\n\nThe team approved Friday's launch.",
        actions: ["James will publish the build", "Ana will update the notes"]
    )
    let restored = try JSONDecoder().decode(
        MeetingSummary.self,
        from: JSONEncoder().encode(value)
    )
    #expect(restored == value)
}

@Test func meetingLedgerParserPreservesMultilingualFactsAndTypedActions() throws {
    let parsed = try #require(MeetingLedgerParser.parse("""
    **Title: Revisión de lanzamiento**

    **Facts:**
    - Elena confirmó el lanzamiento para el 14 de octubre.
    - James said transcription stays local on the Mac.
    - Los documentos Markdown se guardan localmente.

    **Actions:**
    - Ana | Preparar las notas de versión | 12 de octubre
    - James | Publish the signed build |
    END
    """))

    #expect(parsed.title == "Revisión de lanzamiento")
    #expect(parsed.summary.contains("14 de octubre"))
    #expect(parsed.summary.contains("transcription stays local"))
    #expect(parsed.actions == [
        "Ana: Preparar las notas de versión (12 de octubre)",
        "James: Publish the signed build",
    ])
}

@Test func meetingLedgerParserRejectsMalformedAndPlaceholderActionsGenerically() throws {
    let parsed = try #require(MeetingLedgerParser.parse("""
    Title: Arbitrary planning review
    Facts:
    - Priya approved 913 widgets for the northern site.
    Actions:
    - Priya | Order 913 widgets | Tuesday
    - Kai | Publish the notes | No deadline
    - Morgan | N/A | N/A
    - Missing separators
    - | Empty owner | Friday
    END
    """))

    #expect(parsed.summary == "Priya approved 913 widgets for the northern site.")
    #expect(parsed.actions == [
        "Priya: Order 913 widgets (Tuesday)",
        "Kai: Publish the notes",
    ])
}

@Test func meetingLedgerParserRequiresTitleAndFacts() {
    #expect(MeetingLedgerParser.parse("Actions:\n- Ana | Publish | Friday") == nil)
    #expect(MeetingLedgerParser.parse("Title: Empty\nActions:\n- Ana | Publish | Friday") == nil)
}

@Test func meetingLedgerGroundingRejectsInferredTaskWordingWithoutLanguageRules() {
    let transcript = """
    Elena: We agreed Keyer launches on October 14.
    Ana: Voy a preparar las notas de versión antes del viernes.
    James: I will publish the signed build tomorrow.
    """
    #expect(MeetingLedgerParser.groundedActions([
        "Elena: Confirm Keyer launch date (October 14)",
        "Ana: preparar las notas de versión (viernes)",
        "James: publish the signed build (tomorrow)",
    ], transcript: transcript) == [
        "Ana: preparar las notas de versión (viernes)",
        "James: publish the signed build (tomorrow)",
    ])
}

@Test func meetingDocumentRendersActionsBelowSummaryAndBeforeTranscript() {
    let document = MeetingDocument(
        intelligence: MeetingSummary(
            title: "Release review",
            summary: "We approved the release.",
            actions: ["James will publish the build", "Ana will update the notes"]
        ),
        transcript: "James: I will publish it."
    )
    #expect(document.markdown == """
    # Release review

    ## Summary

    We approved the release.

    - James will publish the build
    - Ana will update the notes

    ## Transcript

    James: I will publish it.
    """)
}

@Test func textChunkerHonorsBoundsAndPreservesContentOrder() {
    let input = "First sentence with context. Second sentence with more context.\n\nThird paragraph."
    let chunks = TextChunker.chunks(of: input, maximumCharacters: 36)
    #expect(chunks.count == 3)
    #expect(chunks.allSatisfy { $0.count <= 36 })
    #expect(chunks.joined(separator: " ").contains("First sentence with context."))
    #expect(chunks.joined(separator: " ").contains("Third paragraph."))
}

@Test func cleanupPipelineFallsBackAndReportsTheProvider() async throws {
    let unavailable = MockCleanupProvider(
        identifier: "unavailable",
        availability: .unavailable("not ready"),
        output: "unused"
    )
    let fallback = MockCleanupProvider(
        identifier: "fallback",
        availability: .available,
        output: "Ship Keyer Friday"
    )
    let pipeline = TextCleanupPipeline(providers: [unavailable, fallback])
    let result = try await pipeline.process(TextCleanupRequest(text: "Um, ship Keyer Friday"))
    #expect(result.text == "Ship Keyer Friday")
    #expect(result.provider.identifier == "fallback")
}

@Test func cleanupPipelineUnloadsAProviderWhenCancelled() async {
    let events = PipelineEventLog()
    let pipeline = TextCleanupPipeline(providers: [CancellingCleanupProvider(events: events)])
    var wasCancelled = false
    do {
        _ = try await pipeline.process(TextCleanupRequest(text: "Cancel this"))
    } catch is CancellationError {
        wasCancelled = true
    } catch {}
    #expect(wasCancelled)
    #expect(await events.values() == ["cleanup-unload"])
}

@Test func meetingPipelineNormalizesGeneratedActions() async throws {
    let provider = MockMeetingSummaryProvider(
        summary: MeetingSummary(
            title: "  Launch review  ",
            summary: "  The launch is approved.  ",
            actions: ["- Publish the build", " • Update the notes ", ""]
        )
    )
    let pipeline = MeetingSummaryPipeline(providers: [provider])
    let result = try await pipeline.process(MeetingSummaryRequest(
        transcript: "The launch is approved",
        languages: ["en"],
        durationSeconds: 60
    ))
    #expect(result.value.title == "Launch review")
    #expect(result.value.summary == "The launch is approved.")
    #expect(result.value.actions == ["Publish the build", "Update the notes"])
}

@Test func meetingProcessingRunsModelsSequentiallyEndToEnd() async throws {
    let events = PipelineEventLog()
    let stages = OSAllocatedUnfairLock(initialState: [MeetingProcessingStage]())
    let transcription = SpeechTranscription(
        text: "We approved Friday. James will publish the build.",
        languages: ["en"],
        timing: SpeechTranscriptionTiming(
            audioDecodingMilliseconds: 1,
            modelPreparationMilliseconds: 2,
            inferenceMilliseconds: 3,
            audioSegmentCount: 1
        )
    )
    let transcriber = MockSpeechTranscriptionProvider(transcription: transcription, events: events)
    let summarizerProvider = MockMeetingSummaryProvider(
        summary: MeetingSummary(
            title: "Friday launch",
            summary: "The release was approved for Friday.",
            actions: ["James will publish the build"]
        ),
        events: events
    )
    let pipeline = MeetingProcessingPipeline(
        transcriber: transcriber,
        summarizer: MeetingSummaryPipeline(providers: [summarizerProvider])
    )
    let result = try await pipeline.process(
        fileURL: URL(fileURLWithPath: "/tmp/keyer-meeting-fixture.wav"),
        durationSeconds: 60,
        onStage: { stage in stages.withLock { $0.append(stage) } }
    )

    #expect(result.document.markdown.contains("# Friday launch"))
    #expect(result.document.markdown.contains("- James will publish the build"))
    #expect(result.document.markdown.hasSuffix(transcription.text))
    #expect(stages.withLock { $0 } == [.transcribing, .summarizing])
    #expect(await events.values() == [
        "speech-transcribe",
        "speech-unload",
        "summary-prepare",
        "summary-generate",
        "summary-unload",
    ])

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyer-meeting-pipeline-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = TranscriptArchiveService(historyURL: root)
    let record = result.archiveRecord(id: UUID())
    #expect(try await archive.stage(record) == .ready)
    let documentURL = (record.relativeDirectoryComponents + [record.documentFilename]).reduce(root) {
        $0.appendingPathComponent($1)
    }
    let archived = try String(contentsOf: documentURL, encoding: .utf8)
    #expect(archived.contains("type: meeting"))
    #expect(archived.contains("# Friday launch"))
    #expect(archived.contains("## Transcript"))
    #expect(archived.hasSuffix(transcription.text + "\n"))
}

@Test func meetingArchiveAlwaysSavesTheRawTranscription() {
    let rawTranscript = "Ana: Ship the signed build Friday.\nJames: I will publish it."
    let summary = MeetingSummary(
        title: "Release review",
        summary: "The team approved the release.",
        actions: ["James will publish the build"]
    )
    let result = MeetingProcessingResult(
        transcription: SpeechTranscription(
            text: rawTranscript,
            languages: ["en"],
            timing: SpeechTranscriptionTiming(
                audioDecodingMilliseconds: 1,
                modelPreparationMilliseconds: 2,
                inferenceMilliseconds: 3,
                audioSegmentCount: 1
            )
        ),
        transcriptionProvider: ModelProviderDescriptor(
            identifier: "speech",
            displayName: "Speech"
        ),
        intelligence: MeetingSummaryResult(
            value: summary,
            provider: ModelProviderDescriptor(identifier: "summary", displayName: "Summary")
        ),
        document: MeetingDocument(
            intelligence: summary,
            transcript: "This incorrect presentation transcript must never be archived"
        ),
        durationSeconds: 60
    )

    let archived = result.archiveRecord(id: UUID()).markdown
    #expect(archived.contains("## Transcript\n\n\(rawTranscript)"))
    #expect(!archived.contains("incorrect presentation transcript"))
}

private actor MockCleanupProvider: TextCleanupProvider {
    nonisolated let descriptor: ModelProviderDescriptor
    private let providerAvailability: ModelProviderAvailability
    private let output: String

    init(identifier: String, availability: ModelProviderAvailability, output: String) {
        descriptor = ModelProviderDescriptor(identifier: identifier, displayName: identifier)
        providerAvailability = availability
        self.output = output
    }

    func availability() -> ModelProviderAvailability { providerAvailability }
    func prepare() {}
    func clean(_ request: TextCleanupRequest) -> String { output }
    func unload() {}
}

private actor CancellingCleanupProvider: TextCleanupProvider {
    nonisolated let descriptor = ModelProviderDescriptor(
        identifier: "cancelling-cleanup",
        displayName: "Cancelling cleanup"
    )
    private let events: PipelineEventLog

    init(events: PipelineEventLog) {
        self.events = events
    }

    func availability() -> ModelProviderAvailability { .available }
    func prepare() {}
    func clean(_ request: TextCleanupRequest) throws -> String { throw CancellationError() }
    func unload() async { await events.append("cleanup-unload") }
}

private actor PipelineEventLog {
    private var events: [String] = []

    func append(_ event: String) { events.append(event) }
    func values() -> [String] { events }
}

private actor MockSpeechTranscriptionProvider: SpeechTranscriptionProvider {
    nonisolated let descriptor = ModelProviderDescriptor(
        identifier: "mock-speech",
        displayName: "Mock speech"
    )
    private let transcription: SpeechTranscription
    private let events: PipelineEventLog

    init(transcription: SpeechTranscription, events: PipelineEventLog) {
        self.transcription = transcription
        self.events = events
    }

    func prepare() async throws {}

    func transcribe(wav: Data) async throws -> SpeechTranscription {
        await events.append("speech-transcribe")
        return transcription
    }

    func transcribe(fileURL: URL) async throws -> SpeechTranscription {
        await events.append("speech-transcribe")
        return transcription
    }

    func unload() async {
        await events.append("speech-unload")
    }
}

private actor MockMeetingSummaryProvider: MeetingSummaryProvider {
    nonisolated let descriptor = ModelProviderDescriptor(
        identifier: "mock-summary",
        displayName: "Mock summary"
    )
    private let summary: MeetingSummary
    private let events: PipelineEventLog?

    init(summary: MeetingSummary, events: PipelineEventLog? = nil) {
        self.summary = summary
        self.events = events
    }

    func availability() -> ModelProviderAvailability { .available }

    func prepare() async {
        await events?.append("summary-prepare")
    }

    func summarize(_ request: MeetingSummaryRequest) async -> MeetingSummary {
        await events?.append("summary-generate")
        return summary
    }

    func unload() async {
        await events?.append("summary-unload")
    }
}
