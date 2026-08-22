import Foundation

public struct DictationMetric: Sendable, Codable {
    public let sessionID: UUID
    public let completedAt: Date
    public let totalMilliseconds: Double
    public let audioFinalizationMilliseconds: Double
    public let audioDecodingMilliseconds: Double
    public let modelPreparationMilliseconds: Double
    public let inferenceMilliseconds: Double
    public let normalizationMilliseconds: Double
    public let insertionMilliseconds: Double
    public let payloadBytes: Int
    public let audioDurationSeconds: Double
    public let droppedBuffers: Int
    public let model: String

    public init(sessionID: UUID, completedAt: Date = .now, totalMilliseconds: Double,
                audioFinalizationMilliseconds: Double, audioDecodingMilliseconds: Double,
                modelPreparationMilliseconds: Double, inferenceMilliseconds: Double,
                normalizationMilliseconds: Double,
                insertionMilliseconds: Double, payloadBytes: Int, audioDurationSeconds: Double,
                droppedBuffers: Int, model: String) {
        self.sessionID = sessionID
        self.completedAt = completedAt
        self.totalMilliseconds = totalMilliseconds
        self.audioFinalizationMilliseconds = audioFinalizationMilliseconds
        self.audioDecodingMilliseconds = audioDecodingMilliseconds
        self.modelPreparationMilliseconds = modelPreparationMilliseconds
        self.inferenceMilliseconds = inferenceMilliseconds
        self.normalizationMilliseconds = normalizationMilliseconds
        self.insertionMilliseconds = insertionMilliseconds
        self.payloadBytes = payloadBytes
        self.audioDurationSeconds = audioDurationSeconds
        self.droppedBuffers = droppedBuffers
        self.model = model
    }
}

public struct MetricsBuffer: Sendable {
    public let capacity: Int
    public private(set) var values: [DictationMetric] = []

    public init(capacity: Int = 256) { self.capacity = max(1, capacity) }

    public mutating func append(_ metric: DictationMetric) {
        if values.count == capacity { values.removeFirst() }
        values.append(metric)
    }

    public func percentile(_ percentile: Double, keyPath: KeyPath<DictationMetric, Double> = \.totalMilliseconds) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.map { $0[keyPath: keyPath] }.sorted()
        let clamped = min(max(percentile, 0), 1)
        let index = Int((Double(sorted.count - 1) * clamped).rounded(.up))
        return sorted[index]
    }
}
