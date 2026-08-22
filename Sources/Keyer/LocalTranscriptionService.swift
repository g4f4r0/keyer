import CoreML
import FluidAudio
import Foundation
import os
import WaveCore

enum LocalModelStatus: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)
    case downloaded
    case preparing
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .notDownloaded: "Downloads on first use"
        case let .downloading(progress): "Downloading \(Int((progress * 100).rounded()))%"
        case .downloaded: "Downloaded"
        case .preparing: "Preparing"
        case .ready: "Ready"
        case let .failed(message): message
        }
    }

    var isDownloaded: Bool {
        switch self {
        case .downloaded, .preparing, .ready: true
        default: false
        }
    }
}

enum LocalTranscriptionError: Error, Equatable, Sendable {
    case modelDownloadFailed
    case modelLoadFailed
    case invalidAudio
    case emptyTranscript
}

struct LocalTranscriptionTiming: Sendable {
    let audioDecodingMilliseconds: Double
    let modelPreparationMilliseconds: Double
    let inferenceMilliseconds: Double
    let audioSegmentCount: Int
}

struct LocalTranscriptionResult: Sendable {
    let text: String
    let languages: [String]
    let timing: LocalTranscriptionTiming
}

actor LocalTranscriptionService {
    static let modelDisplayName = "Parakeet TDT 0.6B v3"
    static let modelIdentifier = "parakeet-tdt-0.6b-v3-int8-local"
    static let downloadSizeLabel = "about 461 MB"

    private static let version = AsrModelVersion.v3
    private static let encoderPrecision = ParakeetEncoderPrecision.int8
    private static let inMemoryThresholdBytes = 1_000_000
    private static let approximateChunkStrideSeconds = 12.96

    private let statusReporter: @Sendable (LocalModelStatus) -> Void
    private let fileManager: FileManager
    private let modelsDirectory: URL
    private let temporaryDirectory: URL
    private let encoderComputeUnits: MLComputeUnits
    private let parallelChunkConcurrency: Int
    private let dualDecodeArbitration: Bool
    private let seamGapRepair: Bool
    private var manager: AsrManager?
    private var preparationTask: Task<AsrManager, Error>?
    private var status: LocalModelStatus

    init(
        statusReporter: @escaping @Sendable (LocalModelStatus) -> Void,
        fileManager: FileManager = .default,
        encoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine,
        parallelChunkConcurrency: Int = 4,
        dualDecodeArbitration: Bool = false,
        seamGapRepair: Bool = true
    ) {
        self.statusReporter = statusReporter
        self.fileManager = fileManager
        self.encoderComputeUnits = encoderComputeUnits
        self.parallelChunkConcurrency = max(1, min(parallelChunkConcurrency, 8))
        self.dualDecodeArbitration = dualDecodeArbitration
        self.seamGapRepair = seamGapRepair
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let keyerDirectory = applicationSupport
            .appending(path: "com.keyer.app", directoryHint: .isDirectory)
        modelsDirectory = keyerDirectory
            .appending(path: "Models", directoryHint: .isDirectory)
            .appending(path: "parakeet-tdt-0.6b-v3-coreml", directoryHint: .isDirectory)
        temporaryDirectory = fileManager.temporaryDirectory
            .appending(path: "com.keyer.app-transcription", directoryHint: .isDirectory)
        status = .notDownloaded
    }

    @discardableResult
    func refreshStatus() -> LocalModelStatus {
        let refreshed: LocalModelStatus
        if manager != nil {
            refreshed = .ready
        } else if Self.modelsExist(at: modelsDirectory) {
            refreshed = .downloaded
        } else {
            refreshed = .notDownloaded
        }
        publish(refreshed)
        return refreshed
    }

    func currentStatus() -> LocalModelStatus {
        status
    }

    func prepare() async throws {
        if manager != nil {
            publish(.ready)
            return
        }
        if let preparationTask {
            manager = try await preparationTask.value
            publish(.ready)
            return
        }

        let wasDownloaded = Self.modelsExist(at: modelsDirectory)
        publish(wasDownloaded ? .preparing : .downloading(0))
        let modelsDirectory = modelsDirectory
        let encoderComputeUnits = encoderComputeUnits
        let parallelChunkConcurrency = parallelChunkConcurrency
        let dualDecodeArbitration = dualDecodeArbitration
        let seamGapRepair = seamGapRepair
        let reporter = statusReporter
        let lastReportedPercent = OSAllocatedUnfairLock(initialState: -1)
        let task = Task<AsrManager, Error> {
            let models = try await AsrModels.downloadAndLoad(
                to: modelsDirectory,
                version: Self.version,
                encoderPrecision: Self.encoderPrecision,
                encoderComputeUnits: encoderComputeUnits,
                progressHandler: { progress in
                    guard !wasDownloaded else { return }
                    let percent = min(100, max(0, Int(progress.fractionCompleted * 100)))
                    let shouldReport = lastReportedPercent.withLock { lastPercent in
                        guard percent != lastPercent else { return false }
                        lastPercent = percent
                        return true
                    }
                    if shouldReport {
                        reporter(.downloading(Double(percent) / 100))
                    }
                }
            )
            let config = ASRConfig(
                parallelChunkConcurrency: parallelChunkConcurrency,
                streamingEnabled: true,
                streamingThreshold: 480_000,
                melChunkContext: false,
                dualDecodeArbitration: dualDecodeArbitration,
                seamGapRepair: seamGapRepair,
                seamGapRepairMinGapSeconds: 1.5
            )
            return AsrManager(config: config, models: models)
        }
        preparationTask = task
        do {
            let prepared = try await task.value
            try Task.checkCancellation()
            manager = prepared
            preparationTask = nil
            removeStaleTemporaryFiles()
            removeLegacyWhisperModels()
            publish(.ready)
        } catch is CancellationError {
            preparationTask = nil
            throw CancellationError()
        } catch {
            preparationTask = nil
            let mapped: LocalTranscriptionError = Self.modelsExist(at: modelsDirectory)
                ? .modelLoadFailed
                : .modelDownloadFailed
            publish(.failed(mapped == .modelDownloadFailed ? "Download failed" : "Couldn’t prepare model"))
            throw mapped
        }
    }

    func transcribe(wav: Data) async throws -> LocalTranscriptionResult {
        let preparationStart = ContinuousClock.now
        try await prepare()
        let preparationMS = Self.elapsedMS(since: preparationStart)

        if wav.count > Self.inMemoryThresholdBytes {
            let fileStart = ContinuousClock.now
            let url = try temporaryWAVURL()
            defer { try? fileManager.removeItem(at: url) }
            do {
                try wav.write(to: url, options: .atomic)
            } catch {
                throw LocalTranscriptionError.invalidAudio
            }
            return try await transcribePreparedFile(
                at: url,
                preparationMilliseconds: preparationMS,
                audioPreparationMilliseconds: Self.elapsedMS(since: fileStart)
            )
        }

        let decodeStart = ContinuousClock.now
        let samples: [Float]
        do {
            samples = try PCM16WAVDecoder.decode(wav)
        } catch {
            throw LocalTranscriptionError.invalidAudio
        }
        return try await transcribeSamples(
            samples,
            preparationMilliseconds: preparationMS,
            audioDecodingMilliseconds: Self.elapsedMS(since: decodeStart)
        )
    }

    func transcribe(fileURL: URL) async throws -> LocalTranscriptionResult {
        let preparationStart = ContinuousClock.now
        try await prepare()
        let preparationMS = Self.elapsedMS(since: preparationStart)
        return try await transcribePreparedFile(
            at: fileURL,
            preparationMilliseconds: preparationMS,
            audioPreparationMilliseconds: 0
        )
    }

    func unload() async {
        let inFlightPreparation = preparationTask
        inFlightPreparation?.cancel()
        if let inFlightPreparation {
            _ = try? await inFlightPreparation.value
        }
        preparationTask = nil
        if let manager {
            await manager.cleanup()
        }
        manager = nil
        publish(Self.modelsExist(at: modelsDirectory) ? .downloaded : .notDownloaded)
    }

    func removeDownloadedModel() async throws {
        await unload()
        let modelsRoot = modelsDirectory.deletingLastPathComponent()
        if fileManager.fileExists(atPath: modelsRoot.path) {
            try fileManager.removeItem(at: modelsRoot)
        }
        publish(.notDownloaded)
    }

    private func transcribeSamples(
        _ samples: [Float],
        preparationMilliseconds: Double,
        audioDecodingMilliseconds: Double
    ) async throws -> LocalTranscriptionResult {
        guard !samples.isEmpty else { throw LocalTranscriptionError.invalidAudio }
        let inferenceStart = ContinuousClock.now
        let result = try await retryingTransientFailure {
            guard let manager = self.manager else { throw LocalTranscriptionError.modelLoadFailed }
            var decoderState = TdtDecoderState.make()
            return try await manager.transcribe(samples, decoderState: &decoderState)
        }
        return try resultFrom(
            result,
            wallInferenceMilliseconds: Self.elapsedMS(since: inferenceStart),
            preparationMilliseconds: preparationMilliseconds,
            audioDecodingMilliseconds: audioDecodingMilliseconds
        )
    }

    private func transcribePreparedFile(
        at url: URL,
        preparationMilliseconds: Double,
        audioPreparationMilliseconds: Double
    ) async throws -> LocalTranscriptionResult {
        let inferenceStart = ContinuousClock.now
        let result = try await retryingTransientFailure {
            guard let manager = self.manager else { throw LocalTranscriptionError.modelLoadFailed }
            var decoderState = TdtDecoderState.make()
            return try await manager.transcribe(url, decoderState: &decoderState)
        }
        return try resultFrom(
            result,
            wallInferenceMilliseconds: Self.elapsedMS(since: inferenceStart),
            preparationMilliseconds: preparationMilliseconds,
            audioDecodingMilliseconds: audioPreparationMilliseconds
        )
    }

    private func retryingTransientFailure<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard Self.isRetryable(error), let manager else { throw error }
            await manager.reset()
            try Task.checkCancellation()
            return try await operation()
        }
    }

    private func resultFrom(
        _ result: ASRResult,
        wallInferenceMilliseconds: Double,
        preparationMilliseconds: Double,
        audioDecodingMilliseconds: Double
    ) throws -> LocalTranscriptionResult {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalTranscriptionError.emptyTranscript }
        return LocalTranscriptionResult(
            text: text,
            languages: TextNormalizer.detectedLanguages(in: text),
            timing: .init(
                audioDecodingMilliseconds: audioDecodingMilliseconds,
                modelPreparationMilliseconds: preparationMilliseconds,
                inferenceMilliseconds: wallInferenceMilliseconds,
                audioSegmentCount: max(
                    1,
                    Int(ceil(result.duration / Self.approximateChunkStrideSeconds))
                )
            )
        )
    }

    private func temporaryWAVURL() throws -> URL {
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        return temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("wav")
    }

    private func removeStaleTemporaryFiles() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }

    private func removeLegacyWhisperModels() {
        let modelsRoot = modelsDirectory.deletingLastPathComponent()
        let legacyPaths = [
            modelsRoot.appending(path: "models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory),
            modelsRoot.appending(path: "models/openai/whisper-small", directoryHint: .isDirectory),
        ]
        for path in legacyPaths where fileManager.fileExists(atPath: path.path) {
            try? fileManager.removeItem(at: path)
        }

        let emptyParents = [
            modelsRoot.appending(path: "models/argmaxinc", directoryHint: .isDirectory),
            modelsRoot.appending(path: "models/openai", directoryHint: .isDirectory),
            modelsRoot.appending(path: "models", directoryHint: .isDirectory),
        ]
        for path in emptyParents {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: path.path),
                  contents.isEmpty else { continue }
            try? fileManager.removeItem(at: path)
        }
    }

    private func publish(_ newStatus: LocalModelStatus) {
        status = newStatus
        statusReporter(newStatus)
    }

    private static func modelsExist(at directory: URL) -> Bool {
        AsrModels.modelsExist(
            at: directory,
            version: version,
            encoderPrecision: encoderPrecision
        )
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let local = error as? LocalTranscriptionError {
            return local == .modelLoadFailed
        }
        if let asr = error as? ASRError {
            switch asr {
            case .invalidAudioData, .fileAccessFailed:
                return false
            default:
                return true
            }
        }
        return true
    }

    private static func elapsedMS(since instant: ContinuousClock.Instant) -> Double {
        let duration = instant.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
    }
}
