import Foundation

// 2.5.1: Legacy latency work. Pure policy and switch definitions, no UI or engine state, so the ThreeModes test
// program compiles and tests it with the rest of TranslationSystem. Nothing here was measured on a device.

extension TranslationHotPathAB {
    /// 2.5.1 switches: (setting key, pinned key, report label). Default ON; OFF gives the 2.5.0 behaviour.
    static let v251Switches: [(setting: String, pinned: String, report: String)] = [
        ("legacyEagerSpeculation", "legacyEagerSpeculationPinned", "eagerSpeculationAB"),
        // 2.5.2
        ("finishRunningCaption", "finishRunningCaptionPinned", "finishRunningAB"),
        ("ocrDuplicateFilter", "ocrDuplicateFilterPinned", "duplicateLinesAB"),
        ("streamLegacyCalls", "streamLegacyCallsPinned", "streamCallsAB")
    ]
    /// Legacy only. A first reading that arrives while the previous confirmed caption is still being translated or
    /// waits to be shown is no longer dropped: its early translation is queued and starts the moment the model is
    /// free. Confirmed work always goes first; what is shown and when it is confirmed do not change.
    static var legacyEagerSpeculation: Bool {
        (UserDefaults.standard.object(forKey: "legacyEagerSpeculationPinned") as? Bool) ?? true
    }
    /// 2.5.2, Legacy only: a confirmed caption whose translation is already running is finished and shown when a
    /// newer caption is confirmed, instead of being thrown away. See `ConfirmedHandoffPolicy`.
    static var finishRunningCaption: Bool {
        (UserDefaults.standard.object(forKey: "finishRunningCaptionPinned") as? Bool) ?? true
    }
    /// 2.5.2, both modes, CHANGES WHAT IS READ: duplicate OCR lines of iOS 27 are dropped (`OCRDuplicateFilter`).
    static var ocrDuplicateFilter: Bool {
        (UserDefaults.standard.object(forKey: "ocrDuplicateFilterPinned") as? Bool) ?? true
    }
    /// 2.5.2, Legacy only: every live model call uses `translate(batch:)`, which Apple documents as returning sooner
    /// than `translations(from:)`. Same requests, same model, same order of results.
    static var streamLegacyCalls: Bool {
        (UserDefaults.standard.object(forKey: "streamLegacyCallsPinned") as? Bool) ?? true
    }
    static let v251ReportLabels: [(key: String, label: String)] = [
        ("eagerSpeculationAB", "eager early translation"),
        ("finishRunningAB", "finish running caption"),
        ("duplicateLinesAB", "duplicate OCR lines dropped"),
        ("streamCallsAB", "streamed Legacy calls")
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

/// 2.5.2: the Legacy drain runs one model call at a time, and a confirmed call is never cancelled (only early calls
/// are). So when caption B is confirmed while caption A's own call runs, B cannot start before that call returns.
/// Before 2.5.2, A was thrown away 0.45 to 0.9 s after it was confirmed (in the 2.5.0 runs 31 to 341 times per
/// session, "confirmed continuity loss") although its translation was about to arrive. Now B waits in the existing
/// one-slot handoff while A's call runs, A is shown, and B is replayed when the drain is free.
enum ConfirmedHandoffPolicy {
    /// Upper bound for the hold. The replay of a held caption must happen within 1.2 s of its arrival
    /// (`handleContent` drops older replays), so the deadline stays below that.
    static let maximumHold = 1.0

    /// No hold when a confirmed caption is still queued: then the running call belongs to an older caption, and
    /// holding would make the newer caption wait for one more call.
    static func holdWhileOwnCallRuns(enabled: Bool, busy: Bool, confirmedRunning: Bool, captionQueued: Bool) -> Double {
        enabled && busy && confirmedRunning && !captionQueued ? maximumHold : 0
    }
}
