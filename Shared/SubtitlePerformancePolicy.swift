import Foundation

/// Pure, bounded decisions for performance-sensitive subtitle acquisition.
/// The counters are session-local metadata; no recognized text is persisted.
enum SubtitlePerformancePolicy {
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
    /// every request: alternate opportunities so the policy can recover.
    /// Ordinary confirmed subtitles are not gated by this function.
    static func allowSpeculation(attempts: Int, discarded: Int, hits: Int,
                                 opportunity: Int, enabled: Bool) -> Bool {
        guard enabled, attempts >= 24 else { return true }
        let lost = Double(max(0, discarded)) / Double(max(attempts, 1))
        let useful = Double(max(0, hits)) / Double(max(attempts, 1))
        guard lost >= 0.55, useful < 0.18 else { return true }
        return opportunity.isMultiple(of: 2)
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
