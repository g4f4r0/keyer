import Foundation

public struct TranscriptArchiveRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case dictation
        case meeting

        public var displayName: String {
            switch self {
            case .dictation: "Dictation"
            case .meeting: "Meeting"
            }
        }

        public var folderName: String {
            switch self {
            case .dictation: "Dictations"
            case .meeting: "Meetings"
            }
        }
    }

    public let schemaVersion: Int
    public let id: UUID
    public let kind: Kind
    public let createdAt: Date
    public let languages: [String]
    public let originalText: String
    public let finalText: String
    public let model: String
    public let audioDurationSeconds: Double
    public let sourceApplication: String?
    public let sourceWindowTitle: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case kind
        case createdAt
        case languages
        case originalText
        case finalText
        case model
        case audioDurationSeconds
        case sourceApplication
        case sourceWindowTitle
    }

    public init(schemaVersion: Int = 1, id: UUID, kind: Kind, createdAt: Date = .now,
                languages: [String] = ["und"], originalText: String, finalText: String, model: String,
                audioDurationSeconds: Double, sourceApplication: String? = nil,
                sourceWindowTitle: String? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.languages = languages
        self.originalText = originalText
        self.finalText = finalText
        self.model = model
        self.audioDurationSeconds = audioDurationSeconds
        self.sourceApplication = sourceApplication
        self.sourceWindowTitle = sourceWindowTitle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        languages = try container.decodeIfPresent([String].self, forKey: .languages) ?? ["und"]
        originalText = try container.decode(String.self, forKey: .originalText)
        finalText = try container.decode(String.self, forKey: .finalText)
        model = try container.decode(String.self, forKey: .model)
        audioDurationSeconds = try container.decode(Double.self, forKey: .audioDurationSeconds)
        sourceApplication = try container.decodeIfPresent(String.self, forKey: .sourceApplication)
        sourceWindowTitle = try container.decodeIfPresent(String.self, forKey: .sourceWindowTitle)
    }

    public var relativeDirectoryComponents: [String] {
        let components = Calendar(identifier: .iso8601).dateComponents(in: .gmt, from: createdAt)
        return [kind.folderName, String(format: "%04d", components.year ?? 0),
                String(format: "%02d", components.month ?? 0)]
    }

    public var documentFilename: String {
        let timestamp = Self.iso8601String(from: createdAt)
            .replacingOccurrences(of: ":", with: "-")
        return "\(timestamp).md"
    }

    public var markdown: String {
        var metadata = [
            "---",
            "id: \(Self.yamlQuoted(id.uuidString.lowercased()))",
            "type: \(kind.rawValue)",
            "date: \(Self.yamlQuoted(Self.iso8601String(from: createdAt)))",
            "languages:",
        ]
        var seenLanguages = Set<String>()
        let normalizedLanguages = languages.map { $0.lowercased() }
            .filter { !$0.isEmpty && seenLanguages.insert($0).inserted }
        for language in normalizedLanguages.isEmpty ? ["und"] : normalizedLanguages {
            metadata.append("  - \(Self.yamlQuoted(language))")
        }
        metadata.append("duration: \(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), audioDurationSeconds))")
        metadata.append("---")
        let content = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return metadata.joined(separator: "\n") + "\n\n" + content + "\n"
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func yamlQuoted(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}
