import Foundation

/// Policy for converting OCR text into durable, reusable translation units.
/// The NaturalLanguage sentence tokenizer provides *candidates*, not authority:
/// OCR line breaks, lyrics, abbreviations and ellipses must not silently
/// transform unfinished fragments into independently reusable sentences.
enum TranslationUnitPlanning {
    static let version = 2
    static let maxUnits = 12

    /// Only split where a candidate ends with unequivocal sentence punctuation.
    /// A multi-line subtitle without completed sentence boundaries remains one
    /// unit so translation retains its context and PiP can render all lines at once.
    static func units(source: String, candidates: [String]) -> [String] {
        let original = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return [] }
        guard original.count <= 4096, candidates.count > 1,
              candidates.count <= maxUnits * 4 else { return [original] }

        // Avoid splitting scrolling lyrics, incomplete dialogue and OCR fragments.
        // A newline is not a sentence boundary by itself.
        let filtered = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard filtered.count > 1 else { return [original] }

        let terminators = CharacterSet(charactersIn: ".!?。！？؟")
        var units: [String] = []
        var pending = ""
        for (index, fragment) in filtered.enumerated() {
            if !pending.isEmpty { pending += " " }
            pending += fragment
            // Do not treat ellipses as completed sentences; they can signal a
            // subtitle that is still being revealed.
            let isEllipsis = pending.hasSuffix("...") || pending.hasSuffix("…")
            let lastScalar = pending.unicodeScalars.last
            let hasBoundary = lastScalar.map { terminators.contains($0) } ?? false
            if !isEllipsis && hasBoundary && index < filtered.count - 1 && units.count < maxUnits - 1 {
                units.append(pending)
                pending = ""
            }
        }
        if !pending.isEmpty { units.append(pending) }
        // The tokenizer can include abbreviations as separate candidates.
        // Never split a source into units that obviously lost material.
        let sourceAlphanumeric = original.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined().precomposedStringWithCanonicalMapping
        let resultAlphanumeric = units.joined().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined().precomposedStringWithCanonicalMapping
        guard sourceAlphanumeric == resultAlphanumeric, !units.isEmpty,
              units.count <= maxUnits else { return [original] }
        return units
    }

    /// Preserve all confirmed categories but reject malformed/nonlinguistic
    /// entries. Classification is structural metadata, not evidence of
    /// semantic equivalence or permission to substitute individual words.
    static func mayRemember(_ text: String, confirmed: Bool) -> Bool {
        guard confirmed else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 16 * 1024 else { return false }
        return MemoryUnitClassifier.classify(trimmed) != .unknown
    }
}
