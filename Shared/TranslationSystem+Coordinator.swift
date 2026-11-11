import Foundation

/// Main-actor ownership is the atomic display selection latch. Model cancellation
/// is advisory; both backend lanes remain occupied until their real calls return.
/// 2.5.0: this coordinator serves Low Latency only (Legacy has its own drain; Hybrid Recovery was removed), so
/// every request it makes uses the Low Latency strategy and there is one session cache.
@MainActor
final class ModeCoordinator {
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
    var matchingLowLatencyDeadline = 4.0
    private(set) var current: ModeCaption?
    private var committed: ModeCaption?
    private var memoryProbePending: ModeCaption?
    private var verifiedConfirmedMemory: (caption: ModeCaption, hits: [String?])?
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
    private var cacheEpoch = UUID()
    private var lowCache: [String: String] = [:]
    private var lowOrder: [String] = []

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
        current = nil; committed = nil; memoryProbePending = nil; verifiedConfirmedMemory = nil
        speculativeCaption = nil; speculativeOutput = nil
        speculativeEligible = false; speculativeModelSubmitted = false
        // The speculative task clears its occupied slot only after completion.
        recoveryStarted = false
        cacheEpoch = UUID()
        lowCache.removeAll(); lowOrder.removeAll()
    }

    func observe(_ caption: ModeCaption, confirmed: Bool, speculate: Bool) {
        guard system != .legacy else { return }
        if !confirmed {
            guard speculate, speculation == nil, current == nil || committed == current else { return }
            speculativeCaption = caption; speculativeOutput = nil; speculativeFailed = false
            speculativeEligible = true; speculativeModelSubmitted = false
            speculativeStarted = clock()
            event(caption, "speculation_admitted", nil)
            let ticket = UUID()
            speculationTicket = ticket
            speculation = Task { [weak self] in
                guard let self else { return }
                let output = await self.resolve(caption, speculative: true)
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
        current = caption; committed = nil; memoryProbePending = caption
        verifiedConfirmedMemory = nil; recoveryStarted = false
        cancel(false)
        confirmation?.cancel()
        deadline?.cancel()
        // Never wait for model work before the independent memory probe.
        confirmation = Task { [weak self] in
            guard let self else { return }
            let hits = await self.lookupValues(caption)
            guard !Task.isCancelled, self.current == caption else { return }
            self.memoryProbePending = nil
            // The exact confirmed memory probe already produced this result.
            // Recoveries and fallback must not perform a second identical
            // SQLite round trip after confirmed OCR has been validated.
            self.verifiedConfirmedMemory = (caption, hits)
            if hits.allSatisfy({ $0 != nil }) {
                self.commit(caption, ModeOutput(values: hits.compactMap { $0 }, strategies: hits.map { _ in nil },
                    origins: hits.map { _ in "compatible_memory" }), "memory_hit")
                return
            }
            if let early = self.speculativeCaption, early.matches(caption) {
                if let result = self.speculativeOutput { self.commit(caption, result, "speculation_match_ready"); return }
                if self.speculation != nil && !self.speculativeFailed {
                    self.event(caption, "speculation_match_unfinished", nil)
                    // The confirmed caption shares the running request. A hung request has a deadline.
                    let wait = max(0, self.matchingLowLatencyDeadline - (self.clock() - self.speculativeStarted))
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
            self.speculation?.cancel()
            self.cancel(true)
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

    /// Records that the early request really reached the model (not only a cache or an admission check).
    func noteSpeculativeModelSubmitted(_ caption: ModeCaption) {
        guard speculativeCaption == caption, speculativeEligible else { return }
        speculativeModelSubmitted = true
    }

    private func lookupValues(_ caption: ModeCaption) async -> [String?] {
        guard allowsReuse else { return caption.keys.map { _ in nil } }
        let began = clock(); event(caption, "memory_lookup_start", nil)
        let preferred = await lookup(caption)
        event(caption, "memory_lookup_end", (clock() - began) * 1000)
        guard preferred.count == caption.units.count else { return caption.units.map { _ in nil } }
        return preferred
    }

    private func resolve(_ caption: ModeCaption, speculative: Bool) async -> ModeOutput? {
        let strategy = RequestedTranslationStrategy.lowLatency
        let workEpoch = cacheEpoch
        let valuesFromProbe: [String?]
        #if SCREENLINGO_REFERENCE_CONFIRMED_PROBE
        valuesFromProbe = await lookupValues(caption)
        #else
        if !speculative, let verified = verifiedConfirmedMemory,
           verified.caption == caption, verified.hits.count == caption.units.count {
            valuesFromProbe = verified.hits
            event(caption, "confirmed_memory_probe_reused", nil)
        } else {
            valuesFromProbe = await lookupValues(caption)
        }
        #endif
        var values = valuesFromProbe
        var origins = values.map { $0 == nil ? "fresh" : "compatible_memory" }
        var strategies: [RequestedTranslationStrategy?] = values.map { _ in nil }
        if allowsReuse {
            for i in values.indices where values[i] == nil {
                if let cached = lowCache[caption.keys[i]] {
                    values[i] = cached
                    origins[i] = "session_low_latency"
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
            var result = await translate(caption, missing, strategy, speculative)
            if result == nil, !speculative, !Task.isCancelled,
               shouldStartModel(caption, speculative: false) {
                event(caption, "same_strategy_retry", nil)
                result = await translate(caption, missing, strategy, false)
            }
            guard !Task.isCancelled, let result, result.count == missing.count,
                  result.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
            // A result that lost display authority is still safe to reuse by exact key in this capture session.
            if allowsReuse && SharedTranslationWork.mayReuse(
                workEpoch: workEpoch, currentEpoch: cacheEpoch,
                requestedCancellation: Task.isCancelled, compatibleContext: true) {
                for (position, index) in missing.enumerated() {
                    cacheCompleted(result[position], for: caption.keys[index], strategy: strategy)
                }
                event(caption, "strategy_cache_populated_" + strategy.rawValue, nil)
            }
            if missing.count == 1 && allMissing.count == 1 {
                // The common single-unresolved-unit case needs no duplicate-key scan.
                let index = allMissing[0]
                values[index] = result[0]
                strategies[index] = strategy
                origins[index] = speculative ? "speculation" : "recovery"
            } else {
                for (position, index) in missing.enumerated() {
                    for duplicate in allMissing where caption.keys[duplicate] == caption.keys[index] {
                        values[duplicate] = result[position]; strategies[duplicate] = strategy
                        origins[duplicate] = speculative ? "speculation" : "recovery"
                    }
                }
            }
        }
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        let output = ModeOutput(values: values.compactMap { $0 }, strategies: strategies, origins: origins)
        return output.complete ? output : nil
    }

    private func cacheCompleted(_ value: String, for key: String, strategy: RequestedTranslationStrategy) {
        guard strategy == .lowLatency else { return }
        if lowCache[key] == nil { lowOrder.append(key) }
        lowCache[key] = value
        if lowOrder.count > 256 { lowCache.removeValue(forKey: lowOrder.removeFirst()) }
    }

    private func startRecovery(_ caption: ModeCaption, reason: String) {
        guard current == caption, committed != caption, !recoveryStarted else { return }
        recoveryStarted = true
        event(caption, "recovery_decision_" + reason, nil)
        confirmation = Task { [weak self] in
            guard let self else { return }
            let result = await self.resolve(caption, speculative: false)
            guard !Task.isCancelled, self.current == caption, self.committed != caption else {
                self.event(caption, "stale_rejected", nil)
                return
            }
            guard let result else {
                self.event(caption, "recovery_failed_missing", nil)
                self.status("Translation unavailable. Check that the Low Latency language pack is installed, or choose Legacy, then Retry.")
                return
            }
            self.commit(caption, result, "recovery_success")
        }
    }

    private func commit(_ caption: ModeCaption, _ output: ModeOutput, _ proposedReason: String) {
        let memoryOnly = output.origins.allSatisfy { $0 == "compatible_memory" || $0 == "session_low_latency" }
        let reason = memoryOnly ? "memory_hit" : proposedReason
        guard current == caption, committed != caption, output.complete else { event(caption, "stale_rejected", nil); return }
        committed = caption; deadline?.cancel()
        if speculativeCaption?.matches(caption) == true {
            speculativeEligible = false
        }
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
        speculation?.cancel(); cancel(true)
        confirmation?.cancel(); cancel(false)
    }
}
