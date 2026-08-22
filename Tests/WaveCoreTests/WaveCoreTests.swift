import Foundation
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

@Test func transcriptArchiveStagesLocallyThenSynchronizesMarkdown() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyer-archive-test-\(UUID().uuidString)", isDirectory: true)
    let pending = root.appendingPathComponent("Pending", isDirectory: true)
    let cloud = root.appendingPathComponent("Cloud Documents", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let service = TranscriptArchiveService(
        localQueueURL: pending,
        cloudDocumentsURLProvider: { cloud }
    )
    let date = try #require(ISO8601DateFormatter().date(from: "2026-08-22T16:30:00Z"))
    let id = UUID(uuidString: "3F6D608F-DBD4-4B5D-9CBA-D8EB7E44F15F")!
    let record = TranscriptArchiveRecord(
        id: id, kind: .dictation, createdAt: date, originalText: "raw", finalText: "Final",
        model: "test", audioDurationSeconds: 1
    )

    #expect(try await service.stage(record) == .pending(1))
    #expect(await service.synchronize() == .synced)
    let document = cloud.appendingPathComponent("Dictations/2026/08")
        .appendingPathComponent(record.documentFilename)
    #expect(FileManager.default.fileExists(atPath: document.path))
    let markdown = try String(contentsOf: document, encoding: .utf8)
    #expect(markdown.contains("type: dictation"))
    #expect(markdown.hasSuffix("---\n\nFinal\n"))
    #expect(!FileManager.default.fileExists(atPath: cloud.appendingPathComponent(".Keyer").path))
    #expect((try? FileManager.default.contentsOfDirectory(atPath: pending.path).isEmpty) == true)
}

@Test func transcriptArchiveAvoidsTimestampFilenameCollisionsWithoutIDs() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyer-archive-collision-test-\(UUID().uuidString)", isDirectory: true)
    let pending = root.appendingPathComponent("Pending", isDirectory: true)
    let cloud = root.appendingPathComponent("Cloud Documents", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = TranscriptArchiveService(
        localQueueURL: pending,
        cloudDocumentsURLProvider: { cloud }
    )
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
    #expect(await service.synchronize() == .synced)
    let directory = first.relativeDirectoryComponents.reduce(cloud) {
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

@Test func transcriptArchiveRetainsPendingCopyWhenICloudIsUnavailable() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyer-archive-offline-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = TranscriptArchiveService(
        localQueueURL: root.appendingPathComponent("Pending", isDirectory: true),
        cloudDocumentsURLProvider: { nil }
    )
    let record = TranscriptArchiveRecord(
        id: UUID(), kind: .dictation, originalText: "raw", finalText: "Final",
        model: "test", audioDurationSeconds: 1
    )

    #expect(try await service.stage(record) == .pending(1))
    #expect(await service.synchronize() == .iCloudUnavailable(1))
}
