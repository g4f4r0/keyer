import Foundation

public enum TranscriptArchiveStatus: Equatable, Sendable {
    case checking
    case synced
    case pending(Int)
    case iCloudUnavailable(Int)
    case failed(String, Int)

    public var label: String {
        switch self {
        case .checking: "Checking iCloud"
        case .synced: "Synced with iCloud Drive"
        case let .pending(count): count == 1 ? "1 document waiting to sync" : "\(count) documents waiting to sync"
        case let .iCloudUnavailable(count):
            count == 0 ? "iCloud Drive is unavailable" : "iCloud unavailable — \(count) saved locally"
        case let .failed(message, _): message
        }
    }

    public var isAvailable: Bool {
        switch self {
        case .synced, .pending: true
        case .checking, .iCloudUnavailable, .failed: false
        }
    }
}

public actor TranscriptArchiveService {
    public static let containerIdentifier = "iCloud.com.keyer.app"

    private let fileManager: FileManager
    private let localQueueURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let cloudDocumentsURLProvider: @Sendable () -> URL?

    public init(fileManager: FileManager = .default, localQueueURL: URL? = nil,
                cloudDocumentsURLProvider: (@Sendable () -> URL?)? = nil) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.localQueueURL = localQueueURL ?? support
            .appendingPathComponent("com.keyer.app", isDirectory: true)
            .appendingPathComponent("Pending History", isDirectory: true)
        self.cloudDocumentsURLProvider = cloudDocumentsURLProvider ?? {
            guard FileManager.default.ubiquityIdentityToken != nil,
                  let container = FileManager.default.url(
                    forUbiquityContainerIdentifier: Self.containerIdentifier
                  ) else { return nil }
            return container.appendingPathComponent("Documents", isDirectory: true)
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.iso8601StringWithMilliseconds(from: date))
        }
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = Self.date(fromISO8601String: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO 8601 date"
                )
            }
            return date
        }
    }

    public func stage(_ record: TranscriptArchiveRecord) throws -> TranscriptArchiveStatus {
        try fileManager.createDirectory(at: localQueueURL, withIntermediateDirectories: true)
        let finalDirectory = localQueueURL.appendingPathComponent(record.id.uuidString.lowercased(),
                                                                  isDirectory: true)
        if fileManager.fileExists(atPath: finalDirectory.path) {
            return .pending(pendingCount())
        }

        let temporaryDirectory = localQueueURL
            .appendingPathComponent(".\(record.id.uuidString.lowercased()).\(UUID().uuidString).tmp",
                                    isDirectory: true)
        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            try encoder.encode(record).write(
                to: temporaryDirectory.appendingPathComponent("record.json"), options: .atomic
            )
            try fileManager.moveItem(at: temporaryDirectory, to: finalDirectory)
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw error
        }
        return .pending(pendingCount())
    }

    public func synchronize() -> TranscriptArchiveStatus {
        let count = pendingCount()
        guard let documentsURL = iCloudDocumentsURL(createIfNeeded: true) else {
            return .iCloudUnavailable(count)
        }

        do {
            for directory in pendingDirectories() {
                try synchronizePendingDirectory(directory, documentsURL: documentsURL)
            }
            return pendingCount() == 0 ? .synced : .pending(pendingCount())
        } catch {
            let message = (error as NSError).localizedDescription
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return .failed("iCloud sync failed — \(message)", pendingCount())
        }
    }

    public func documentsURL() -> URL? {
        iCloudDocumentsURL(createIfNeeded: true)
    }

    private func synchronizePendingDirectory(_ pendingURL: URL, documentsURL: URL) throws {
        let recordData = try Data(contentsOf: pendingURL.appendingPathComponent("record.json"),
                                  options: .mappedIfSafe)
        let record = try decoder.decode(TranscriptArchiveRecord.self, from: recordData)
        let markdownData = Data(record.markdown.utf8)

        let documentDirectory = record.relativeDirectoryComponents.reduce(documentsURL) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        let documentURL = availableDocumentURL(for: record, in: documentDirectory)
        try coordinatedWrite(markdownData, to: documentURL)
        try fileManager.removeItem(at: pendingURL)
    }

    private func availableDocumentURL(for record: TranscriptArchiveRecord, in directory: URL) -> URL {
        let filename = record.documentFilename
        let stem = String(filename.dropLast(3))
        let identifierLine = "id: \"\(record.id.uuidString.lowercased())\""
        var collisionIndex = 0

        while true {
            let candidateName = collisionIndex == 0
                ? filename
                : "\(stem)-\(String(format: "%03d", collisionIndex)).md"
            let candidate = directory.appendingPathComponent(candidateName)
            guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

            if let contents = try? String(contentsOf: candidate, encoding: .utf8),
               contents.split(separator: "\n", maxSplits: 16)
                .contains(where: { $0 == Substring(identifierLine) }) {
                return candidate
            }
            collisionIndex += 1
        }
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &coordinationError) { coordinatedURL in
            do {
                try fileManager.createDirectory(at: coordinatedURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    private func iCloudDocumentsURL(createIfNeeded: Bool) -> URL? {
        guard let documents = cloudDocumentsURLProvider() else { return nil }
        if createIfNeeded {
            do {
                try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return documents
    }

    private func pendingDirectories() -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .nameKey]
        let urls = (try? fileManager.contentsOfDirectory(
            at: localQueueURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { url in
            (try? url.resourceValues(forKeys: keys).isDirectory) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func pendingCount() -> Int { pendingDirectories().count }

    private static func iso8601StringWithMilliseconds(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(fromISO8601String value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
