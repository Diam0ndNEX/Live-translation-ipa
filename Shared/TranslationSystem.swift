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
        case .hybridRecovery: return "Uses Apple default early, with fast recovery when confirmed text differs or early work is unavailable. Opt-in; device acceptance is pending."
        case .lowLatency: return "Uses low latency for both early and confirmed text. Wording may differ from Legacy. Requires iOS 26.4 and installed supported languages."
        }
    }
    static func migrate(_ defaults: UserDefaults) -> (TranslationSystem, String) {
        if let value = defaults.string(forKey: "translationSystem") {
            return (Self(rawValue: value) ?? .legacy, Self(rawValue: value) == nil ? "unknown_value_legacy" : "persisted")
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

enum ConfirmedSourceIdentity {
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

struct ModeCaption: Equatable {
    var system: TranslationSystem? = nil
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
    var coldSpeculationCeiling = 0.7
    var matchingLowLatencyDeadline = 4.0
    private(set) var current: ModeCaption?
    private var committed: ModeCaption?
    private var confirmation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var speculation: Task<Void, Never>?
    private var speculativeCaption: ModeCaption?
    private var speculativeOutput: ModeOutput?
    private var speculativeStarted = 0.0
    private var speculativeFailed = false
    private var recoveryStarted = false
    private var lowCache: [String: String] = [:]
    private var lowOrder: [String] = []
    private var defaultService: [Double] = []
    private var lowService: [Double] = []

    init(lookup: @escaping Lookup, translate: @escaping Translate,
         cancel: @escaping (Bool) -> Void, selected: @escaping (ModeCaption, ModeOutput, String) -> Void,
         event: @escaping (ModeCaption, String, Double?) -> Void, status: @escaping (String) -> Void) {
        self.lookup = lookup; self.translate = translate; self.cancel = cancel
        self.selected = selected; self.event = event; self.status = status
    }

    func reduceSpeculation(memoryPressure: Bool) {
        speculation?.cancel(); cancel(true)
        speculativeCaption = nil; speculativeOutput = nil
        if memoryPressure { lowCache.removeAll(); lowOrder.removeAll() }
        if let current, committed != current {
            event(current, memoryPressure ? "memory_pressure" : "thermal_reduced_speculation", nil)
            startRecovery(current, reason: "speculation_absent")
        }
    }

    func reset() {
        confirmation?.cancel(); deadline?.cancel(); speculation?.cancel()
        cancel(true); cancel(false)
        confirmation = nil; deadline = nil
        current = nil; committed = nil; speculativeCaption = nil; speculativeOutput = nil
        // The speculative task clears its occupied slot only after completion.
        recoveryStarted = false
        lowCache.removeAll(); lowOrder.removeAll()
    }

    func observe(_ caption: ModeCaption, confirmed: Bool, speculate: Bool) {
        guard system != .legacy else { return }
        if !confirmed {
            guard speculate, speculation == nil, current == nil || committed == current else { return }
            speculativeCaption = caption; speculativeOutput = nil; speculativeFailed = false
            speculativeStarted = clock()
            event(caption, "speculation_admitted", nil)
            let strategy: RequestedTranslationStrategy = system == .lowLatency ? .lowLatency : .appleDefault
            speculation = Task { [weak self] in
                guard let self else { return }
                let output = await self.resolve(caption, strategy: strategy, speculative: true)
                self.speculation = nil
                guard self.speculativeCaption == caption else { return }
                self.speculativeOutput = output
                self.speculativeFailed = output == nil
                self.event(caption, output == nil ? "speculation_failed" : "speculation_ready", nil)
                if let current = self.current, current.matches(caption), self.committed != current {
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
        current = caption; committed = nil; recoveryStarted = false
        cancel(false)
        confirmation?.cancel(); deadline?.cancel()
        // Never wait for model work before the independent memory probe.
        confirmation = Task { [weak self] in
            guard let self else { return }
            let hits = await self.lookupValues(caption)
            guard !Task.isCancelled, self.current == caption else { return }
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
                    let wait = self.system == .lowLatency ? max(0, self.matchingLowLatencyDeadline - (self.clock() - self.speculativeStarted)) : self.remainingWait()
                    self.deadline = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
                        guard let self, !Task.isCancelled, self.current == caption, self.committed != caption else { return }
                        self.cancel(true)
                        self.startRecovery(caption, reason: "matching_deadline")
                    }
                    return
                }
            }
            let reason = self.speculativeCaption == nil ? "speculation_absent" : (self.speculativeFailed ? "speculation_failed" : "source_mismatch")
            self.speculation?.cancel(); self.cancel(true)
            self.startRecovery(caption, reason: reason)
        }
    }

    private func remainingWait() -> Double {
        let elapsed = max(0, clock() - speculativeStarted)
        // Cold policy uses the measured build-58 observed service ceiling (654 ms),
        // rounded to 700 ms total, not a new 700 ms post-confirmation grace period.
        guard defaultService.count >= 5, lowService.count >= 5 else { return max(0, coldSpeculationCeiling - elapsed) }
        let ordinary = defaultService.sorted()[defaultService.count / 2]
        let recovery = lowService.sorted()[lowService.count / 2]
        return max(0, min(0.25, ordinary - elapsed, recovery))
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
        var values = await lookupValues(caption)
        var origins = values.map { $0 == nil ? "fresh" : "compatible_memory" }
        var strategies: [RequestedTranslationStrategy?] = values.map { _ in nil }
        if allowsReuse {
            for i in values.indices where values[i] == nil {
                if let cached = lowCache[caption.keys[i]], strategy == .lowLatency {
                    values[i] = cached; origins[i] = "session_low_latency"; strategies[i] = .lowLatency
                }
            }
        }
        var uniqueKeys = Set<String>()
        let allMissing = values.indices.filter { values[$0] == nil }
        let missing = allMissing.filter { uniqueKeys.insert(caption.keys[$0]).inserted }
        if !missing.isEmpty {
            guard !Task.isCancelled else { return nil }
            event(caption, speculative ? "speculative_enqueue" : "recovery_enqueue", nil)
            let began = clock()
            var result = await translate(caption, missing, strategy, speculative)
            if result == nil, !speculative, !Task.isCancelled {
                event(caption, "same_strategy_retry", nil)
                result = await translate(caption, missing, strategy, false)
            }
            guard let result, result.count == missing.count else { return nil }
            let duration = clock() - began
            if strategy == .appleDefault { defaultService.append(duration); defaultService = Array(defaultService.suffix(32)) }
            else { lowService.append(duration); lowService = Array(lowService.suffix(32)) }
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

    private func startRecovery(_ caption: ModeCaption, reason: String) {
        guard current == caption, committed != caption, !recoveryStarted else { return }
        recoveryStarted = true
        event(caption, "recovery_decision_" + reason, nil)
        confirmation = Task { [weak self] in
            guard let self else { return }
            var result = await self.resolve(caption, strategy: .lowLatency, speculative: false)
            // Hybrid alone permits one default fallback after bounded LL failure.
            if result == nil, self.system == .hybridRecovery, !Task.isCancelled, self.current == caption {
                self.event(caption, "hybrid_default_fallback", nil)
                result = await self.resolve(caption, strategy: .appleDefault, speculative: false)
            }
            guard !Task.isCancelled, self.current == caption else { self.event(caption, "stale_rejected", nil); return }
            guard let result else { self.event(caption, "recovery_failed_missing", nil); self.status("Translation unavailable. Check installed languages or select another translation system, then Retry."); return }
            self.commit(caption, result, "recovery_success")
        }
    }

    private func commit(_ caption: ModeCaption, _ output: ModeOutput, _ reason: String) {
        guard current == caption, committed != caption, output.complete else { event(caption, "stale_rejected", nil); return }
        committed = caption; deadline?.cancel()
        if allowsReuse {
            for i in output.values.indices where output.strategies[i] == .lowLatency {
                let key = caption.keys[i]
                if lowCache[key] == nil { lowOrder.append(key) }
                lowCache[key] = output.values[i]
                if lowOrder.count > 256 { lowCache.removeValue(forKey: lowOrder.removeFirst()) }
            }
        }
        for i in output.values.indices {
            event(caption, "selected_origin_" + output.origins[i], nil)
            if let strategy = output.strategies[i] { event(caption, "selected_strategy_" + strategy.rawValue, nil) }
        }
        event(caption, "selected_" + reason, nil)
        selected(caption, output, reason)
        // Once selected, competing work has no display authority or inference purpose.
        speculation?.cancel(); cancel(true)
        confirmation?.cancel(); cancel(false)
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
