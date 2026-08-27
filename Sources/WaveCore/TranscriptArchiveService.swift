import Foundation

public enum TranscriptArchiveStatus: Equatable, Sendable {
    case ready
    case failed(String)

    public var label: String {
        switch self {
        case .ready: "Saved locally"
        case let .failed(message): message
        }
    }

    public var isAvailable: Bool {
        if case .ready = self { return true }
        return false
    }
}

public actor TranscriptArchiveService {
    private let fileManager: FileManager
    private let historyURL: URL

    public init(fileManager: FileManager = .default, historyURL: URL? = nil) {
        self.fileManager = fileManager
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.historyURL = historyURL ?? documents.appendingPathComponent("Keyer", isDirectory: true)
    }

    public func stage(_ record: TranscriptArchiveRecord) throws -> TranscriptArchiveStatus {
        let directory = record.relativeDirectoryComponents.reduce(historyURL) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(record.markdown.utf8).write(
            to: availableDocumentURL(for: record, in: directory), options: .atomic
        )
        return .ready
    }

    public func documentsURL() -> URL? {
        createDirectory(historyURL)
    }

    public func documentsURL(for kind: TranscriptArchiveRecord.Kind) -> URL? {
        createDirectory(historyURL.appendingPathComponent(kind.folderName, isDirectory: true))
    }

    public func documentURL(for record: TranscriptArchiveRecord) -> URL? {
        let directory = record.relativeDirectoryComponents.reduce(historyURL) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        let stem = String(record.documentFilename.dropLast(3))
        let identifierLine = "id: \"\(record.id.uuidString.lowercased())\""
        let candidates = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return candidates.first { candidate in
            candidate.pathExtension == "md"
                && candidate.deletingPathExtension().lastPathComponent.hasPrefix(stem)
                && ((try? String(contentsOf: candidate, encoding: .utf8))?
                    .split(separator: "\n", maxSplits: 16).contains(Substring(identifierLine)) == true)
        }
    }

    private func createDirectory(_ url: URL) -> URL? {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }

    private func availableDocumentURL(for record: TranscriptArchiveRecord, in directory: URL) -> URL {
        let filename = record.documentFilename
        let stem = String(filename.dropLast(3))
        let identifierLine = "id: \"\(record.id.uuidString.lowercased())\""
        var collisionIndex = 0
        while true {
            let name = collisionIndex == 0 ? filename : "\(stem)-\(String(format: "%03d", collisionIndex)).md"
            let candidate = directory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
            if let contents = try? String(contentsOf: candidate, encoding: .utf8),
               contents.split(separator: "\n", maxSplits: 16).contains(Substring(identifierLine)) {
                return candidate
            }
            collisionIndex += 1
        }
    }
}
