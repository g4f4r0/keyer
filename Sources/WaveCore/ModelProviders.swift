import Foundation

public struct ModelProviderDescriptor: Equatable, Sendable {
    public let identifier: String
    public let displayName: String

    public init(identifier: String, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }
}

public enum ModelProviderAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

public struct SpeechTranscriptionTiming: Equatable, Sendable {
    public let audioDecodingMilliseconds: Double
    public let modelPreparationMilliseconds: Double
    public let inferenceMilliseconds: Double
    public let audioSegmentCount: Int

    public init(audioDecodingMilliseconds: Double, modelPreparationMilliseconds: Double,
                inferenceMilliseconds: Double, audioSegmentCount: Int) {
        self.audioDecodingMilliseconds = audioDecodingMilliseconds
        self.modelPreparationMilliseconds = modelPreparationMilliseconds
        self.inferenceMilliseconds = inferenceMilliseconds
        self.audioSegmentCount = audioSegmentCount
    }
}

public struct SpeechTranscription: Equatable, Sendable {
    public let text: String
    public let languages: [String]
    public let timing: SpeechTranscriptionTiming
    public let model: String?

    public init(text: String, languages: [String], timing: SpeechTranscriptionTiming,
                model: String? = nil) {
        self.text = text
        self.languages = languages
        self.timing = timing
        self.model = model
    }
}

public struct TextGenerationRequest: Equatable, Sendable {
    public struct Message: Equatable, Sendable {
        public enum Role: String, Equatable, Sendable {
            case system
            case user
            case assistant
        }

        public let role: Role
        public let content: String

        public init(role: Role, content: String) {
            self.role = role
            self.content = content
        }
    }

    public let messages: [Message]
    public let responseSchema: JSONSchema?
    public let maximumOutputTokens: Int
    public let temperature: Double

    public init(
        messages: [Message],
        responseSchema: JSONSchema? = nil,
        maximumOutputTokens: Int = 1_024,
        temperature: Double = 0
    ) {
        self.messages = messages
        self.responseSchema = responseSchema
        self.maximumOutputTokens = maximumOutputTokens
        self.temperature = temperature
    }
}

public struct TextGenerationUsage: Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cost: Double?

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cost: Double? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cost = cost
    }
}

public struct TextGenerationResponse: Equatable, Sendable {
    public let text: String
    public let model: String
    public let usage: TextGenerationUsage
    public let latencyMilliseconds: Double

    public init(text: String, model: String, usage: TextGenerationUsage,
                latencyMilliseconds: Double) {
        self.text = text
        self.model = model
        self.usage = usage
        self.latencyMilliseconds = latencyMilliseconds
    }
}

public protocol TextGenerationProvider: Actor {
    nonisolated var descriptor: ModelProviderDescriptor { get }
    func generate(_ request: TextGenerationRequest) async throws -> TextGenerationResponse
}

public indirect enum JSONSchema: Equatable, Sendable {
    case string(description: String? = nil)
    case array(items: JSONSchema, description: String? = nil)
    case object(properties: [String: JSONSchema], required: [String], additionalProperties: Bool = false)
}

public protocol SpeechTranscriptionProvider: Actor {
    nonisolated var descriptor: ModelProviderDescriptor { get }

    func prepare() async throws
    func transcribe(wav: Data) async throws -> SpeechTranscription
    func transcribe(fileURL: URL) async throws -> SpeechTranscription
    func unload() async
}

public struct TextCleanupRequest: Equatable, Sendable {
    public let text: String
    public let languages: [String]

    public init(text: String, languages: [String] = []) {
        self.text = text
        self.languages = languages
    }
}

public struct TextCleanupResult: Equatable, Sendable {
    public let text: String
    public let provider: ModelProviderDescriptor

    public init(text: String, provider: ModelProviderDescriptor) {
        self.text = text
        self.provider = provider
    }
}

public protocol TextCleanupProvider: Actor {
    nonisolated var descriptor: ModelProviderDescriptor { get }

    func availability() async -> ModelProviderAvailability
    func prepare() async throws
    func clean(_ request: TextCleanupRequest) async throws -> String
    func unload() async
}

public struct MeetingSummaryRequest: Equatable, Sendable {
    public let transcript: String
    public let languages: [String]
    public let durationSeconds: Double

    public init(transcript: String, languages: [String] = [], durationSeconds: Double) {
        self.transcript = transcript
        self.languages = languages
        self.durationSeconds = durationSeconds
    }
}

public struct MeetingSummary: Codable, Equatable, Sendable {
    public let title: String
    public let summary: String
    public let actions: [String]

    public init(title: String, summary: String, actions: [String]) {
        self.title = title
        self.summary = summary
        self.actions = actions
    }
}

public struct MeetingSummaryResult: Equatable, Sendable {
    public let value: MeetingSummary
    public let provider: ModelProviderDescriptor

    public init(value: MeetingSummary, provider: ModelProviderDescriptor) {
        self.value = value
        self.provider = provider
    }
}

public protocol MeetingSummaryProvider: Actor {
    nonisolated var descriptor: ModelProviderDescriptor { get }

    func availability() async -> ModelProviderAvailability
    func prepare() async throws
    func summarize(_ request: MeetingSummaryRequest) async throws -> MeetingSummary
    func unload() async
}

public enum ModelPipelineError: Error, Equatable, Sendable {
    case noProvider
    case unavailable(String)
    case invalidOutput
    case providerFailed(String)
}

public actor TextCleanupPipeline {
    private let providers: [any TextCleanupProvider]

    public init(providers: [any TextCleanupProvider]) {
        self.providers = providers
    }

    public func process(_ request: TextCleanupRequest) async throws -> TextCleanupResult {
        var lastUnavailableReason: String?
        var lastFailure: String?
        for provider in providers {
            switch await provider.availability() {
            case .available:
                do {
                    try await provider.prepare()
                    let text = try await provider.clean(request)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { throw ModelPipelineError.invalidOutput }
                    return TextCleanupResult(text: text, provider: provider.descriptor)
                } catch is CancellationError {
                    await provider.unload()
                    throw CancellationError()
                } catch {
                    await provider.unload()
                    lastFailure = String(describing: error)
                    continue
                }
            case let .unavailable(reason):
                lastUnavailableReason = reason
            }
        }
        if let lastFailure { throw ModelPipelineError.providerFailed(lastFailure) }
        if let lastUnavailableReason { throw ModelPipelineError.unavailable(lastUnavailableReason) }
        throw ModelPipelineError.noProvider
    }

    public func unload() async {
        for provider in providers { await provider.unload() }
    }
}

public actor MeetingSummaryPipeline {
    private let providers: [any MeetingSummaryProvider]

    public init(providers: [any MeetingSummaryProvider]) {
        self.providers = providers
    }

    public func process(_ request: MeetingSummaryRequest) async throws -> MeetingSummaryResult {
        var lastUnavailableReason: String?
        var lastFailure: String?
        for provider in providers {
            switch await provider.availability() {
            case .available:
                do {
                    try await provider.prepare()
                    let summary = try await provider.summarize(request).normalized()
                    guard !summary.title.isEmpty, !summary.summary.isEmpty else {
                        throw ModelPipelineError.invalidOutput
                    }
                    return MeetingSummaryResult(value: summary, provider: provider.descriptor)
                } catch is CancellationError {
                    await provider.unload()
                    throw CancellationError()
                } catch {
                    await provider.unload()
                    lastFailure = String(describing: error)
                    continue
                }
            case let .unavailable(reason):
                lastUnavailableReason = reason
            }
        }
        if let lastFailure { throw ModelPipelineError.providerFailed(lastFailure) }
        if let lastUnavailableReason { throw ModelPipelineError.unavailable(lastUnavailableReason) }
        throw ModelPipelineError.noProvider
    }

    public func unload() async {
        for provider in providers { await provider.unload() }
    }
}

private extension MeetingSummary {
    func normalized() -> MeetingSummary {
        var seenActions = Set<String>()
        let cleanedActions = actions.compactMap { action -> String? in
            var value = action
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            while value.hasPrefix("-") || value.hasPrefix("•") {
                value.removeFirst()
                value = value.trimmingCharacters(in: .whitespaces)
            }
            value = TextNormalizer.normalize(value)
            guard !value.isEmpty, seenActions.insert(value.lowercased()).inserted else { return nil }
            return value
        }
        var cleanedTitle = title
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while cleanedTitle.hasPrefix("#") {
            cleanedTitle.removeFirst()
            cleanedTitle = cleanedTitle.trimmingCharacters(in: .whitespaces)
        }
        return MeetingSummary(
            title: cleanedTitle,
            summary: TextNormalizer.normalize(summary),
            actions: cleanedActions
        )
    }
}
