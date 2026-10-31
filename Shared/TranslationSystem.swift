import Foundation

enum TranslationSystem: String, CaseIterable, Codable {
    case legacy, hybridRecovery, lowLatency
    static let referenceSHA = "e94542ce46cdb5b2426fdfd5dc258c932327762b"
    static let referenceVersion = "1.7.2 (58)"
    var title: String {
        switch self {
        case .legacy: return "Legacy (1.7.2)"
        case .hybridRecovery: return "Hybrid Recovery"
        case .lowLatency: return "Low Latency"
        }
    }
    var explanation: String {
        switch self {
        case .legacy: return "Uses the established 1.7.2 pipeline and Apple default strategy."
        case .hybridRecovery: return "Uses Apple Default ahead and Low Latency for confirmed recovery. Automatically reduces speculative work when it causes repeated waste or slow overlapping requests. Device acceptance pending."
        case .lowLatency: return "Uses low latency for both early and confirmed text. Wording may differ from Legacy. Requires iOS 26.4 and installed supported languages."
        }
    }
    static func migrate(_ defaults: UserDefaults) -> (TranslationSystem, String) {
        if let value = defaults.string(forKey: "translationSystem") {
            guard let mode = Self(rawValue: value) else { return (.legacy, "unknown_value_legacy") }
            let saved = defaults.string(forKey: "translationSystemMigration") ?? "persisted"
            let reasons = ["explicit_hybrid", "explicit_low_latency", "legacy_or_ambiguous", "persisted"]
            return (mode, reasons.contains(saved) ? saved : "persisted")
        }
        let mode: Self
        let reason: String
        // These old switches were opt-in, with false defaults. Hybrid took precedence.
        if defaults.object(forKey: "hybridTranslation") as? Bool == true {
            mode = .hybridRecovery; reason = "explicit_hybrid"
        } else if defaults.object(forKey: "lowLatencyTranslation") as? Bool == true {
            mode = .lowLatency; reason = "explicit_low_latency"
        } else { mode = .legacy; reason = "legacy_or_ambiguous" }
        defaults.set(mode.rawValue, forKey: "translationSystem")
        defaults.set(reason, forKey: "translationSystemMigration")
        return (mode, reason)
    }
}

enum RequestedTranslationStrategy: String, Codable {
    case appleDefault, lowLatency
}

/// Device language availability for each requested translation strategy.
/// "Supported" is not installed; an unavailable strategy must never invalidate another.
enum LanguageAssetState: String, Equatable {
    case installed, supported, unsupported, unchecked
}

struct TranslationLanguageCoverage: Equatable {
    let appleDefault: LanguageAssetState
    let lowLatency: LanguageAssetState

    func overall(for system: TranslationSystem) -> LanguageAssetState {
        switch system {
        case .legacy: return appleDefault
        case .lowLatency: return lowLatency
        case .hybridRecovery:
            if appleDefault == .installed || lowLatency == .installed { return .installed }
            if appleDefault == .supported || lowLatency == .supported { return .supported }
            if appleDefault == .unchecked || lowLatency == .unchecked { return .unchecked }
            return .unsupported
        }
    }

    func nextDownload(for system: TranslationSystem) -> RequestedTranslationStrategy? {
        switch system {
        case .legacy:
            return appleDefault == .supported ? .appleDefault : nil
        case .lowLatency:
            return lowLatency == .supported ? .lowLatency : nil
        case .hybridRecovery:
            // Prefer completing fast recovery if default is already usable.
            if lowLatency == .supported { return .lowLatency }
            if appleDefault == .supported { return .appleDefault }
            return nil
        }
    }

    func explanation(for system: TranslationSystem) -> String {
        switch system {
        case .legacy:
            switch appleDefault {
            case .installed: return "Apple Default installed for this language pair"
            case .supported: return "Apple Default supports this pair; download required"
            case .unsupported: return "Apple Default does not support this language pair"
            case .unchecked: return "Apple Default availability has not been checked"
            }
        case .lowLatency:
            switch lowLatency {
            case .installed: return "Low Latency language pack installed"
            case .supported: return "Low Latency pack available but not installed"
            case .unsupported: return "Low Latency does not support this language pair"
            case .unchecked: return "Low Latency availability has not been checked"
            }
        case .hybridRecovery:
            if appleDefault == .installed && lowLatency == .installed {
                return "Apple Default and Low Latency installed"
            }
            if appleDefault == .installed {
                return lowLatency == .supported ?
                    "Apple Default ready; install Low Latency for faster recovery" :
                    "Apple Default ready; Low Latency recovery unavailable for this pair"
            }
            if lowLatency == .installed {
                return appleDefault == .supported ?
                    "Low Latency ready; Apple Default requires download" :
                    "Low Latency ready; Apple Default unavailable for this pair"
            }
            if overall(for: system) == .unsupported { return "Neither strategy supports this language pair" }
            if overall(for: system) == .supported { return "No installed strategy for this pair; download required" }
            return "Checking Apple Default and Low Latency language availability"
        }
    }
}

enum ConfirmedSourceIdentity {
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

struct ModeCaption: Equatable {
    var system: TranslationSystem? = nil
    var thermal = 0
    let session: UUID
    let caption: String
    let revision: Int
    let source: String
    let target: String
    let rules: String
    let text: String
    let units: [String]
    let keys: [String]
    let firstOCR: Double
    var fingerprint: String { ConfirmedSourceIdentity.normalize(text) }
    var policyCohort: String {
        let tier = thermal <= 1 ? "full_performance" : (thermal == 2 ? "protected" : "emergency")
        return "\(source)>\(target)|tier\(tier)"
    }

    /// Temperature is observation metadata, not a candidate identity boundary.
    /// A nominal/fair transition must not invalidate an active translation.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.system == rhs.system && lhs.session == rhs.session &&
        lhs.caption == rhs.caption && lhs.revision == rhs.revision &&
        lhs.source == rhs.source && lhs.target == rhs.target &&
        lhs.rules == rhs.rules && lhs.text == rhs.text &&
        lhs.units == rhs.units && lhs.keys == rhs.keys &&
        lhs.firstOCR == rhs.firstOCR
    }
    func matches(_ other: Self) -> Bool {
        system == other.system && session == other.session && caption == other.caption && source == other.source &&
        target == other.target && rules == other.rules && fingerprint == other.fingerprint &&
        units.map(ConfirmedSourceIdentity.normalize) == other.units.map(ConfirmedSourceIdentity.normalize)
    }
}

struct ModeOutput {
    let values: [String]
    let strategies: [RequestedTranslationStrategy?]
    let origins: [String]
    var complete: Bool { !values.isEmpty && values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

/// Internal-only A/B strategies. These never change the user's translation
/// system or permit tentative text to be displayed before confirmation.
enum HybridSchedulerVariant: String {
    case reference195
    case recoveryFirst
    case evidenceBounded
}

enum HybridSchedulingPolicy {
    /// These are build-time reference variants, not user-facing modes.
    static var buildVariant: HybridSchedulerVariant {
        #if SCREENLINGO_HYBRID_REFERENCE
        return .reference195
        #elseif SCREENLINGO_HYBRID_RECOVERY_FIRST
        return .recoveryFirst
        #else
        return .evidenceBounded
        #endif
    }

    /// The expected gain is a bounded reduction of LL/Default cross-lane
    /// contention, not a claim of independent Apple inference hardware.
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
            lowMedian <= 0.12 && remaining > 0.45 { return 0 }
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

    /// A repeated OCR packet must not exhaust a backoff intended to cover
    /// distinct subtitle candidates. Identity contains metadata, never text.
    mutating func admit(identity: String? = nil) -> Bool {
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
            skipped = max(skipped, 8)
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
        skipped = max(skipped, actualOverlap >= 600 ? 12 : 4)
        recentContention = min(8, recentContention + 1)
        consecutiveWaste = 0
    }
}

/// Main-actor ownership is the atomic display selection latch. Model cancellation
/// is advisory; both backend lanes remain occupied until their real calls return.
@MainActor
final class ThreeModeCoordinator {
    typealias Lookup = (ModeCaption) async -> [String?]
    typealias Translate = (ModeCaption, [Int], RequestedTranslationStrategy, Bool) async -> [String]?
    var lookup: Lookup
    var translate: Translate
    var cancel: (Bool) -> Void
    var selected: (ModeCaption, ModeOutput, String) -> Void
    var event: (ModeCaption, String, Double?) -> Void
    var status: (String) -> Void
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    var system: TranslationSystem = .legacy
    var allowsReuse = true
    var adaptiveHybrid = true
    var hybridVariant: HybridSchedulerVariant = HybridSchedulingPolicy.buildVariant
    var fastRecoveryInstalled = true
    var hybridSpeculationPermitted: () -> Bool = { true }
    var coldSpeculationCeiling = 0.7
    var matchingLowLatencyDeadline = 4.0
    private(set) var current: ModeCaption?
    private var committed: ModeCaption?
    private var memoryProbePending: ModeCaption?
    private var confirmation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var speculation: Task<Void, Never>?
    private var speculationTicket = UUID()
    private var speculativeCaption: ModeCaption?
    private var speculativeOutput: ModeOutput?
    private var speculativeStarted = 0.0
    private var speculativeFailed = false
    private var speculativeEligible = false
    private var speculativeModelSubmitted = false
    private var recoveryStarted = false
    private var hybridAdmission = HybridAdmissionPolicy()
    private var scoredSpeculation: ModeCaption?
    private var cacheEpoch = UUID()
    private var lowCache: [String: String] = [:]
    private var lowOrder: [String] = []
    private var defaultCache: [String: String] = [:]
    private var defaultOrder: [String] = []
    private var defaultService: [String: [Double]] = [:]
    private var lowService: [String: [Double]] = [:]

    init(lookup: @escaping Lookup, translate: @escaping Translate,
         cancel: @escaping (Bool) -> Void, selected: @escaping (ModeCaption, ModeOutput, String) -> Void,
         event: @escaping (ModeCaption, String, Double?) -> Void, status: @escaping (String) -> Void) {
        self.lookup = lookup; self.translate = translate; self.cancel = cancel
        self.selected = selected; self.event = event; self.status = status
    }

    func reduceSpeculation(memoryPressure: Bool) {
        speculation?.cancel(); cancel(true)
        speculativeCaption = nil; speculativeOutput = nil
        speculativeEligible = false
        if memoryPressure {
            lowCache.removeAll(); lowOrder.removeAll()
            defaultCache.removeAll(); defaultOrder.removeAll()
        }
        if let current, committed != current {
            event(current, memoryPressure ? "memory_pressure" : "thermal_reduced_speculation", nil)
            if memoryProbePending != current { startRecovery(current, reason: "speculation_absent") }
        }
    }

    func reset() {
        confirmation?.cancel(); deadline?.cancel(); speculation?.cancel()
        cancel(true); cancel(false)
        // Old asynchronous responses may arrive after a reset. Release the
        // logical slot for the next capture while keeping the real backend
        // lane occupied until Apple's request actually returns.
        speculationTicket = UUID()
        speculation = nil
        confirmation = nil; deadline = nil
        current = nil; committed = nil; memoryProbePending = nil; speculativeCaption = nil; speculativeOutput = nil
        speculativeEligible = false; speculativeModelSubmitted = false
        // The speculative task clears its occupied slot only after completion.
        recoveryStarted = false
        hybridAdmission = HybridAdmissionPolicy()
        scoredSpeculation = nil
        cacheEpoch = UUID()
        lowCache.removeAll(); lowOrder.removeAll()
        defaultCache.removeAll(); defaultOrder.removeAll()
        defaultService.removeAll(); lowService.removeAll()
    }

    func observe(_ caption: ModeCaption, confirmed: Bool, speculate: Bool) {
        guard system != .legacy else { return }
        if !confirmed {
            guard speculate, speculation == nil, current == nil || committed == current else { return }
            if system == .hybridRecovery && !hybridSpeculationPermitted() {
                speculativeCaption = nil
                speculativeOutput = nil
                event(caption, "hybrid_speculation_backend_busy", nil)
                return
            }
            if system == .hybridRecovery && adaptiveHybrid &&
                !hybridAdmission.admit(identity: "\(caption.session.uuidString)|\(caption.caption)|\(caption.revision)") {
                speculativeCaption = nil
                speculativeOutput = nil
                event(caption, "hybrid_speculation_throttled", nil)
                return
            }
            scoredSpeculation = nil
            speculativeCaption = caption; speculativeOutput = nil; speculativeFailed = false
            speculativeEligible = true; speculativeModelSubmitted = false
            speculativeStarted = clock()
            event(caption, "speculation_admitted", nil)
            let strategy: RequestedTranslationStrategy = system == .lowLatency ? .lowLatency : .appleDefault
            let ticket = UUID()
            speculationTicket = ticket
            speculation = Task { [weak self] in
                guard let self else { return }
                let output = await self.resolve(caption, strategy: strategy, speculative: true)
                // An older cancelled task must not erase the next capture's
                // active speculation slot or publish an obsolete response.
                guard self.speculationTicket == ticket else { return }
                self.speculation = nil
                guard self.speculativeCaption == caption else { return }
                self.speculativeOutput = output
                self.speculativeFailed = output == nil
                self.event(caption, output == nil ? "speculation_failed" : "speculation_ready", nil)
                if let current = self.current, current.matches(caption), self.committed != current, self.memoryProbePending != current {
                    if let output { self.commit(current, output, "speculation_match_in_flight") }
                    else { self.startRecovery(current, reason: "speculation_failed") }
                }
            }
            return
        }
        if let current, current.matches(caption), current.revision == caption.revision { return }
        if let previous = current, committed != previous { event(previous, "superseded_missing", nil) }
        if let previous = current, previous.caption == caption.caption, previous.fingerprint != caption.fingerprint {
            event(caption, "source_correction", nil)
        }
        // Confirmation, not the previously displayed caption, determines
        // whether an early next-subtitle prediction has been superseded.
        if let early = speculativeCaption, !early.matches(caption) {
            speculativeEligible = false
            event(caption, "speculation_superseded_before_confirmation", nil)
        }
        current = caption; committed = nil; memoryProbePending = caption; recoveryStarted = false
        // Obsolete Hybrid work loses display authority without cancelling its
        // warmed backend session. Only one physical call may occupy each lane.
        if system != .hybridRecovery {
            cancel(false)
            confirmation?.cancel()
        } else {
            event(caption, "hybrid_preserve_confirmed_session", nil)
        }
        deadline?.cancel()
        // Never wait for model work before the independent memory probe.
        confirmation = Task { [weak self] in
            guard let self else { return }
            let hits = await self.lookupValues(caption)
            guard !Task.isCancelled, self.current == caption else { return }
            self.memoryProbePending = nil
            if hits.allSatisfy({ $0 != nil }) {
                self.commit(caption, ModeOutput(values: hits.compactMap { $0 }, strategies: hits.map { _ in nil },
                    origins: hits.map { _ in "compatible_memory" }), "memory_hit")
                return
            }
            if let early = self.speculativeCaption, early.matches(caption) {
                if let result = self.speculativeOutput { self.commit(caption, result, "speculation_match_ready"); return }
                if self.speculation != nil && !self.speculativeFailed {
                    self.event(caption, "speculation_match_unfinished", nil)
                    // LL shares the original request. A hung request has a same-strategy deadline.
                    let wait = self.system == .lowLatency ? max(0, self.matchingLowLatencyDeadline - (self.clock() - self.speculativeStarted)) : self.remainingWait(caption)
                    self.deadline = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
                        guard let self, !Task.isCancelled, self.current == caption, self.committed != caption else { return }
                        if self.system == .hybridRecovery {
                            // Hedge: the existing matching Apple Default request
                            // can still win, so its session must not be cancelled.
                            self.event(caption, "hybrid_hedged_recovery", nil)
                        } else {
                            self.cancel(true)
                        }
                        self.startRecovery(caption, reason: "matching_deadline")
                    }
                    return
                }
            }
            let reason = self.speculativeCaption == nil ? "speculation_absent" : (self.speculativeFailed ? "speculation_failed" : "source_mismatch")
            if self.system == .hybridRecovery {
                if self.speculation != nil {
                    // Incorrect OCR speculation is discarded when it returns,
                    // but the warmed session survives if the request succeeds.
                    self.event(caption, "hybrid_obsolete_speculation_draining", nil)
                }
            } else {
                self.speculation?.cancel()
                self.cancel(true)
            }
            self.startRecovery(caption, reason: reason)
        }
    }

    /// An unconfirmed next subtitle is valid while the preceding subtitle is
    /// displayed. Only a DIFFERENT new confirmation, a reset, or explicit
    /// cancellation can revoke its right to start inference.
    func shouldStartModel(_ caption: ModeCaption, speculative: Bool) -> Bool {
        guard system != .legacy else { return false }
        if speculative {
            guard speculativeEligible, speculativeCaption == caption else { return false }
            if let current, current.matches(caption) { return committed != current }
            return true
        }
        return current == caption && committed != caption
    }

    /// Feedback must reflect actual Apple-default work, not a local admission
    /// rejection or a cache-only result. Match the complete caption identity.
    func noteSpeculativeModelSubmitted(_ caption: ModeCaption) {
        guard speculativeCaption == caption, speculativeEligible else { return }
        speculativeModelSubmitted = true
    }

    func noteOverlappingRecovery(serviceMilliseconds: Double, simultaneousMilliseconds: Double) {
        guard system == .hybridRecovery, adaptiveHybrid else { return }
        hybridAdmission.recordRecovery(serviceMilliseconds: serviceMilliseconds,
                                       simultaneousMilliseconds: simultaneousMilliseconds)
    }

    private func scoreSpeculation(for caption: ModeCaption, useful: Bool) {
        guard system == .hybridRecovery, let early = speculativeCaption,
              early.session == caption.session, scoredSpeculation != early else { return }
        scoredSpeculation = early
        if !speculativeModelSubmitted && !useful {
            event(caption, "hybrid_speculation_unexecuted", nil)
            return
        }
        if adaptiveHybrid && speculativeModelSubmitted {
            hybridAdmission.record(used: useful)
        }
        event(caption, useful ? "hybrid_speculation_useful" : "hybrid_speculation_wasted", nil)
    }

    private func remainingWait(_ caption: ModeCaption) -> Double {
        let elapsed = max(0, clock() - speculativeStarted)
        let ordinary = defaultService[caption.policyCohort, default: []]
        let recovery = lowService[caption.policyCohort, default: []]
        let referenceWait = SpeculationWaitPolicy.remaining(elapsed: elapsed,
            ordinary: ordinary, recovery: recovery, coldCeiling: coldSpeculationCeiling)
        guard system == .hybridRecovery else { return referenceWait }
        let chosen = HybridSchedulingPolicy.matchingWait(variant: hybridVariant,
            elapsed: elapsed, defaultSamples: ordinary, lowSamples: recovery,
            oldWait: referenceWait, recentContention: hybridAdmission.recentContention)
        event(caption, "hybrid_matching_wait_ms", chosen * 1000)
        return chosen
    }

    private func lookupValues(_ caption: ModeCaption) async -> [String?] {
        guard allowsReuse else { return caption.keys.map { _ in nil } }
        let began = clock(); event(caption, "memory_lookup_start", nil)
        let preferred = await lookup(caption)
        event(caption, "memory_lookup_end", (clock() - began) * 1000)
        guard preferred.count == caption.units.count else { return caption.units.map { _ in nil } }
        return preferred
    }

    private func resolve(_ caption: ModeCaption, strategy: RequestedTranslationStrategy, speculative: Bool) async -> ModeOutput? {
        let workEpoch = cacheEpoch
        var values = await lookupValues(caption)
        var origins = values.map { $0 == nil ? "fresh" : "compatible_memory" }
        var strategies: [RequestedTranslationStrategy?] = values.map { _ in nil }
        if allowsReuse {
            for i in values.indices where values[i] == nil {
                let cached = strategy == .lowLatency ? lowCache[caption.keys[i]] : defaultCache[caption.keys[i]]
                if let cached {
                    values[i] = cached
                    origins[i] = strategy == .lowLatency ? "session_low_latency" : "session_apple_default"
                    strategies[i] = strategy
                    event(caption, "strategy_cache_hit_" + strategy.rawValue, nil)
                }
            }
        }
        let allMissing = values.indices.filter { values[$0] == nil }
        guard let missing = SharedTranslationWork.unresolvedIndices(keys: caption.keys, values: values) else {
            return nil
        }
        if !missing.isEmpty {
            guard !Task.isCancelled else { return nil }
            event(caption, speculative ? "speculative_enqueue" : "recovery_enqueue", nil)
            let began = clock()
            var result = await translate(caption, missing, strategy, speculative)
            if result == nil, !speculative, !Task.isCancelled,
               shouldStartModel(caption, speculative: false) {
                event(caption, "same_strategy_retry", nil)
                result = await translate(caption, missing, strategy, false)
            }
            guard !Task.isCancelled, let result, result.count == missing.count,
                  result.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
            // An obsolete Hybrid model result has no display authority, but its
            // exact-key translation is safe to reuse in this capture session.
            if allowsReuse && SharedTranslationWork.mayReuse(
                workEpoch: workEpoch, currentEpoch: cacheEpoch,
                requestedCancellation: Task.isCancelled, compatibleContext: true) {
                for (position, index) in missing.enumerated() {
                    cacheCompleted(result[position], for: caption.keys[index], strategy: strategy)
                }
                event(caption, "strategy_cache_populated_" + strategy.rawValue, nil)
            }
            let duration = clock() - began
            let cohort = caption.policyCohort
            if strategy == .appleDefault {
                if defaultService.count >= 64 && defaultService[cohort] == nil { defaultService.removeAll() }
                defaultService[cohort, default: []].append(duration)
                defaultService[cohort] = Array(defaultService[cohort, default: []].suffix(32))
            } else {
                if lowService.count >= 64 && lowService[cohort] == nil { lowService.removeAll() }
                lowService[cohort, default: []].append(duration)
                lowService[cohort] = Array(lowService[cohort, default: []].suffix(32))
            }
            for (position, index) in missing.enumerated() {
                for duplicate in allMissing where caption.keys[duplicate] == caption.keys[index] {
                    values[duplicate] = result[position]; strategies[duplicate] = strategy
                    origins[duplicate] = speculative ? "speculation" : "recovery"
                }
            }
        }
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        let output = ModeOutput(values: values.compactMap { $0 }, strategies: strategies, origins: origins)
        return output.complete ? output : nil
    }

    private func cacheCompleted(_ value: String, for key: String, strategy: RequestedTranslationStrategy) {
        if strategy == .lowLatency {
            if lowCache[key] == nil { lowOrder.append(key) }
            lowCache[key] = value
            if lowOrder.count > 256 { lowCache.removeValue(forKey: lowOrder.removeFirst()) }
        } else {
            if defaultCache[key] == nil { defaultOrder.append(key) }
            defaultCache[key] = value
            if defaultOrder.count > 256 { defaultCache.removeValue(forKey: defaultOrder.removeFirst()) }
        }
    }

    private func startRecovery(_ caption: ModeCaption, reason: String) {
        guard current == caption, committed != caption, !recoveryStarted else { return }
        // A matching request can still finish first after the hedge starts.
        if speculativeCaption?.matches(caption) != true {
            scoreSpeculation(for: caption, useful: false)
        }
        recoveryStarted = true
        event(caption, "recovery_decision_" + reason, nil)
        confirmation = Task { [weak self] in
            guard let self else { return }
            // If Hybrid's optional fast language pack is known missing, do not
            // burn two failed Low Latency requests before Apple Default fallback.
            let useLowLatency = self.system == .lowLatency || self.fastRecoveryInstalled
            if !useLowLatency { self.event(caption, "hybrid_no_fast_pack_fallback", nil) }
            var result = await self.resolve(caption, strategy: useLowLatency ? .lowLatency : .appleDefault,
                                            speculative: false)
            // Hybrid alone permits one default fallback after bounded LL failure.
            if result == nil, self.system == .hybridRecovery, useLowLatency,
               !Task.isCancelled, self.current == caption, self.committed != caption {
                self.event(caption, "hybrid_default_fallback", nil)
                result = await self.resolve(caption, strategy: .appleDefault, speculative: false)
            }
            guard !Task.isCancelled, self.current == caption, self.committed != caption else {
                self.event(caption, "stale_rejected", nil)
                return
            }
            guard let result else {
                self.event(caption, "recovery_failed_missing", nil)
                self.status("Translation unavailable. Check installed languages or select another translation system, then Retry.")
                return
            }
            self.commit(caption, result, "recovery_success")
        }
    }

    private func commit(_ caption: ModeCaption, _ output: ModeOutput, _ proposedReason: String) {
        let memoryOnly = output.origins.allSatisfy {
            $0 == "compatible_memory" || $0 == "session_low_latency" || $0 == "session_apple_default"
        }
        let reason = memoryOnly ? "memory_hit" : proposedReason
        guard current == caption, committed != caption, output.complete else { event(caption, "stale_rejected", nil); return }
        committed = caption; deadline?.cancel()
        if speculativeCaption?.matches(caption) == true {
            speculativeEligible = false
        }
        let matchedPreview = proposedReason == "speculation_match_ready" ||
            proposedReason == "speculation_match_in_flight"
        let previewUseful = output.origins.contains("speculation") ||
            (matchedPreview && output.origins.contains("session_apple_default"))
        scoreSpeculation(for: caption, useful: previewUseful)
        if allowsReuse {
            for i in output.values.indices {
                if let strategy = output.strategies[i] {
                    cacheCompleted(output.values[i], for: caption.keys[i], strategy: strategy)
                }
            }
        }
        for i in output.values.indices {
            event(caption, "selected_origin_" + output.origins[i], nil)
            if let strategy = output.strategies[i] { event(caption, "selected_strategy_" + strategy.rawValue, nil) }
        }
        event(caption, "selected_" + reason, nil)
        selected(caption, output, reason)
        // After selection, Hybrid ignores losing output but lets the bounded
        // underlying call drain. This preserves successful warm-up and cannot
        // change the selected text. Hard cancel remains for shutdown/pressure.
        if system == .hybridRecovery {
            if speculation != nil || recoveryStarted {
                event(caption, "hybrid_losing_request_draining", nil)
            }
        } else {
            speculation?.cancel(); cancel(true)
            confirmation?.cancel(); cancel(false)
        }
    }
}

/// Reject delayed UDP packets from a stopped/replaced broadcast, including a
/// quick restart before heartbeat expiry. Retention is bounded to 64 broadcasts.
struct CaptureSessionIdentityGate {
    enum Admission { case current, newSession, rejected }
    private(set) var current: String?
    private var retired: [String] = []
    mutating func admit(_ id: String?) -> Admission {
        guard let id else { return current == nil ? .current : .rejected }
        guard !retired.contains(id) else { return .rejected }
        if id == current { return .current }
        if let current { retire(current) }
        current = id
        return .newSession
    }
    mutating func stop(_ id: String?) -> Bool {
        guard id == current else { return false }
        if let current { retire(current) }
        current = nil
        return true
    }
    private mutating func retire(_ id: String) {
        if !retired.contains(id) { retired.append(id) }
        if retired.count > 64 { retired.removeFirst(retired.count - 64) }
    }
}

enum CaptionClockOrigin {
    static func monotonic(firstSeen: Double?, wallFirstSeen: Double, wallNow: Double, uptimeNow: Double) -> Double {
        if let firstSeen, firstSeen.isFinite, firstSeen >= 0, firstSeen <= uptimeNow { return firstSeen }
        return max(0, uptimeNow - max(0, wallNow - wallFirstSeen))
    }
}

/// Per-language-pair and thermal-cohort timing guides the matching speculation
/// hedge. Unknown performance has a bounded cold-start fallback; completed
/// samples choose the likely Default finish and recovery crossover.
enum SpeculationWaitPolicy {
    static func remaining(elapsed: Double, ordinary: [Double], recovery: [Double], coldCeiling: Double) -> Double {
        let age = max(0, elapsed)
        let ceiling = max(0, min(coldCeiling, 0.70))
        guard age < ceiling else { return 0 }
        let ageBudget = ceiling - age
        let sortedDefault = ordinary.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard sortedDefault.count >= 5 else { return min(ageBudget, max(0, 0.45 - age)) }
        let expectedDefault = sortedDefault[min(sortedDefault.count - 1, Int(Double(sortedDefault.count - 1) * 0.75))]
        let remainingDefault = max(0, expectedDefault - age)
        guard remainingDefault > 0 else { return 0 }
        let validRecovery = recovery.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard validRecovery.count >= 5 else { return min(ageBudget, remainingDefault) }
        let recoveryMedian = validRecovery[validRecovery.count / 2]
        // Fast recovery can start sooner; a slow contended recovery should
        // not preempt an Apple Default request already nearing completion.
        let hedgeBudget = max(0.10, min(0.65, recoveryMedian * 0.75))
        return max(0, min(ageBudget, remainingDefault, hedgeBudget))
    }
}
