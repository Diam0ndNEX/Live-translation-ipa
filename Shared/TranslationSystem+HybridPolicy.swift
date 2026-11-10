import Foundation

/// Internal-only A/B strategies. These never change the user's translation
/// system or permit tentative text to be displayed before confirmation.
enum HybridSchedulerVariant: String {
    case reference195
    case recoveryFirst
    case evidenceBounded
}

enum HybridSchedulingPolicy {
    /// Admission must be validated again after any asynchronous availability
    /// check. H0 faithfully preserves the old physical-call admission; H1/H2
    /// yield unstarted Apple Default work to already-demanded confirmed LL.
    static func maySubmitDefaultAfterAvailability(variant: HybridSchedulerVariant,
                                                   confirmedDemand: Bool) -> Bool {
        variant == .reference195 || !confirmedDemand
    }

    /// 2.2.1 (D13): the variant is a run-time setting (Advanced > Experimental features), copied into a pinned value
    /// when a session starts so a change applies from the next session and never mid-run. The compile flags still
    /// override it for the CI reference builds. These are internal A/B variants, not user-facing modes.
    static let settingKey = "hybridSchedulerVariant"
    static let pinnedKey = "hybridSchedulerVariantPinned"

    static func configuredVariant(_ defaults: UserDefaults = .standard) -> HybridSchedulerVariant {
        defaults.string(forKey: settingKey).flatMap(HybridSchedulerVariant.init(rawValue:)) ?? .evidenceBounded
    }

    /// Called when a session starts.
    static func pinSetting(_ defaults: UserDefaults = .standard) {
        defaults.set(configuredVariant(defaults).rawValue, forKey: pinnedKey)
    }

    static var buildVariant: HybridSchedulerVariant {
        #if SCREENLINGO_HYBRID_REFERENCE
        return .reference195
        #elseif SCREENLINGO_HYBRID_RECOVERY_FIRST
        return .recoveryFirst
        #else
        return UserDefaults.standard.string(forKey: pinnedKey).flatMap(HybridSchedulerVariant.init(rawValue:)) ?? .evidenceBounded
        #endif
    }

    /// Restore the bounded v1.9.6 matching deadline: the premature 25ms
    /// hedge in v1.9.7 correlated with slow overlapping model requests.
    static func preflightWait(variant: HybridSchedulerVariant, submitted: Bool,
                              fastRecoveryInstalled: Bool, proposed: Double) -> Double {
        guard proposed.isFinite else { return 0 }
        return max(0, proposed)
    }

    /// Wait briefly for an actual Default call to release its physical lane
    /// before initiating an independent confirmed Low Latency model call.
    /// The budget is finite even if Apple's cancellation is slow to return.
    static func physicalDrainBudget(variant: HybridSchedulerVariant,
                                    speculativeActive: Bool) -> Double {
        guard variant != .reference195, speculativeActive else { return 0 }
        return 0.45
    }

    /// iPhone traces show many 900ms confirmed LL calls beginning less than
    /// 150ms after a Default call returned, even with no logical overlap.
    /// A bounded pair-specific settling interval is an experiment, not a
    /// claim about Apple's internal scheduling or processor allocation.
    /// Never block standalone Low Latency, Legacy, or a cold/unknown pair.
    static func postDefaultSettlement(variant: HybridSchedulerVariant,
                                      millisecondsSinceReturn: Double?) -> Double {
        #if SCREENLINGO_REFERENCE_HYBRID_EXIT_SETTLING
        return 0
        #else
        // 2.2.3 (L4): the arm shortens the settling window from 220 to 120 ms. UNVERIFIED value.
        let window = TranslationHotPathAB.hybridShorterGuard ? 120.0 : 220.0
        guard variant != .reference195, let age = millisecondsSinceReturn,
              age.isFinite, age >= 0, age < window else { return 0 }
        return min(window / 1000, max(0, (window - age) / 1000))
        #endif
    }

    /// v2.0.0 switch guard window. Device traces (builds 74-81) showed a
    /// Low Latency recovery at ~40 ms alone but ~900-1200 ms while an Apple
    /// Default call was running or had returned less than ~1.5 s earlier.
    /// This is a measured correlation, not a proven Apple mechanism.
    static let switchGuardWindowMs = 1500.0
    /// 2.2.3 (L4): the arm uses 1000 ms instead of 1500 ms. UNVERIFIED value; Low Latency is only chosen
    /// when the fast pack is installed and the guard gap has already passed.
    static var effectiveSwitchGuardWindowMs: Double {
        TranslationHotPathAB.hybridShorterGuard ? 1000.0 : switchGuardWindowMs
    }

    /// Choose the confirmed Hybrid recovery strategy. `gapMs` is 0 while an
    /// Apple Default call is in flight, the time since the last same-pair
    /// Default return, or nil when none is known. Inside the window recover
    /// with Apple Default instead of switching models; otherwise keep the fast
    /// isolated Low Latency case. A missing fast pack always uses Default.
    static func recoveryStrategy(gapMs: Double?, fastRecoveryInstalled: Bool,
                                 guardEnabled: Bool) -> RequestedTranslationStrategy {
        guard fastRecoveryInstalled else { return .appleDefault }
        guard guardEnabled, let gapMs, gapMs.isFinite, gapMs >= 0,
              gapMs < effectiveSwitchGuardWindowMs else { return .lowLatency }
        return .appleDefault
    }

    /// v2.0.0: with the switch guard on, Hybrid does not start a parallel Low
    /// Latency hedge beside a matching running Default call. It waits for that
    /// call up to this ceiling, measured from speculation start.
    static let suppressedHedgeCeiling = 1.2

    static func suppressedHedgeWait(elapsed: Double) -> Double {
        guard elapsed.isFinite else { return 0 }
        return max(0, suppressedHedgeCeiling - max(0, elapsed))
    }

    static func matchingWait(variant: HybridSchedulerVariant,
                             elapsed: Double, defaultSamples: [Double],
                             lowSamples: [Double], oldWait: Double,
                             recentContention: Int) -> Double {
        guard elapsed.isFinite, oldWait.isFinite else { return 0 }
        if variant != .evidenceBounded { return max(0, min(0.7, oldWait)) }
        let defaultValid = defaultSamples.filter { $0.isFinite && $0 > 0 }.suffix(32).sorted()
        let lowValid = lowSamples.filter { $0.isFinite && $0 > 0 }.suffix(32).sorted()
        // Without enough evidence use the proven bounded reference deadline.
        guard defaultValid.count >= 4 else { return max(0, min(0.7, oldWait)) }
        let predicted = defaultValid[min(defaultValid.count - 1, (defaultValid.count * 3) / 4)]
        let remaining = max(0, predicted - max(0, elapsed))
        let lowMedian = lowValid.isEmpty ? 0.15 : lowValid[lowValid.count / 2]
        // Favor a verified fast LL recovery when no contention has been
        // observed and Default is far from likely completion.
        if recentContention == 0 && lowValid.count >= 4 &&
            lowMedian <= 0.12 && remaining > max(0.08, lowMedian * 1.5) {
            // The fast confirmed strategy is expected to finish well before
            // Default. A fixed 450ms gate incorrectly delayed 40ms LL
            // recoveries behind predicted 250-400ms speculation.
            return 0
        }
        // When overlap has correlated with expensive LL work, let a matching
        // already-running Apple Default call get a short bounded head start.
        if recentContention > 0 && remaining > 0 {
            return min(0.58, max(0.08, remaining))
        }
        return min(0.45, max(0, remaining))
    }
}

/// A bounded feedback controller; never changes Legacy or the explicit Low Latency mode.
/// A successful speculative display clears backoff; repeated wasted speculation uses
/// fast confirmed Low Latency instead of competing Apple Default inference.
struct HybridAdmissionPolicy {
    private(set) var consecutiveWaste = 0
    private(set) var skipped = 0
    private(set) var rejected = 0
    private(set) var recentContention = 0
    private var lastRejectedIdentity: String?
    /// 2.2.3 (L3): when the relaxed-backoff arm is on, a backoff older than this many seconds is dropped. UNVERIFIED value.
    private var skipSetAt: Double?
    static let relaxedBackoffMaxAge = 10.0

    /// A repeated OCR packet must not exhaust a backoff intended to cover
    /// distinct subtitle candidates. Identity contains metadata, never text.
    mutating func admit(identity: String? = nil, now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        if TranslationHotPathAB.hybridRelaxedBackoff, skipped > 0, let set = skipSetAt,
           now - set > Self.relaxedBackoffMaxAge {
            skipped = 0; skipSetAt = nil; lastRejectedIdentity = nil
        }
        if let identity, identity == lastRejectedIdentity { return false }
        guard skipped > 0 else {
            lastRejectedIdentity = nil
            return true
        }
        skipped -= 1
        rejected += 1
        lastRejectedIdentity = identity
        return false
    }

    mutating func record(used: Bool) {
        if used {
            consecutiveWaste = 0
            skipped = 0
            recentContention = max(0, recentContention - 1)
            lastRejectedIdentity = nil
            return
        }
        consecutiveWaste += 1
        if consecutiveWaste >= 3 {
            // 2.2.3 (L3): the arm skips 4 instead of 8 early requests. UNVERIFIED value.
            skipped = max(skipped, TranslationHotPathAB.hybridRelaxedBackoff ? 4 : 8)
            skipSetAt = ProcessInfo.processInfo.systemUptime
            consecutiveWaste = 0
        }
    }

    /// Recovery service includes time after speculation has finished. Never
    /// treat the entire service duration as proof of simultaneous contention.
    /// Repeated wasted requests are handled independently by record(used:).
    mutating func recordRecovery(serviceMilliseconds: Double, simultaneousMilliseconds: Double) {
        guard serviceMilliseconds.isFinite, simultaneousMilliseconds.isFinite,
              serviceMilliseconds > 0, simultaneousMilliseconds >= 0 else { return }
        let actualOverlap = min(serviceMilliseconds, simultaneousMilliseconds)
        guard actualOverlap >= 350,
              actualOverlap / serviceMilliseconds >= 0.25 else { return }
        // Bound admission backoff; leave periodic opportunities to re-evaluate
        // whether Apple Default is once again useful for the current scene.
        let relaxed = TranslationHotPathAB.hybridRelaxedBackoff
        skipped = max(skipped, actualOverlap >= 600 ? (relaxed ? 6 : 12) : (relaxed ? 2 : 4))
        skipSetAt = ProcessInfo.processInfo.systemUptime
        recentContention = min(8, recentContention + 1)
        consecutiveWaste = 0
    }
}
