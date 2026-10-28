import Foundation

/// Conservative structural metadata. Classification never overrides canonical-key
/// compatibility or authorizes a remembered translation by itself.
enum MemoryUnitClassifier {
    enum Unit: String, CaseIterable, Codable, Sendable {
        case word, phrase, sentence, subtitleFragment = "subtitle_fragment", unknown
    }

    static let version = 1

    static func classify(_ original: String) -> Unit {
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 4096,
              text.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return .unknown }
        let lines = text.split(whereSeparator: { $0.isNewline })
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.count > 1 { return .subtitleFragment }
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return .unknown }
        if tokens.count == 1 {
            let acceptable = text.unicodeScalars.allSatisfy {
                CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0) ||
                $0 == "'" || $0 == "’" || $0 == "-"
            }
            return acceptable ? .word : .unknown
        }
        if let last = text.last, ".!?。！？؟".contains(last) { return .sentence }
        if text.hasSuffix("…") || text.hasSuffix("...") { return .subtitleFragment }
        if tokens.count >= 7 { return .subtitleFragment }
        return .phrase
    }
}
