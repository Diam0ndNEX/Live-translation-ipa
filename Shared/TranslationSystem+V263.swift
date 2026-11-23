import Foundation

// 2.6.3: memory care. Pure policy, no UI or engine state, no reference to types from Shared.swift, so the
// ThreeModes and HotPathAB test programs compile and test it with the rest of TranslationSystem.
extension TranslationHotPathAB {
    /// One switch for both parts (default ON): saved translations are loaded into RAM at start, and a reused
    /// translation with a clear defect is sent back for a fresh translation. Applies from the next session.
    static let v263Switches: [(setting: String, pinned: String, report: String)] = [
        ("memoryCare", "memoryCarePinned", "memoryCareAB")
    ]
    static var memoryCare: Bool {
        !sessionOff.contains("memoryCare") && ((UserDefaults.standard.object(forKey: "memoryCarePinned") as? Bool) ?? true)
    }
    static let v263ReportLabels: [(key: String, label: String)] = [
        ("memoryCareAB", "saved translations preloaded and defective reuses retranslated")
    ]
}

enum MemoryCare {
    /// Saved units loaded into RAM when memory opens (the most recently used first).
    static let warmupLimit = 400
    /// A reused unit counts as part of the caption just shown when it was touched within this many RAM uses.
    static let recentTouches = 64
    /// A translation equal to its source is only a defect for a unit of at least this many words (names stay).
    static let unchangedMinimumWords = 3

    /// The source text of a unit key `v4|rules|src>tgt|n:context|text` (or the v2/v3 form without rules).
    static func unitSource(_ key: String) -> String? {
        let parts = key.split(separator: "|", maxSplits: key.hasPrefix("v4|") ? 4 : 3, omittingEmptySubsequences: false)
        let expected = key.hasPrefix("v4|") ? 5 : 4
        guard parts.count == expected else { return nil }
        return String(parts[expected - 1])
    }

    /// The prefix that every unit key of these rules and target language starts with, up to the source language.
    static func rulesPrefix(_ rules: String) -> String { "v4|\(rules)|" }

    /// The target language of a unit key, or nil.
    static func target(_ key: String) -> String? {
        let parts = key.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 5, let arrow = parts[2].firstIndex(of: ">") else { return nil }
        return String(parts[2][parts[2].index(after: arrow)...])
    }

    /// Clear defects of one saved unit's translation, judged from the two texts alone.
    static func defects(source: String, translation: String) -> [CaptionFlag] {
        var out: [CaptionFlag] = []
        let sk = CaptionSignals.key(source), tk = CaptionSignals.key(translation)
        let words = source.split(whereSeparator: { $0.isWhitespace }).count
        if sk.count >= 8, sk == tk, words >= unchangedMinimumWords { out.append(.unchanged) }
        let numbers = CaptionSignals.digitRuns(source)
        if !numbers.isEmpty, numbers.contains(where: { !translation.contains($0) }) { out.append(.digitsLost) }
        if CaptionSignals.repeatsWord(translation) { out.append(.repeatedWord) }
        return out
    }

    /// Caption flags that can point at a defective saved translation.
    static let quarantineFlags: Set<CaptionFlag> = [.unchanged, .digitsLost, .repeatedWord]
}
