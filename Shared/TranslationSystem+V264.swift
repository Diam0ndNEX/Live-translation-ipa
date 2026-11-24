import Foundation

// 2.6.4: display stability. Pure policy, no UI or engine state, no reference to types from Shared.swift.
// Device report 2.6.3 build 128: the same subtitle was shown four times in one second because OCR alternated
// between two readings that differ only in an accent (ã / ă), and a subtitle and a logo were shown in turn.
// Nothing here uses speaker labels, punctuation rules, languages or screen layout: only the text that was shown.
extension TranslationHotPathAB {
    static let v264Switches: [(setting: String, pinned: String, report: String)] = [
        ("stableDisplay", "stableDisplayPinned", "stableDisplayAB")
    ]
    static var stableDisplay: Bool {
        !sessionOff.contains("stableDisplay") && ((UserDefaults.standard.object(forKey: "stableDisplayPinned") as? Bool) ?? true)
    }
    static let v264ReportLabels: [(key: String, label: String)] = [
        ("stableDisplayAB", "the shown caption is kept when the new one differs only in accents, case or punctuation, or flips back within 2 s")
    ]
}

struct DisplayStability {
    /// A new caption that differs from the shown one only in accents, case, width, spacing or punctuation is not
    /// shown for this long after the shown one appeared.
    static let foldWindow = 6.0
    /// A caption that was shown within this window and comes back ...
    static let flapWindow = 8.0
    /// ... is not shown while the caption it would replace has been on screen for less than this.
    static let minimumDwell = 2.0
    static let remembered = 6

    enum Decision: Equatable { case show, holdVariant, holdFlip }
    struct Shown: Equatable { let key: String; let at: Double }
    private(set) var history: [Shown] = []

    /// Letters and numbers only, without accents, case or width: what two OCR readings of one line share.
    static func key(_ text: String) -> String {
        CaptionSignals.key(text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil))
    }

    func decide(_ text: String, now: Double) -> Decision {
        let k = Self.key(text)
        guard k.count >= 3, let current = history.last else { return .show }
        if k == current.key, now - current.at <= Self.foldWindow { return .holdVariant }
        if now - current.at < Self.minimumDwell,
           history.dropLast().contains(where: { $0.key == k && now - $0.at <= Self.flapWindow }) { return .holdFlip }
        return .show
    }

    mutating func shown(_ text: String, now: Double) {
        let k = Self.key(text)
        guard !k.isEmpty else { return }
        let last = history.last
        history.removeAll { now - $0.at > Self.flapWindow && $0 != last }
        history.append(Shown(key: k, at: now))
        if history.count > Self.remembered { history.removeFirst(history.count - Self.remembered) }
    }

    mutating func forget() { history.removeAll() }
}
