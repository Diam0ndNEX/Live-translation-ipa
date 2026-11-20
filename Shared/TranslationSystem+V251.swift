import Foundation

// 2.5.1: Legacy latency work. Pure policy and switch definitions, no UI or engine state, so the ThreeModes test
// program compiles and tests it with the rest of TranslationSystem. Nothing here was measured on a device.

extension TranslationHotPathAB {
    /// 2.5.1 switches: (setting key, pinned key, report label). Default ON; OFF gives the 2.5.0 behaviour.
    static let v251Switches: [(setting: String, pinned: String, report: String)] = [
        ("legacyEagerSpeculation", "legacyEagerSpeculationPinned", "eagerSpeculationAB")
    ]
    /// Legacy only. A first reading that arrives while the previous confirmed caption is still being translated or
    /// waits to be shown is no longer dropped: its early translation is queued and starts the moment the model is
    /// free. Confirmed work always goes first; what is shown and when it is confirmed do not change.
    static var legacyEagerSpeculation: Bool {
        (UserDefaults.standard.object(forKey: "legacyEagerSpeculationPinned") as? Bool) ?? true
    }
    static let v251ReportLabels: [(key: String, label: String)] = [
        ("eagerSpeculationAB", "eager early translation")
    ]
}

/// 2.5.1: new defaults reach people who opened Experimental features before. Settings that were only ever stored
/// with the old default are cleared once, so the new default applies; the toggles still work afterwards.
enum LegacyV251Defaults {
    static let appliedKey = "legacyV251DefaultsApplied"
    /// Settings whose default changed in 2.5.1 (old default in brackets): deferArmedSpeculation (on),
    /// legacyConfirmedOwnLane (off).
    static let changedKeys = ["deferArmedSpeculation", "legacyConfirmedOwnLane"]

    static func applyOnce(_ defaults: UserDefaults) {
        guard defaults.object(forKey: appliedKey) as? Bool != true else { return }
        for key in changedKeys { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: appliedKey)
    }
}

/// 2.5.1: how the Legacy head start decides whether its quick read matched the confirmed caption.
/// 2.5.0 compared the two texts byte for byte, line breaks included. The quick and the normal read split lines
/// differently, so it was judged wrong 95 to 100 percent of the time in the 2.5.0 device runs and never started a
/// translation. The app joins the lines of one caption before it translates, so only the words and their order
/// matter. Letters, accents and punctuation still have to be identical: a different word is still a miss.
enum HeadStartText {
    static func key(_ texts: [String]) -> String {
        texts.joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func matches(_ quick: String, _ confirmed: String) -> Bool {
        !quick.isEmpty && key([quick]) == key([confirmed])
    }
}

/// 2.5.1: whether a Legacy first reading may wait behind confirmed work instead of being dropped.
enum EagerSpeculationPolicy {
    /// The early translation is kept for later only when nothing confirmed is waiting for the model, so it can
    /// never delay a confirmed caption: the drain always takes confirmed work first.
    static func mayQueueBehindConfirmed(enabled: Bool, busy: Bool, confirmedRunning: Bool,
                                        confirmedQueued: Bool) -> Bool {
        enabled && busy && confirmedRunning && !confirmedQueued
    }
}
