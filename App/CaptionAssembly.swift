import Foundation

/// Shared assembly for model results and complete, exact RAM results.
struct CaptionTranslationUnit {
    var label: String?
    var sentences: [String]
    var out: [String?]
    var tokens: [(String, String)]
}

enum CaptionAssembly {
    /// Never expose a partial caption or substitute untranslated source for a miss.
    static func complete(_ blocks: [[CaptionTranslationUnit]], glossary: [(String, String)]) -> String? {
        guard !blocks.isEmpty else { return nil }
        var output: [String] = []
        for row in blocks {
            guard !row.isEmpty else { return nil }
            var lines: [String] = []
            for unit in row {
                guard !unit.sentences.isEmpty, unit.out.count == unit.sentences.count else { return nil }
                var body: [String] = []
                for value in unit.out {
                    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    body.append(value)
                }
                let restored = TextIntel.restore(body.joined(separator: " "), tokens: unit.tokens)
                lines.append(unit.label.map { "\($0): \(restored)" } ?? restored)
            }
            var block = lines.joined(separator: "\n")
            for (from, to) in glossary {
                block = block.replacingOccurrences(of: from, with: to, options: [.caseInsensitive])
            }
            output.append(block)
        }
        let result = output.joined(separator: "\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : result
    }
}
