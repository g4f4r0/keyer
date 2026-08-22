import Foundation
import NaturalLanguage

public enum TextNormalizer {
    public static func joinTranscriptionChunks(_ chunks: [String]) -> String {
        var joinedWords = [Substring]()
        for chunk in chunks {
            let words = chunk.split(whereSeparator: \Character.isWhitespace)
            guard !words.isEmpty else { continue }
            let maximumOverlap = min(12, joinedWords.count, words.count)
            var overlap = 0
            if maximumOverlap > 0 {
                for count in stride(from: maximumOverlap, through: 1, by: -1) {
                    let suffix = joinedWords.suffix(count).map(normalizedComparisonWord)
                    let prefix = words.prefix(count).map(normalizedComparisonWord)
                    let isReliableSingleWord = count > 1 || (suffix.first?.count ?? 0) >= 4
                    if isReliableSingleWord, suffix == prefix {
                        overlap = count
                        break
                    }
                }
            }
            joinedWords.append(contentsOf: words.dropFirst(overlap))
        }
        return joinedWords.joined(separator: " ")
    }

    public static func detectedLanguages(in text: String, fallback: [String] = []) -> [String] {
        var languages: [String] = []
        var seen = Set<String>()
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard sentence.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 4 else {
                return true
            }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sentence)
            guard let language = recognizer.dominantLanguage?.rawValue,
                  let confidence = recognizer.languageHypotheses(withMaximum: 1)[NLLanguage(language)],
                  confidence >= 0.55,
                  seen.insert(language).inserted else { return true }
            languages.append(language)
            return true
        }
        if languages.isEmpty {
            for language in fallback.map({ $0.lowercased() })
                where language != "automatic" && !language.isEmpty && seen.insert(language).inserted {
                languages.append(language)
            }
        }
        return languages.isEmpty ? ["und"] : languages
    }

    private static let leadingFiller = try! NSRegularExpression(
        pattern: #"^\s*(so|like|basically|actually|you know)[,\s]+"#,
        options: .caseInsensitive
    )
    private static let embeddedFiller = try! NSRegularExpression(
        pattern: #",\s*(like|you know|basically),"#,
        options: .caseInsensitive
    )
    private static let hesitation = try! NSRegularExpression(
        pattern: #"(^|[\s,])(um+|uh+|erm+|hmm+|eh+)(?=$|[\s,.!?])"#,
        options: .caseInsensitive
    )
    private static let repeatedWord = try! NSRegularExpression(
        pattern: #"\b([\p{L}\p{N}']{1,30})[\s,.!?-]+\1\b"#,
        options: .caseInsensitive
    )
    private static let correctionRestart = try! NSRegularExpression(
        pattern: #"^\s*(?:no[,.\s]+){1,3}(?:(?:i\s+(?:mean|meant)(?:\s+to\s+say)?)|(?:quiero|quise)\s+decir|mejor\s+dicho)[,:\s]+"#,
        options: .caseInsensitive
    )
    private static let leadingSeparator = try! NSRegularExpression(
        pattern: #"^\s*[,;:]+\s*"#
    )
    private static let leadingCorrection = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:i\s+(?:mean|meant)(?:\s+to\s+say)?)|(?:quiero|quise)\s+decir|mejor\s+dicho|sorry|perd[oó]n)[,:\s]+"#,
        options: .caseInsensitive
    )
    private static let dictatedList = try! NSRegularExpression(
        pattern: #"\b(first|firstly|primero)\b.*\b(second|secondly|segundo)\b.*\b(third|thirdly|tercero)\b"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    public static func normalize(_ input: String) -> String {
        let normalized = input.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        return normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(normalizeLine)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " — ", with: ", ")
            .replacingOccurrences(of: "—", with: ", ")
            .replacingOccurrences(of: "–", with: "-")
    }

    public static func needsSpokenCleanup(_ input: String) -> Bool {
        let normalized = " \(input.lowercased()) "
        let correctionMarkers = [
            " i mean ", " i meant ", " no, no ", " no no ", " sorry, ", " or rather ",
            " quiero decir ", " quise decir ", " mejor dicho ", " no, no ", " perdón, ",
            " perdon, ", " o sea, "
        ]
        if correctionMarkers.contains(where: normalized.contains) { return true }
        if matches(leadingFiller, in: input) { return true }
        if matches(embeddedFiller, in: input) { return true }
        if matches(hesitation, in: input) { return true }
        if matches(repeatedWord, in: input) { return true }
        return matches(dictatedList, in: input)
    }

    public static func removeSimpleStutters(_ input: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        let cleaned = repeatedWord.stringByReplacingMatches(in: input, range: range, withTemplate: "$1")
        return normalize(cleaned)
    }

    public static func cleanSpokenTextLocally(_ input: String) -> String {
        var cleaned = removeSimpleStutters(input)
        cleaned = replacing(hesitation, in: cleaned, with: "$1")
        cleaned = replacing(leadingSeparator, in: cleaned, with: "")
        cleaned = replacing(correctionRestart, in: cleaned, with: "")
        cleaned = replacing(leadingCorrection, in: cleaned, with: "")
        cleaned = replacing(leadingFiller, in: cleaned, with: "")
        cleaned = replacing(embeddedFiller, in: cleaned, with: ",")
        return normalize(cleaned)
    }

    private static func matches(_ expression: NSRegularExpression, in input: String) -> Bool {
        expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil
    }

    private static func replacing(_ expression: NSRegularExpression, in input: String,
                                  with template: String) -> String {
        expression.stringByReplacingMatches(
            in: input,
            range: NSRange(input.startIndex..., in: input),
            withTemplate: template
        )
    }

    private static func normalizeLine(_ line: Substring) -> String {
        var output = ""
        output.reserveCapacity(line.utf8.count)
        var pendingSpace = false

        for scalar in line.unicodeScalars {
            if CharacterSet.whitespaces.contains(scalar) {
                pendingSpace = !output.isEmpty
                continue
            }
            let character = Character(scalar)
            if ",.!?;:%)]}".contains(character) {
                while output.last == " " { output.removeLast() }
                output.append(character)
                pendingSpace = true
            } else if "([{¿¡".contains(character) {
                if pendingSpace, !output.isEmpty { output.append(" ") }
                output.append(character)
                pendingSpace = false
            } else {
                if pendingSpace, !output.isEmpty { output.append(" ") }
                output.append(character)
                pendingSpace = false
            }
        }
        return output.trimmingCharacters(in: .whitespaces)
    }

    private static func normalizedComparisonWord(_ word: Substring) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
