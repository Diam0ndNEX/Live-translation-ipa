import Foundation

/// Shared, synchronous request preparation for Legacy and Hybrid Apple Default
/// speculation. This does not own an Apple session or serialize model lanes.
/// Identity is deliberately byte-for-byte compatible with existing v4 memory
/// keys so the SQLite and temporary memory formats need no migration.
enum SharedTranslationWork {
    @inline(__always)
    static func unitKey(source: String, target: String, text: String,
                        protectedWords: [String], rules: String) -> String {
        let context = protectedWords.map { "\($0.utf8.count):\($0)" }.joined()
        let version = protectedWords.isEmpty ? "v2" : "v3"
        if !rules.isEmpty { return "v4|\(rules)|\(source)>\(target)|\(context.utf8.count):\(context)|\(text)" }
        return "\(version)|\(source)>\(target)|\(context.utf8.count):\(context)|\(text)"
    }

    /// One model request per distinct unresolved exact-context unit, retaining
    /// original ordering. Duplicated lines still receive the corresponding
    /// response when the caller assembles its output.
    static func unresolvedIndices(keys: [String], values: [String?]) -> [Int]? {
        guard !keys.isEmpty, keys.count == values.count,
              !keys.contains(where: { $0.isEmpty }) else { return nil }
        var seen = Set<String>()
        return values.indices.filter { values[$0] == nil && seen.insert(keys[$0]).inserted }
    }

    /// This is only a volatile reuse gate. A cancelled request may finish on
    /// Apple's side; it never receives presentation authority from this helper.
    static func mayReuse(workEpoch: UUID, currentEpoch: UUID, requestedCancellation: Bool,
                         compatibleContext: Bool) -> Bool {
        workEpoch == currentEpoch && !requestedCancellation && compatibleContext
    }
}
