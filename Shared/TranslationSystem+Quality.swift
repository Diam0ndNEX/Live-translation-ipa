import Foundation

// 2.6.0: automatic quality signals. Pure policy, no UI or engine state, no reference to types from Shared.swift,
// so the ThreeModes and HotPathAB test programs compile and test it with the rest of TranslationSystem.
// These are PROXIES: they find captions worth a human reading, they do not decide that a translation is wrong.
// Nothing here uses speaker labels, punctuation rules, language names or screen layout.

enum CaptionFlag: String, CaseIterable {
    /// The same sentence was shown again within a few seconds.
    case reshownSame = "reshown_same"
    /// A caption that starts like one shown moments ago, but differs: the same sentence rewritten on screen.
    case rewrittenSoon = "rewritten_soon"
    /// The translation is the source text (nothing was translated).
    case unchanged = "unchanged_from_source"
    /// A number (two or more digits) in the source is missing from the translation.
    case digitsLost = "digits_lost"
    /// The translation is much longer or shorter than this run's usual ratio for the language pair.
    case lengthOutlier = "length_outlier"
    /// The same word three or more times in a row in the translation.
    case repeatedWord = "repeated_word"
}

struct CaptionSignals {
    static let sameWindow = 8.0
    static let rewriteWindow = 4.0
    static let minimumCharacters = 12
    static let prefixShare = 0.6
    static let maximumRemembered = 6
    /// Samples before the length ratio is judged, and how far from this run's usual ratio counts as an outlier.
    static let ratioSamples = 30
    static let ratioSigmas = 3.0
    static let minimumSigma = 0.25

    struct Shown { let key: String; let at: Double }
    private(set) var recent: [Shown] = []
    private var ratioCount = 0.0, ratioMean = 0.0, ratioM2 = 0.0

    /// Letters and numbers only, lower case: the text without spacing, punctuation or case.
    static func key(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        var count = 0
        for (x, y) in zip(a, b) { if x == y { count += 1 } else { break } }
        return count
    }

    /// Runs of two or more ASCII digits.
    static func digitRuns(_ text: String) -> [String] {
        var runs: [String] = [], current = ""
        for ch in text {
            if ch.isASCII, ch.isNumber { current.append(ch) }
            else { if current.count >= 2 { runs.append(current) }; current = "" }
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    static func repeatsWord(_ text: String) -> Bool {
        var last = "", run = 0
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let word = key(String(raw))
            guard !word.isEmpty else { continue }
            if word == last { run += 1 } else { last = word; run = 1 }
            if run >= 3 { return true }
        }
        return false
    }

    /// Call once for each caption that was shown. `at` is a monotonic time in seconds.
    mutating func observe(original: String, translated: String, at: Double) -> [CaptionFlag] {
        var flags: [CaptionFlag] = []
        let tk = Self.key(translated), ok = Self.key(original)
        recent.removeAll { at - $0.at > Self.sameWindow }
        if tk.count >= 3, recent.contains(where: { $0.key == tk }) {
            flags.append(.reshownSame)
        } else if tk.count >= Self.minimumCharacters {
            let near = recent.contains { shown in
                guard at - shown.at <= Self.rewriteWindow, shown.key.count >= Self.minimumCharacters else { return false }
                let shortest = min(shown.key.count, tk.count)
                return Double(Self.commonPrefix(shown.key, tk)) >= Self.prefixShare * Double(shortest)
            }
            if near { flags.append(.rewrittenSoon) }
        }
        if ok.count >= 8, ok == tk { flags.append(.unchanged) }
        let sourceNumbers = Self.digitRuns(original)
        if !sourceNumbers.isEmpty, sourceNumbers.contains(where: { !translated.contains($0) }) { flags.append(.digitsLost) }
        if ok.count >= Self.minimumCharacters, tk.count > 0 {
            let ratio = log(Double(tk.count) / Double(ok.count))
            if ratioCount >= Double(Self.ratioSamples) {
                let sigma = max(Self.minimumSigma, (ratioM2 / (ratioCount - 1)).squareRoot())
                if abs(ratio - ratioMean) > Self.ratioSigmas * sigma { flags.append(.lengthOutlier) }
            }
            ratioCount += 1
            let delta = ratio - ratioMean
            ratioMean += delta / ratioCount
            ratioM2 += delta * (ratio - ratioMean)
        }
        if Self.repeatsWord(translated) { flags.append(.repeatedWord) }
        recent.append(Shown(key: tk, at: at))
        if recent.count > Self.maximumRemembered { recent.removeFirst(recent.count - Self.maximumRemembered) }
        return flags
    }

    /// The screen was cleared or the context changed: earlier captions are not "recent" any more (the learned ratio stays).
    mutating func forgetShown() { recent.removeAll() }

    mutating func restart() { recent.removeAll(); ratioCount = 0; ratioMean = 0; ratioM2 = 0 }
}
