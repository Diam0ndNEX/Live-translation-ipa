import Foundation

/// 2.4.0: which model Hybrid Recovery uses for the next caption when the pinned-backend switch is on.
///
/// The 2.3.9 device report showed that the first Low Latency call after an Apple Default call (and the reverse) took
/// about 0.9 to 1.3 s, whatever the time gap, while calls that stayed on one model took 30 to 80 ms (Low Latency) or
/// about 300 ms (Apple Default). So the pin stays on one model for a run of captions: Low Latency while its language
/// pack is installed and working, Apple Default otherwise, and never back and forth caption by caption.
/// The cause inside iOS is not known; this is a scheduling rule, not a claim about model residency.
struct HybridBackendPin {
    /// How long Apple Default stays in use after a Low Latency request returned nothing. UNVERIFIED value.
    static let fallbackHold = 20.0

    /// Nil until the first caption of a context has been routed.
    private(set) var current: RequestedTranslationStrategy?
    private(set) var changes = 0
    private var defaultUntil = -Double.infinity

    /// What `strategy` would answer now, without recording a change.
    func peek(fastInstalled: Bool, now: Double) -> RequestedTranslationStrategy {
        (!fastInstalled || now < defaultUntil) ? .appleDefault : .lowLatency
    }

    /// The model for the next caption.
    mutating func strategy(fastInstalled: Bool, now: Double) -> RequestedTranslationStrategy {
        let next: RequestedTranslationStrategy =
            (!fastInstalled || now < defaultUntil) ? .appleDefault : .lowLatency
        if next != current {
            if current != nil { changes += 1 }
            current = next
        }
        return next
    }

    /// A Low Latency request for the current caption failed: stay on Apple Default for the hold time.
    mutating func noteLowLatencyFailure(now: Double) {
        defaultUntil = now + Self.fallbackHold
    }
}
