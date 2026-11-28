import Foundation

// 2.8.0: capture beside ScreenLingo, one subtitle shown once, shorter growth wait, cost-aware early start.
// Pure policy, no UI or engine state, no reference to types from Shared.swift (the Swift tests compile without it). Evidence: device report 2.7.1 build 132 (iPad, 9.9 min, Legacy): translations
// stopped after 5.5 min while the capture link stayed alive; 54 captions were rewritten within 4 s; about 20
// captions waited 450-650 ms for a growing subtitle; 70 % of first readings were already the final text but the
// learner needs 90 % and never moved. Nothing here was compiled or measured when it was written.
extension TranslationHotPathAB {
    /// 2.8.0 switches: (setting key, pinned key, report label). Default ON; OFF gives the 2.7.2 behaviour.
    static let v280Switches: [(setting: String, pinned: String, report: String)] = [
        ("ownWindowCapture", "ownWindowCapturePinned", "ownWindowCaptureAB"),
        ("stableTranslation", "stableTranslationPinned", "stableTranslationAB"),
        ("growthPunctuationRelease", "growthPunctuationReleasePinned", "growthPunctuationReleaseAB"),
        ("costAwareEarlyStart", "costAwareEarlyStartPinned", "costAwareEarlyStartAB")
    ]
    /// The capture keeps reading the screen while ScreenLingo shares it (iPad Split View, Stage Manager, Slide Over)
    /// and ignores text inside ScreenLingo's own window. Off: any visible ScreenLingo window pauses the capture.
    static var ownWindowCapture: Bool {
        (UserDefaults.standard.object(forKey: "ownWindowCapturePinned") as? Bool) ?? true
    }
    /// A new translation that says the same as the shown one is not drawn again.
    static var stableTranslation: Bool {
        !sessionOff.contains("stableTranslation") && ((UserDefaults.standard.object(forKey: "stableTranslationPinned") as? Bool) ?? true)
    }
    /// A growing subtitle that ends a sentence is used at once; the total wait is at most 0.6 s.
    static var growthPunctuationRelease: Bool {
        (UserDefaults.standard.object(forKey: "growthPunctuationReleasePinned") as? Bool) ?? true
    }
    /// The early-start learner asks for less certainty when a wasted early call is cheap on this device.
    static var costAwareEarlyStart: Bool {
        !sessionOff.contains("costAwareEarlyStart") && ((UserDefaults.standard.object(forKey: "costAwareEarlyStartPinned") as? Bool) ?? true)
    }
    static let v280ReportLabels: [(key: String, label: String)] = [
        ("ownWindowCaptureAB", "capture keeps running beside ScreenLingo and skips its window"),
        ("stableTranslationAB", "a translation that says the same as the shown one is not drawn again"),
        ("growthPunctuationReleaseAB", "a growing subtitle that ends a sentence is used at once, wait at most 0.6 s"),
        ("costAwareEarlyStartAB", "early translation asks for less certainty when a wasted call is cheap")
    ]
}

/// ScreenLingo's own window on the screen, as fractions of the screen: [x, y, width, height], origin top left.
enum OwnWindowCapture {
    /// A window covering at least this share of the screen is treated as full screen: the capture pauses.
    static let fullScreenShare = 0.85

    static func valid(_ window: [Double]?) -> [Double]? {
        guard let w = window, w.count == 4, w.allSatisfy({ $0.isFinite }), w[2] > 0, w[3] > 0 else { return nil }
        return w
    }

    static func coveredShare(_ window: [Double]?) -> Double {
        guard let w = valid(window) else { return 1 }
        let x0 = max(0, w[0]), y0 = max(0, w[1]), x1 = min(1, w[0] + w[2]), y1 = min(1, w[1] + w[3])
        return max(0, x1 - x0) * max(0, y1 - y0)
    }

    /// True when the capture must not read at all. Unknown window or a rotated capture: pause (the old rule).
    static func pausesAll(visible: Bool, window: [Double]?, rotated: Bool) -> Bool {
        guard visible else { return false }
        guard !rotated, valid(window) != nil else { return true }
        return coveredShare(window) >= fullScreenShare
    }

    /// True when an OCR line (x from the left, y from the bottom, both 0...1) lies inside ScreenLingo's window.
    static func excludes(x: Double, yFromBottom: Double, window: [Double]?) -> Bool {
        guard let w = valid(window) else { return false }
        let top = 1 - yFromBottom
        return x >= w[0] && x <= w[0] + w[2] && top >= w[1] && top <= w[1] + w[3]
    }
}

/// The translation on screen is kept when a new reading of the same subtitle translates to the same thing, apart
/// from OCR noise. Every reading is still translated; only the redraw is skipped. Real changes are always shown.
struct TranslationStability {
    /// Only a translation shown at most this long ago can be kept.
    static let window = 6.0
    /// Character-bigram similarity of the two translations (letters and numbers only).
    static let similarity = 0.85
    /// A source with this much more text than the shown one is a more complete reading: show it.
    static let moreComplete = 1.2
    /// Words that turn a sentence around. A change in these is always shown.
    static let negations: Set<String> = [
        "não", "nao", "nunca", "nem", "nenhum", "nenhuma", "ninguém", "ninguem", "jamais", "nada",
        "not", "no", "never", "nothing", "nobody", "none", "neither", "nor", "cannot",
        "nicht", "kein", "keine", "nie", "nichts", "ne", "pas", "rien", "non", "nadie"
    ]

    struct Shown: Equatable {
        let translation: String
        let sourceLetters: Int
        let numbers: [String]
        let negations: [String]
        let at: Double
    }
    private(set) var shown: Shown?

    static func letters(_ text: String) -> Int { text.filter { $0.isLetter || $0.isNumber }.count }

    /// Letters and numbers only, lowercased (as in the app's text similarity, which the Swift tests cannot see).
    static func norm(_ text: String) -> String { String(text.lowercased().filter { $0.isLetter || $0.isNumber }) }

    /// Jaccard similarity of character bigrams of the two normalized texts.
    static func similar(_ a: String, _ b: String, _ threshold: Double) -> Bool {
        let x = norm(a), y = norm(b)
        if x == y { return !x.isEmpty }
        func grams(_ s: String) -> Set<String> {
            let c = Array(s)
            guard c.count > 1 else { return c.isEmpty ? [] : [String(c)] }
            return Set((0..<(c.count - 1)).map { String(c[$0...($0 + 1)]) })
        }
        let gx = grams(x), gy = grams(y)
        let union = gx.union(gy).count
        return union > 0 && Double(gx.intersection(gy).count) / Double(union) >= threshold
    }

    static func numbers(_ text: String) -> [String] {
        var out: [String] = [], current = ""
        for ch in text {
            if ch.isNumber { current.append(ch) } else if !current.isEmpty { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func negationWords(_ text: String) -> [String] {
        let lowered = text.lowercased()
        var words = lowered.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { negations.contains($0) }
        if lowered.contains("n't") || lowered.contains("n’t") { words.append("n't") }
        return words.sorted()
    }

    /// True when the new reading may keep the shown translation instead of drawing its own.
    func holds(source: String, translation: String, now: Double) -> Bool {
        guard let s = shown, now - s.at <= Self.window, now >= s.at else { return false }
        guard Self.norm(translation).count >= 3, Self.norm(s.translation).count >= 3 else { return false }
        guard Self.similar(translation, s.translation, Self.similarity) else { return false }
        // Numbers and negations of source and translation together must be exactly the same.
        guard Self.numbers(source + " " + translation) == s.numbers,
              Self.negationWords(source + " " + translation) == s.negations else { return false }
        guard Double(Self.letters(source)) <= Double(max(1, s.sourceLetters)) * Self.moreComplete else { return false }
        return true
    }

    mutating func record(source: String, translation: String, now: Double) {
        shown = Shown(translation: translation, sourceLetters: Self.letters(source),
                      numbers: Self.numbers(source + " " + translation),
                      negations: Self.negationWords(source + " " + translation), at: now)
    }

    mutating func forget() { shown = nil }
}

/// A growing subtitle that already ends a sentence is complete: there is nothing left to wait for.
enum GrowthRelease {
    static let maximumTotal = 0.6
    static let enders: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]

    static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]"))
        guard let last = trimmed.last else { return false }
        return enders.contains(last)
    }

    /// The next wait with the shorter total cap.
    static func wait(_ planned: Double, elapsed: Double) -> Double {
        min(planned, max(0.05, maximumTotal - elapsed))
    }
}

/// How sure the first readings must be (share that were the final text) before early translations start,
/// depending on what a wasted early call costs on this device in this run.
enum CostAwareEarlyStart {
    /// A median model call at or below this is cheap (iPad b132: 58 ms).
    static let cheapCallSeconds = 0.15
    static let cheapRate = 0.7
    static let costlyRate = 0.8

    static func requiredMatchRate(medianModelSeconds: Double?) -> Double {
        guard let m = medianModelSeconds, m.isFinite, m > 0 else { return SpecConfidenceLearner.requiredMatchRate }
        return m <= cheapCallSeconds ? cheapRate : costlyRate
    }
}

extension ModelStallLimit {
    /// Median of recent successful model calls, in seconds (nil before five calls).
    var median: Double? {
        guard recent.count >= 5 else { return nil }
        let sorted = recent.sorted()
        return sorted[sorted.count / 2]
    }
}

extension SpecConfidenceLearner {
    /// Same as `threshold(fallback:)` with a different required share of first readings that were the final text.
    func threshold(fallback: Double, requiredMatchRate rate: Double) -> Double {
        guard samples.count >= Self.minimumSamples else { return fallback }
        let low = Int((Self.floor * 100).rounded()), high = Int((Self.ceiling * 100).rounded())
        let stepHundredths = max(1, Int((Self.step * 100).rounded()))
        for hundredths in stride(from: low, through: high, by: stepHundredths) {
            let candidate = Double(hundredths) / 100
            let above = samples.filter { $0.confidence >= candidate }
            if above.count >= Self.minimumPerBand,
               Double(above.filter(\.matched).count) / Double(above.count) >= rate {
                return candidate
            }
        }
        return fallback
    }
}
