import Foundation

/// Recognition behavior is a set of independently selectable capabilities.
/// The legacy "mode" is used only to migrate preferences that predate these
/// switches; running OCR never branches on a preset's name or category.
enum PresetRecognitionPolicy {
    static let rapidTextTracking = "rapidTextTracking"
    static let joinAdjacentText = "joinAdjacentText"
    static let activeTextFocus = "activeTextFocus"

    static func legacyDefaults(for mode: String) -> [String: Bool] {
        let subtitleStyle = mode == "movie"
        return [
            rapidTextTracking: subtitleStyle,
            joinAdjacentText: subtitleStyle,
            activeTextFocus: subtitleStyle
        ]
    }

    static func migrate(_ defaults: UserDefaults) {
        let inherited = legacyDefaults(for: defaults.string(forKey: "mode") ?? "movie")
        for (key, value) in inherited where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}

/// Pure, bounded decisions for performance-sensitive subtitle acquisition.
/// The counters are session-local metadata; no recognized text is persisted.
enum SubtitlePerformancePolicy {
    static func preemptSpeculation(activeText: String?, confirmedText: String) -> Bool {
        guard let activeText, !activeText.isEmpty, !confirmedText.isEmpty else { return false }
        return activeText != confirmedText
    }

    /// A second independent frame can be read sooner without reducing the
    /// configured number of reads, detail, confidence or correction. Only a
    /// pending Movie confirmation may borrow this short burst; pressure wins.
    static func confirmationInterval(planned: Double, pending: Bool, rapidTextTracking: Bool,
                                     pressure: Bool, processingMs: Double) -> Double {
        guard pending, rapidTextTracking, !pressure, processingMs.isFinite, processingMs > 0 else { return planned }
        // Use the last real OCR service time as the lower bound so the next
        // independent confirmation frame can start promptly without overlap.
        // A 100 ms nominal floor avoids high-frequency OCR under unusually
        // cheap frames; pressure and non-Movie scheduling remain untouched.
        return min(planned, max(0.10, processingMs / 1000))
    }

    /// One non-renewable grace period for an unpresented confirmed caption.
    /// Early replacements retain the old absolute 450ms deadline. Later ones
    /// get at most 120ms, and never beyond 900ms since confirmation.
    static func confirmedHandoffDelay(age: Double) -> Double {
        guard age.isFinite, age >= 0, age < 0.9 else { return 0 }
        return age < 0.45 ? 0.45 - age : min(0.12, 0.9 - age)
    }
    /// Give a previously confirmed subtitle a short, bounded chance to reach PiP
    /// when a newer *confirmed* candidate arrives. A long block cannot hold up
    /// genuinely new dialogue indefinitely.
    static func deferConfirmedReplacement(activeConfirmed: Bool,
                                          activePresented: Bool,
                                          incomingConfirmed: Bool,
                                          workPending: Bool,
                                          ageSeconds: TimeInterval,
                                          equivalent: Bool) -> Bool {
        activeConfirmed && !activePresented && incomingConfirmed && workPending &&
        !equivalent && ageSeconds >= 0 && ageSeconds < 0.45
    }

    /// Limit speculative model work when recent benefit is low. Never suppress
    /// every request: periodic opportunities let the policy recover.
    /// Ordinary confirmed subtitles are not gated by this function.
    static func allowSpeculation(attempts: Int, discarded: Int, hits: Int,
                                 opportunity: Int, enabled: Bool, savedMemoryDominant: Bool = false) -> Bool {
        guard enabled, attempts >= 24 else { return true }
        let lost = Double(max(0, discarded)) / Double(max(attempts, 1))
        let useful = Double(max(0, hits)) / Double(max(attempts, 1))
        guard lost >= 0.50, useful < 0.18 else { return true }
        // Familiar content gets fewer probes only after independent confirmed
        // reuse evidence. Unknown-content and temporary-bank behavior keep the
        // existing alternate-opportunity floor. Never suppress all probes.
        return opportunity.isMultiple(of: savedMemoryDominant ? 3 : 2)
    }

    /// Completed tentative output may seed RAM even after its caption was
    /// superseded. Only exact, fully contextualized keys can later reuse it;
    /// this never authorizes presentation or persistence. A settings/capture/
    /// cache mutation invalidates the context and rejects the entire batch.
    static func retainedSpeculativeResults(keys: [String], values: [String?]?,
                                          workContext: Int, currentContext: Int,
                                          reuseAllowed: Bool) -> [String: String] {
        guard reuseAllowed, workContext == currentContext, let values,
              !keys.isEmpty, keys.count == values.count else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in zip(keys, values) {
            guard !key.isEmpty, let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  result[key] == nil || result[key] == value else { return [:] }
            result[key] = value
        }
        return result
    }

    /// A previous confidently resolved source can be warmed ahead of capture
    /// without changing the actual OCR language selection. Invalid/stale
    /// predictions are ignored and the live language detection still decides.
    static func predictiveSource(selected: String, detected: String?,
                                 lastResolved: String?,
                                 ageSeconds: TimeInterval,
                                 enabled: Bool) -> String? {
        guard enabled, selected == "auto",
              detected == nil || detected == "–",
              let lastResolved, !lastResolved.isEmpty,
              lastResolved != "auto", lastResolved != "–",
              lastResolved.count <= 16,
              lastResolved.allSatisfy({ $0.isLetter || $0 == "-" }),
              ageSeconds >= 0, ageSeconds < 24 * 3600 else { return nil }
        return lastResolved
    }

    /// Prefer confirmed work, since queueing a new tentative candidate while
    /// a confirmed one is waiting can increase the long-tail latency.
    static func confirmedWorkHasPriority(confirmedQueued: Bool,
                                         translating: Bool) -> Bool {
        confirmedQueued || translating
    }
}

/// Runtime policy evidence is independent of diagnostic collection. A rolling
/// window recovers after a scene change; hits are counted per pipeline, not per
/// sentence (one pipeline can contain several sentences).
struct SpeculativeWorkWindow {
    private struct Sample {
        let id: UInt64
        var discarded: Bool?
        var reused = false
    }
    private var samples: [Sample] = []
    private var sequence: UInt64 = 0
    private var opportunities = 0
    private var confirmedSavedOutcomes: [Bool] = []

    var savedMemoryDominant: Bool {
        confirmedSavedOutcomes.count >= 24 &&
            confirmedSavedOutcomes.filter { $0 }.count * 4 >= confirmedSavedOutcomes.count * 3
    }

    /// Actual confirmed lookup outcomes, independent of diagnostics and model
    /// completion. Misses/session/speculative hits age out a familiar scene.
    mutating func recordConfirmedOutcome(saved: Bool) {
        confirmedSavedOutcomes.append(saved)
        if confirmedSavedOutcomes.count > 32 { confirmedSavedOutcomes.removeFirst() }
    }

    mutating func begin() -> UInt64 {
        sequence &+= 1
        samples.append(Sample(id: sequence))
        if samples.count > 32 { samples.removeFirst(samples.count - 32) }
        return sequence
    }
    mutating func finish(_ id: UInt64, discarded: Bool) {
        if let index = samples.firstIndex(where: { $0.id == id }) { samples[index].discarded = discarded }
    }
    mutating func reuse(_ id: UInt64) {
        if let index = samples.firstIndex(where: { $0.id == id }) { samples[index].reused = true }
    }
    mutating func allowsOpportunity(enabled: Bool) -> Bool {
        opportunities &+= 1
        let completed = samples.filter { $0.discarded != nil }
        return SubtitlePerformancePolicy.allowSpeculation(attempts: completed.count,
            discarded: completed.filter { $0.discarded == true }.count,
            hits: completed.filter { $0.reused }.count,
            opportunity: opportunities, enabled: enabled, savedMemoryDominant: savedMemoryDominant)
    }
}

