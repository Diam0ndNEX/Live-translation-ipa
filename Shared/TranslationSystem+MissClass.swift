import Foundation

// 2.6.0: why a memory lookup missed. MEASUREMENT ONLY: nothing here changes what is translated or reused.
// A "near miss" is a miss whose source text differs from a unit already seen in this run only in case, punctuation
// or spacing. The count says how much a looser reuse could save before anyone builds it. Pure policy, no
// references to types from Shared.swift.

struct LooseUnitIndex {
    static let capacity = 3000
    /// Letters and numbers only, lower case, no spacing: the unit without case, punctuation and spacing.
    static func looseKey(_ text: String) -> String { CaptionSignals.key(text) }

    enum Kind: String { case new, nearMiss, repeatedExact }

    private var seen: [String: String] = [:]
    private var order: [String] = []

    /// Classifies a unit that missed memory and remembers it. A unit seen before in this run with the same text
    /// is `repeatedExact` (it was evicted or never stored); one that differs only in case, punctuation or
    /// spacing is `nearMiss`.
    mutating func classifyMiss(_ unit: String) -> Kind {
        let loose = Self.looseKey(unit)
        guard !loose.isEmpty else { return .new }
        defer { remember(unit, loose: loose) }
        guard let previous = seen[loose] else { return .new }
        return previous == unit ? .repeatedExact : .nearMiss
    }

    /// Units that hit memory are known too, so a later variant of them counts as a near miss.
    mutating func noteSeen(_ unit: String) {
        let loose = Self.looseKey(unit)
        if !loose.isEmpty { remember(unit, loose: loose) }
    }

    private mutating func remember(_ unit: String, loose: String) {
        if seen[loose] == nil { order.append(loose) }
        seen[loose] = unit
        if order.count > Self.capacity {
            let drop = order.count - Self.capacity
            for key in order.prefix(drop) { seen[key] = nil }
            order.removeFirst(drop)
        }
    }

    mutating func restart() { seen.removeAll(); order.removeAll() }
}
