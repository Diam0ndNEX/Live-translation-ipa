import Foundation

/// Language evidence must not be biased toward whichever translation packs are installed.
struct SourceLanguageRouter {
    struct Choice {
        let code: String
        let origin: SourceLanguageOrigin
    }
    private(set) var locked: String?
    private var recent: [String] = []
    private var mismatches = 0

    static func canonical(_ code: String) -> String {
        Locale.Language(identifier: code).minimalIdentifier
    }
    static func sameLanguage(_ a: String, _ b: String) -> Bool {
        Locale.Language(identifier: a).languageCode == Locale.Language(identifier: b).languageCode
    }
    static func captureLanguage(selected: String, locked: String?) -> String {
        // Translation stabilization must never turn Automatic OCR into single-language OCR.
        selected
    }
    static func shouldDropTarget(selected: String, target: String, hypotheses: [String: Double], letters: Int) -> Bool {
        // Explicit source selection is authoritative, especially for short/related languages.
        guard selected == "auto", letters >= 32,
              let best = hypotheses.max(by: { $0.value < $1.value }),
              sameLanguage(best.key, target) else { return false }
        let other = hypotheses.filter { !sameLanguage($0.key, target) }.values.max() ?? 0
        return best.value >= 0.98 && best.value - other >= 0.8
    }
    mutating func reset() { self = SourceLanguageRouter() }

    mutating func resolve(hypotheses: [String: Double], target: String, letters: Int,
                          useLock: Bool, record: Bool) -> Choice? {
        // Speculative reads may use the lock but never acquire, release or vote for one.
        var next = self
        let choice = next.choose(hypotheses: hypotheses, target: target, letters: letters, useLock: useLock)
        if record { self = next }
        return choice
    }

    private mutating func choose(hypotheses: [String: Double], target: String, letters: Int, useLock: Bool) -> Choice? {
        if !useLock || locked.map({ Self.sameLanguage($0, target) }) == true { reset() }
        let ranked = hypotheses.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let best = ranked.first, best.value > 0 else {
            return useLock ? locked.map { Choice(code: $0, origin: .locked) } : nil
        }
        let code = Self.canonical(best.key)
        let nextScore = ranked.dropFirst().first?.value ?? 0
        let strong = best.value >= 0.65 && best.value - nextScore >= 0.25
        if useLock, let lock = locked {
            let lockScore = hypotheses.filter { Self.sameLanguage($0.key, lock) }.values.max() ?? 0
            if Self.sameLanguage(code, lock) || (!strong && (letters < 12 || lockScore >= 0.15)) {
                mismatches = 0
                return Choice(code: lock, origin: .locked)
            }
            // A clear language change is translated immediately, even during release hysteresis.
            mismatches += 1
            if mismatches >= 3 { reset() }
            else { return Choice(code: code, origin: .detected) }
        }
        // Target-language text may pass through, but can never become a source lock.
        if useLock && strong && letters >= 12 && !Self.sameLanguage(code, target) {
            recent.append(code)
            if recent.count > 6 { recent.removeFirst() }
            let count = recent.filter { $0 == code }.count
            if count >= 4 { locked = code; mismatches = 0 }
        }
        return Choice(code: code, origin: .detected)
    }
}
