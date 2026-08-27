import Foundation

public enum MeetingLedgerParser {
    public static func parse(_ response: String) -> MeetingSummary? {
        var title = ""
        var facts: [String] = []
        var actions: [String] = []
        var section = Section.none

        for rawLine in response.components(separatedBy: .newlines) {
            let line = stripMarkdown(rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let parsedTitle = parseTitle(from: line) {
                title = parsedTitle
                continue
            }

            switch normalizedHeading(line) {
            case "facts":
                section = .facts
                continue
            case "actions":
                section = .actions
                continue
            case "end":
                section = .none
                continue
            default:
                break
            }

            guard let bullet = bulletValue(from: line) else { continue }
            switch section {
            case .facts:
                facts.append(bullet)
            case .actions:
                if let action = action(from: bullet) { actions.append(action) }
            case .none:
                continue
            }
        }

        let uniqueFacts = deduplicated(facts)
        guard !title.isEmpty, !uniqueFacts.isEmpty else { return nil }
        return MeetingSummary(
            title: title,
            summary: paragraphs(from: uniqueFacts),
            actions: deduplicated(actions)
        )
    }

    /// Keeps only actions whose owner and task wording are grounded in the
    /// owner's source lines. This is language-neutral and never invents terms.
    public static func groundedActions(_ actions: [String], transcript: String) -> [String] {
        let lines = transcript.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return actions.filter { action in
            guard let separator = action.firstIndex(of: ":") else { return false }
            let owner = String(action[..<separator]).trimmingCharacters(in: .whitespaces)
            var task = String(action[action.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if let deadlineStart = task.range(of: " (", options: .backwards), task.hasSuffix(")") {
                task.removeSubrange(deadlineStart.lowerBound...)
            }

            let ownerWords = normalizedWords(in: owner)
            let matchingSource = lines.filter {
                ownerWords.isSubset(of: normalizedWords(in: $0))
            }.joined(separator: " ")
            let sourceWords = normalizedWords(in: matchingSource)
            let taskWords = normalizedWords(in: task).filter { $0.count >= 3 }
            return !taskWords.isEmpty && taskWords.allSatisfy(sourceWords.contains)
        }
    }

    private enum Section {
        case none
        case facts
        case actions
    }

    private static func parseTitle(from line: String) -> String? {
        let normalized = line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard normalized.lowercased().hasPrefix("title:") else { return nil }
        let value = String(normalized.dropFirst(6))
            .trimmingCharacters(in: CharacterSet(charactersIn: "#:* "))
        return value.isEmpty ? nil : value
    }

    private static func normalizedHeading(_ line: String) -> String {
        line.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "#:* "))
    }

    private static func bulletValue(from line: String) -> String? {
        guard line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix("•") else {
            return nil
        }
        let value = String(line.dropFirst())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func action(from value: String) -> String? {
        let fields = value.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.count == 3, !fields[0].isEmpty, !fields[1].isEmpty,
              !isPlaceholder(fields[1]) else { return nil }

        if fields[2].isEmpty || isPlaceholder(fields[2]) {
            return "\(fields[0]): \(fields[1])"
        }
        return "\(fields[0]): \(fields[1]) (\(fields[2]))"
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        let normalized = value.lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return [
            "n/a", "na", "none", "no action", "no future commitment",
            "no deadline", "not applicable", "not specified", "unspecified",
        ].contains(normalized)
    }

    private static func paragraphs(from facts: [String]) -> String {
        let paragraphCount = min(6, max(1, Int(ceil(Double(facts.count) / 3))))
        let factsPerParagraph = Int(ceil(Double(facts.count) / Double(paragraphCount)))
        return stride(from: 0, to: facts.count, by: factsPerParagraph).map { start in
            facts[start ..< min(start + factsPerParagraph, facts.count)]
                .joined(separator: " ")
        }.joined(separator: "\n\n")
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            seen.insert(value.lowercased()).inserted
        }
    }

    private static func stripMarkdown(_ value: String) -> String {
        value.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
    }

    private static func normalizedWords(in value: String) -> Set<String> {
        Set(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init))
    }
}
