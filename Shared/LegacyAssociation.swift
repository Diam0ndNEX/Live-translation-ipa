import Foundation

/// Discovery only: similarity must never authorize a legacy translation for live reuse.
/// Use byte-safe exact keys for reuse, and independent current-model output to reconcile.
enum LegacyAssociationKind: String, Codable, Sendable {
    case none, exact, orthographic, ocrCandidate, fragment
}

enum LegacyAssociation {
    private static func chars(_ text: String) -> [Character] {
        Array(text.precomposedStringWithCanonicalMapping.lowercased())
            .filter { $0.isLetter || $0.isNumber }
    }
    private static func words(_ text: String) -> [String] {
        text.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
    private static func nearByOne(_ a: [Character], _ b: [Character]) -> Bool {
        guard min(a.count, b.count) >= 23,
              abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, differences = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            differences += 1
            if differences > 1 { return false }
            if a.count > b.count { i += 1 }
            else if a.count < b.count { j += 1 }
            else { i += 1; j += 1 }
        }
        return differences + (a.count - i) + (b.count - j) <= 1
    }
    private static func containsWholeWords(_ long: [String], _ short: [String]) -> Bool {
        guard short.count >= 2, short.joined().count >= 12,
              short.count < long.count, long.count <= 80 else { return false }
        for start in 0...(long.count-short.count) {
            if Array(long[start..<(start+short.count)]) == short { return true }
        }
        return false
    }

    static func classify(old: String, new: String) -> LegacyAssociationKind {
        guard !old.isEmpty && !new.isEmpty,
              old.count <= 500 && new.count <= 500 else { return .none }
        if old == new { return .exact }
        let a = chars(old), b = chars(new)
        guard !a.isEmpty && !b.isEmpty else { return .none }
        if a == b && a.count >= 6 { return .orthographic }
        if nearByOne(a, b) { return .ocrCandidate }
        let x = words(old), y = words(new)
        if containsWholeWords(x, y) || containsWholeWords(y, x) {
            return .fragment
        }
        return .none
    }
}
