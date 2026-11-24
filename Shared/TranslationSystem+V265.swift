import Foundation

// 2.6.5: lower and steadier latency. Pure policy, no UI or engine state, no reference to types from Shared.swift.
// Device report 2.6.3 build 128 (502 captions, Legacy): 326 captions had no early translation at all; the first
// reading was refused for "low confidence" 320 times. The model call then starts only at confirmation and is the
// longest stage (P50 363 ms for 330 captions). Nothing here was measured on a device: the next report shows, in the
// "Early start learning" table, how often a first reading was already the final text.
extension TranslationHotPathAB {
    /// 2.6.5 switches: (setting key, pinned key, report label). Default ON; OFF gives the 2.6.4 behaviour.
    static let v265Switches: [(setting: String, pinned: String, report: String)] = [
        ("learnedEarlyStart", "learnedEarlyStartPinned", "learnedEarlyStartAB"),
        ("quickHangLimit", "quickHangLimitPinned", "quickHangLimitAB")
    ]
    /// The confidence a first reading needs before its translation starts early is learned from this run: how often
    /// the first reading was exactly the text that was confirmed later, per confidence band. Off, the fixed setting
    /// (default 0.85) is used. A first reading whose text turns out different only wastes one quiet call.
    static var learnedEarlyStart: Bool {
        !sessionOff.contains("learnedEarlyStart") && ((UserDefaults.standard.object(forKey: "learnedEarlyStartPinned") as? Bool) ?? true)
    }
    /// A model call that does not return is given up on sooner (floor 3.5 s instead of 6 s, 4 times the slow end
    /// instead of 6 times). The longest call that returned in report 2.6.3 build 128 took 2.7 s.
    static var quickHangLimit: Bool {
        (UserDefaults.standard.object(forKey: "quickHangLimitPinned") as? Bool) ?? true
    }
    static let v265ReportLabels: [(key: String, label: String)] = [
        ("learnedEarlyStartAB", "early translation confidence learned from this run"),
        ("quickHangLimitAB", "hung translation calls given up on after about 3.5 s")
    ]
}

/// Learns, from first readings that were later confirmed, how sure OCR must be for the first reading to be the final
/// text. Every first reading is recorded (also those that were refused), so the sample is not biased by the setting.
/// Nothing depends on a language, a video or a screen position.
struct SpecConfidenceLearner {
    static let floor = 0.55
    static let ceiling = 0.95
    /// Samples needed before anything is learned, and in one band before it counts.
    static let minimumSamples = 24
    static let minimumPerBand = 8
    /// Share of first readings, at or above a threshold, that must have been the final text.
    static let requiredMatchRate = 0.9
    static let window = 160
    static let step = 0.05

    struct Sample: Equatable { let confidence: Double; let matched: Bool }
    private(set) var samples: [Sample] = []
    private(set) var recordedTotal = 0
    private(set) var matchedTotal = 0

    mutating func record(confidence: Double, matched: Bool) {
        guard confidence.isFinite else { return }
        samples.append(Sample(confidence: min(1, max(0, confidence)), matched: matched))
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
        recordedTotal += 1
        if matched { matchedTotal += 1 }
    }

    /// The lowest confidence at or above which at least `requiredMatchRate` of the first readings were the final
    /// text (with enough samples), kept between floor and ceiling. Without enough samples, or when no threshold
    /// qualifies, `fallback` (the fixed setting) is returned unchanged.
    func threshold(fallback: Double) -> Double {
        guard samples.count >= Self.minimumSamples else { return fallback }
        // Whole hundredths, so that 0.60 is exactly 0.6 and no confidence falls out of a band by rounding.
        let low = Int((Self.floor * 100).rounded()), high = Int((Self.ceiling * 100).rounded())
        let stepHundredths = max(1, Int((Self.step * 100).rounded()))
        for hundredths in stride(from: low, through: high, by: stepHundredths) {
            let candidate = Double(hundredths) / 100
            let above = samples.filter { $0.confidence >= candidate }
            if above.count >= Self.minimumPerBand,
               Double(above.filter(\.matched).count) / Double(above.count) >= Self.requiredMatchRate {
                return candidate
            }
        }
        return fallback
    }

    mutating func forget() { samples.removeAll() }
}

/// What a first reading looked like, kept until its caption is confirmed or forgotten.
struct FirstReadingNote: Equatable {
    let confidence: Double
    let identity: String
}

/// The first reading of every caption, by candidate. Small and bounded.
struct FirstReadingBook {
    static let capacity = 12
    private(set) var notes: [String: FirstReadingNote] = [:]
    private var order: [String] = []

    /// Only the first reading of a candidate counts: that is the one an early translation would start from.
    /// Returns the notes pushed out by the capacity limit: first readings whose caption was never confirmed.
    @discardableResult
    mutating func noteFirst(candidate: String, confidence: Double, identity: String) -> [FirstReadingNote] {
        guard notes[candidate] == nil else { return [] }
        notes[candidate] = FirstReadingNote(confidence: confidence, identity: identity)
        order.append(candidate)
        var evicted: [FirstReadingNote] = []
        while order.count > Self.capacity {
            if let old = notes.removeValue(forKey: order.removeFirst()) { evicted.append(old) }
        }
        return evicted
    }

    /// Returns the first reading of the candidate once, and forgets it.
    mutating func take(candidate: String) -> FirstReadingNote? {
        guard let note = notes.removeValue(forKey: candidate) else { return nil }
        order.removeAll { $0 == candidate }
        return note
    }

    mutating func forget() { notes.removeAll(); order.removeAll() }
}
