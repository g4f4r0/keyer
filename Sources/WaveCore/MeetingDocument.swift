import Foundation

public struct MeetingDocument: Equatable, Sendable {
    public let intelligence: MeetingSummary
    public let transcript: String

    public init(intelligence: MeetingSummary, transcript: String) {
        self.intelligence = intelligence
        self.transcript = transcript
    }

    public var markdown: String {
        let title = intelligence.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = intelligence.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections = ["# \(title)", "## Summary", summary]
        let actions = intelligence.actions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !actions.isEmpty {
            sections.append(actions.map { "- \($0)" }.joined(separator: "\n"))
        }
        sections.append("## Transcript")
        sections.append(transcript)
        return sections.joined(separator: "\n\n")
    }
}

public enum TextChunker {
    public static func chunks(of text: String, maximumCharacters: Int) -> [String] {
        precondition(maximumCharacters > 0)
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var chunks: [String] = []
        var current = ""
        let paragraphs = normalized.components(separatedBy: "\n\n")

        for paragraph in paragraphs {
            let value = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            for piece in split(value, maximumCharacters: maximumCharacters) {
                let separator = current.isEmpty ? "" : "\n\n"
                if current.count + separator.count + piece.count <= maximumCharacters {
                    current += separator + piece
                } else {
                    if !current.isEmpty { chunks.append(current) }
                    current = piece
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func split(_ text: String, maximumCharacters: Int) -> [String] {
        guard text.count > maximumCharacters else { return [text] }
        var pieces: [String] = []
        var start = text.startIndex

        while let hardEnd = text.index(
            start,
            offsetBy: maximumCharacters,
            limitedBy: text.endIndex
        ), hardEnd < text.endIndex {
            let prefix = text[start..<hardEnd]
            let preferredBreak = prefix.lastIndex(where: { ".!?\n".contains($0) })
            let whitespaceBreak = prefix.lastIndex(where: \.isWhitespace)
            let breakIndex = preferredBreak.map { text.index(after: $0) }
                ?? whitespaceBreak
                ?? hardEnd
            let piece = text[start..<breakIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            start = breakIndex
            while start < text.endIndex, text[start].isWhitespace {
                start = text.index(after: start)
            }
        }
        let tail = text[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }
}
