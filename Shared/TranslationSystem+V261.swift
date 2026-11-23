import Foundation

// 2.6.1: looser reuse of saved translations. Pure policy and switch definitions, no UI or engine state, no
// reference to types from Shared.swift, so the ThreeModes, HotPathAB and memory test programs compile it.
// Nothing here was measured on a device; the 2.6.0 counter "differs only in case, punctuation or spacing" says how
// often it can apply.

extension TranslationHotPathAB {
    /// 2.6.1 switches: (setting key, pinned key, report label). Default ON; OFF gives the 2.6.0 behaviour.
    static let v261Switches: [(setting: String, pinned: String, report: String)] = [
        ("looseMemoryReuse", "looseMemoryReusePinned", "looseMemoryReuseAB")
    ]
    /// CHANGES WHAT IS SHOWN: when a unit is not saved exactly but a saved unit has the same letters and numbers
    /// (only case, punctuation or spacing differ), its saved translation is reused (with the final punctuation of
    /// the new source) instead of translating again. Only the exact translation still counts as confirmed memory.
    static var looseMemoryReuse: Bool {
        (UserDefaults.standard.object(forKey: "looseMemoryReusePinned") as? Bool) ?? true
    }
    static let v261ReportLabels: [(key: String, label: String)] = [
        ("looseMemoryReuseAB", "memory reuses translations that differ only in case, punctuation or spacing")
    ]
}

extension TranslationHotPathAB {
    /// Switches that a guard turned off for the rest of this session. Never saved: the next session starts clean
    /// (pinSettings clears it) and the setting the owner chose is not changed.
    static var sessionOff: Set<String> = []
}

/// Guards judge a switch from numbers the session measures about itself. Fixed limits, stated in the report.
enum SwitchGuard {
    static let growthMinimumHeld = 12
    static let growthDroppedShare = 0.6

    /// Growing-subtitle wait: most held readings were dropped because the screen had already moved on, so the wait
    /// delays captions that are then never shown at all.
    static func growthShouldTrip(held: Int, dropped: Int) -> Bool {
        held >= growthMinimumHeld && Double(dropped) >= growthDroppedShare * Double(held)
    }
}

enum LooseReuse {
    /// A shorter unit is too ambiguous to match without its punctuation or case.
    static let minimumCharacters = 8
    static let terminals: Set<Character> = [".", "!", "?", "…", "。", "！", "？", "‼", "⁉"]

    /// Letters and numbers of the text, lower case, canonical form: what two spellings of one unit have in common.
    static func key(_ text: String) -> String {
        CaptionSignals.key(text.precomposedStringWithCanonicalMapping)
    }

    /// The closing punctuation marks of the text ("" when it has none).
    static func terminal(_ text: String) -> String {
        var out = ""
        for ch in text.reversed() {
            if terminals.contains(ch) { out.insert(ch, at: out.startIndex) }
            else if ch.isWhitespace, out.isEmpty { continue }
            else { break }
        }
        return out
    }

    /// The saved translation with the closing punctuation of the new source instead of the saved one's.
    static func adapt(storedSource: String, storedTranslation: String, requestedSource: String) -> String {
        let have = terminal(storedSource), want = terminal(requestedSource)
        guard have != want else { return storedTranslation }
        var base = storedTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = base.last, terminals.contains(last) { base.removeLast() }
        base = base.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return storedTranslation }
        return base + want
    }
}
