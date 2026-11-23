import Foundation

// 2.5.6: Legacy settles a subtitle that is still growing before it is translated and shown. Pure policy and
// switch definitions, no UI or engine state, and no reference to types from Shared.swift, so the ThreeModes and
// HotPathAB test programs compile and test it with the rest of TranslationSystem. Nothing here was measured on a
// device.

extension TranslationHotPathAB {
    /// 2.5.6 switches: (setting key, pinned key, report label). Default ON; OFF gives the 2.5.5 behaviour.
    static let v256Switches: [(setting: String, pinned: String, report: String)] = [
        ("growthSettle", "growthSettlePinned", "growthSettleAB")
    ]
    /// Legacy only, CHANGES WHEN A CAPTION IS TRANSLATED AND SHOWN: when a confirmed reading is the previous one
    /// with more text at the end (a subtitle that is typed or faded in), it waits until the text has stopped
    /// growing, then only the last state is translated. Nothing waits when the text is not growing.
    static var growthSettle: Bool {
        !sessionOff.contains("growthSettle") && ((UserDefaults.standard.object(forKey: "growthSettlePinned") as? Bool) ?? true)
    }
    static let v256ReportLabels: [(key: String, label: String)] = [
        ("growthSettleAB", "growing subtitles settle before translation")
    ]
}

/// 2.5.6: recognises growth from the text alone (no punctuation, label, language or screen-layout rule) and learns
/// the pace of the current video: how long the text usually stays unchanged between two growth steps. The wait
/// before a growing subtitle is translated is a little longer than that pace, so it is shorter for a fast reveal
/// and longer for a slow one, and it never exceeds a fixed total.
struct CaptionGrowthTracker {
    enum Step { case extended, same, different }

    static let minimumPreviousCharacters = 4
    /// Share of the previous text that must be the start of the new text (tolerates a misread letter).
    static let prefixShare = 0.85
    /// A reading older than this is not the "previous" subtitle any more.
    static let staleAfter = 2.5
    static let initialGap = 0.35
    static let minimumQuiet = 0.18
    static let maximumQuiet = 0.6
    /// The longest a subtitle can be held in total, however long it keeps growing.
    static let maximumTotal = 0.9
    static let quietFactor = 1.3

    private(set) var previous = ""
    private(set) var previousAt = -1000.0
    private(set) var lastGrowthAt = -1000.0
    private(set) var gap = CaptionGrowthTracker.initialGap

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        var count = 0
        var i = a.startIndex, j = b.startIndex
        while i < a.endIndex, j < b.endIndex, a[i] == b[j] {
            count += 1
            i = a.index(after: i)
            j = b.index(after: j)
        }
        return count
    }

    static func extends(_ current: String, _ previous: String) -> Bool {
        guard previous.count >= minimumPreviousCharacters, current.count > previous.count else { return false }
        return Double(commonPrefix(current, previous)) >= prefixShare * Double(previous.count)
    }

    /// Whether `text` would be growth of the last confirmed reading. Does not change anything.
    func wouldExtend(_ text: String, at now: Double) -> Bool {
        now - previousAt <= Self.staleAfter && Self.extends(text, previous)
    }

    /// Records a confirmed reading (normalized text) and says how it relates to the previous one.
    mutating func observe(_ text: String, at now: Double) -> Step {
        let fresh = now - previousAt <= Self.staleAfter
        if fresh, text == previous { previousAt = now; return .same }
        let grew = fresh && Self.extends(text, previous)
        if grew {
            if now - lastGrowthAt <= Self.staleAfter {
                gap = 0.6 * gap + 0.4 * max(0.05, min(1.5, now - lastGrowthAt))
            }
            lastGrowthAt = now
        }
        previous = text
        previousAt = now
        return grew ? .extended : .different
    }

    /// How long the text must stay unchanged before the last state is used.
    var quietPeriod: Double { min(Self.maximumQuiet, max(Self.minimumQuiet, Self.quietFactor * gap)) }

    /// The next wait, given how long the subtitle has been held already.
    func wait(elapsed: Double) -> Double { min(quietPeriod, max(0.05, Self.maximumTotal - elapsed)) }

    mutating func restart() { self = CaptionGrowthTracker() }
}
