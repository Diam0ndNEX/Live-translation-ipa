import Foundation
import Translation

/// Installed-language sessions are independent of SwiftUI translationTask lifetimes.
/// There is at most one real Apple request per lane, even after a timeout.
@MainActor
final class ModeTranslationService {
    /// Physical return time of the last Apple Default call per language pair,
    /// on any lane. Used only by the Hybrid switch guard.
    var lastAppleDefaultReturn: [String: Double] = [:]
    var hostedIsSpeculative = false
    var hostedTask: Task<[String]?, Never>?
    var hostedActivityID: UUID?
    var activityChanged: ((TranslationBackendActivity) -> Void)?
    var activity = TranslationBackendActivity() { didSet { activityChanged?(activity) } }
    var generation = 0
    var confirmedDemand = 0
    var preparationRevision = 0
    let speculative = Lane()
    let confirmed = Lane()
    let warmupLane = Lane()
    var warmupPolicy = InitialWarmupPolicy()
    private var recentlyInstalled: [String: Double] = [:]
    private let installedCheckTTL: Double = 30
    /// 2.2.3 (L5, UNVERIFIED): with the pinned backgroundAvailabilityRefresh switch on (default off), a cached
    /// "installed" check at least this old is refreshed after a model call returns, so the first request after the
    /// 30 s TTL does not pay the availability check itself. Must stay below installedCheckTTL.
    private let availabilityRefreshAfter: Double = 20
    private var availabilityRefreshing = Set<String>()
    var warmupEvent: ((InitialWarmupEvent) -> Void)?
    var modelRequestCompleted: ((String, String, RequestedTranslationStrategy, Double) -> Void)?
    var warmupSkipDescription = ""
    var event: ((ModeCaption, String, Double?) -> Void)?
    var status: ((String) -> Void)?
    var hostedDefault: (([String], Locale.Language, Locale.Language, Bool) async -> [String]?)?
    /// Checks only not-yet-submitted requests. Already-running calls must drain.
    var mayStartModel: ((ModeCaption, Bool) -> Bool)?

    /// 2.2.3 (L5): refreshes the cached availability result for one language pair and strategy in the background.
    /// Runs only while nothing is translating, never extends a stale entry for a pack that is no longer installed,
    /// and drops its result if the service was reset while the check was running.
    private func refreshAvailabilityIfStale(source: Locale.Language, target: Locale.Language,
                                            strategy: RequestedTranslationStrategy, key: String) {
        guard TranslationHotPathAB.refreshAvailabilityInBackground,
              let verifiedAt = recentlyInstalled[key],
              ProcessInfo.processInfo.systemUptime - verifiedAt >= availabilityRefreshAfter,
              !availabilityRefreshing.contains(key),
              !speculative.busy, !confirmed.busy, !warmupLane.busy, hostedTask == nil else { return }
        availabilityRefreshing.insert(key)
        let revision = generation
        Task { @MainActor in
            defer { self.availabilityRefreshing.remove(key) }
            let availability: LanguageAvailability
            if #available(iOS 26.4, *), strategy == .lowLatency {
                availability = LanguageAvailability(preferredStrategy: .lowLatency)
            } else { availability = LanguageAvailability() }
            let refreshed = await availability.status(from: source, to: target)
            guard revision == self.generation else { return }
            if refreshed == .installed {
                self.recentlyInstalled[key] = ProcessInfo.processInfo.systemUptime
            } else {
                self.recentlyInstalled.removeValue(forKey: key)
            }
        }
    }

    func translate(_ caption: ModeCaption, indices: [Int], strategy: RequestedTranslationStrategy,
                   speculation: Bool, warmup: Bool = false) async -> [String]? {
        func report(_ reason: String, _ duration: Double? = nil) {
            if warmup {
                let phase = reason.replacingOccurrences(of: "confirmed_model_", with: "model_")
                    .replacingOccurrences(of: "recovery_", with: "")
                self.warmupEvent?(InitialWarmupEvent(id: caption.session, system: caption.system ?? .legacy, testMode: caption.rules, source: caption.source, target: caption.target,
                    strategy: strategy, phase: phase, monotonicTime: ProcessInfo.processInfo.systemUptime, durationMs: duration))
            } else { self.event?(caption, reason, duration) }
        }
        let tracksConfirmedDemand = !warmup && !speculation && strategy == .lowLatency
        if tracksConfirmedDemand { confirmedDemand += 1 }
        defer { if tracksConfirmedDemand { confirmedDemand = max(0, confirmedDemand - 1) } }
        let activityID = activity.begin(kind: warmup ? .warmup : (speculation ? .speculative : .confirmed),
            source: caption.source, target: caption.target, strategy: strategy, stage: .waitingForSlot)
        var heldByActualCall = false
        defer { if !heldByActualCall { activity.end(activityID) } }
        func eligibleToStart() -> Bool {
            warmup || mayStartModel?(caption, speculation) != false
        }
        guard eligibleToStart() else {
            report("backend_stale_request_dropped", nil)
            return nil
        }
        if strategy == .lowLatency {
            guard #available(iOS 26.4, *) else {
                status?("Explicit low latency requires iOS 26.4 or later. Select Legacy or Hybrid Recovery to use Apple default.")
                report("unsupported_os", nil)
                return nil
            }
        }
        guard #available(iOS 26.0, *) else {
            guard strategy == .appleDefault else { return nil }
            let enqueued = ProcessInfo.processInfo.systemUptime
            while hostedTask != nil {
                if Task.isCancelled || ProcessInfo.processInfo.systemUptime - enqueued > 4 { return nil }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard !Task.isCancelled else { return nil }
            report("requested_appleDefault", nil)
            report(speculation ? "speculative_queue_ms" : "recovery_queue_ms", (ProcessInfo.processInfo.systemUptime - enqueued) * 1000)
            let began = ProcessInfo.processInfo.systemUptime
            activity.advance(activityID, to: .running); hostedActivityID = activityID
            let task = Task { @MainActor in
                await self.hostedDefault?(indices.map { caption.units[$0] }, Locale.Language(identifier: caption.source),
                    Locale.Language(identifier: caption.target), speculation)
            }
            hostedTask = task; hostedIsSpeculative = speculation
            let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
            hostedTask = nil
            if hostedActivityID == activityID { hostedActivityID = nil }
            let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
            report(speculation ? "speculative_service_ms" : "recovery_service_ms", elapsed)
            if result != nil { modelRequestCompleted?(caption.source, caption.target, strategy, elapsed) }
            return result
        }
        let lane = warmup ? warmupLane : (speculation ? speculative : confirmed)
        let enqueued = ProcessInfo.processInfo.systemUptime
        // One current confirmed waiter; superseded tasks exit without taking a slot.
        while lane.busy {
            guard eligibleToStart() else {
                report("backend_stale_request_dropped", nil)
                report("backend_lane_wait_ms", (ProcessInfo.processInfo.systemUptime - enqueued) * 1000)
                return nil
            }
            if speculation || Task.isCancelled || ProcessInfo.processInfo.systemUptime - enqueued >= 4 {
                report("backend_lane_admission_rejected", nil)
                report("backend_lane_wait_ms", (ProcessInfo.processInfo.systemUptime - enqueued) * 1000)
                return nil
            }
            // Confirmed requests are latency critical. A shorter bounded poll reduces
            // the handoff gap after the previous actual Apple call releases this lane.
            // Speculation never waits here; it is rejected by the guard above.
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        report("backend_lane_wait_ms", (ProcessInfo.processInfo.systemUptime - enqueued) * 1000)
        guard !Task.isCancelled, eligibleToStart() else {
            report("backend_stale_request_dropped", nil)
            return nil
        }
        let source = Locale.Language(identifier: caption.source), target = Locale.Language(identifier: caption.target)
        activity.advance(activityID, to: .checkingLanguages)
        let languageCheckStart = ProcessInfo.processInfo.systemUptime
        let languagePairKey = "\(source.minimalIdentifier)>\(target.minimalIdentifier)"
        let availabilityKey = languagePairKey + "|\(strategy.rawValue)"
        let pairAvailability: LanguageAvailability.Status
        if let verifiedAt = recentlyInstalled[availabilityKey],
           languageCheckStart - verifiedAt < installedCheckTTL {
            pairAvailability = .installed
            report("backend_installed_cache_hit", nil)
        } else {
            let availability: LanguageAvailability
            if #available(iOS 26.4, *), strategy == .lowLatency {
                availability = LanguageAvailability(preferredStrategy: .lowLatency)
            } else { availability = LanguageAvailability() }
            pairAvailability = await availability.status(from: source, to: target)
            if pairAvailability == .installed {
                if recentlyInstalled.count >= 100 { recentlyInstalled.removeAll() }
                recentlyInstalled[availabilityKey] = ProcessInfo.processInfo.systemUptime
            }
        }
        report("backend_availability_ms", (ProcessInfo.processInfo.systemUptime - languageCheckStart) * 1000)
        guard !Task.isCancelled, eligibleToStart() else {
            report("backend_stale_request_dropped", nil)
            return nil
        }
        guard pairAvailability == .installed else {
            report("unsupported_or_uninstalled_pair", nil)
            // Hybrid may still complete this caption through Apple Default.
            // Missing optional fast assets must not display a fatal status.
            if caption.system != .hybridRecovery || strategy != .lowLatency {
                status?("Translation languages unavailable. Open Languages to install the selected pair.")
            }
            return nil
        }
        // Availability suspended. The original admission decision is not a
        // reservation to execute Default later: confirmed LL demand can begin
        // while LanguageAvailability is awaiting its result. Only the H0
        // reference variant preserves v1.9.5's late admission behavior.
        if caption.system == .hybridRecovery && speculation &&
           strategy == .appleDefault &&
           !HybridSchedulingPolicy.maySubmitDefaultAfterAvailability(
               variant: HybridSchedulingPolicy.buildVariant,
               confirmedDemand: hasConfirmedLowLatencyDemand) {
            report("hybrid_speculation_yielded_to_confirmed", nil)
            return nil
        }
        guard !lane.busy, eligibleToStart() else {
            report("backend_stale_request_dropped", nil)
            return nil
        }
        // Physical Apple model requests can continue even after Swift's
        // cancellation. Allow an ongoing speculative Default request a short
        // release window, but never block confirmed Low Latency indefinitely.
        if caption.system == .hybridRecovery && !speculation && strategy == .lowLatency {
            let budget = HybridSchedulingPolicy.physicalDrainBudget(
                variant: HybridSchedulingPolicy.buildVariant,
                speculativeActive: speculative.busy && speculative.requestedStrategy == .appleDefault)
            if budget > 0 {
                let waitStarted = ProcessInfo.processInfo.systemUptime
                while speculative.busy && speculative.requestedStrategy == .appleDefault &&
                      ProcessInfo.processInfo.systemUptime - waitStarted < budget {
                    guard !Task.isCancelled, eligibleToStart() else {
                        report("backend_stale_request_dropped", nil)
                        return nil
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                let elapsed = (ProcessInfo.processInfo.systemUptime - waitStarted) * 1000
                report("hybrid_physical_default_drain_wait_ms", elapsed)
                report(speculative.busy ? "hybrid_default_drain_budget_exceeded" :
                    "hybrid_default_drain_completed", elapsed)
                guard !Task.isCancelled, eligibleToStart() else {
                    report("backend_stale_request_dropped", nil)
                    return nil
                }
            }
        }
        // Both model strategies belong to the same language pair. Comparing
        // strategy-suffixed availability keys incorrectly classified every
        // post-Default LL request as having no recent Default completion.
        let samePairDefaultReturn = speculative.requestedStrategy == .appleDefault &&
            speculative.lastFinishedPair == languagePairKey
        let gapBeforeSettlement: Double?
        if caption.system == .hybridRecovery, !speculation, strategy == .lowLatency,
           samePairDefaultReturn, let previousFinished = speculative.lastFinishedAt {
            let elapsed = (ProcessInfo.processInfo.systemUptime - previousFinished) * 1000
            gapBeforeSettlement = elapsed.isFinite && elapsed >= 0 && elapsed <= 1500 ? elapsed : nil
        } else { gapBeforeSettlement = nil }
        if let gapBeforeSettlement {
            report("hybrid_previous_default_exit_gap_ms", gapBeforeSettlement)
            let proposed = HybridSchedulingPolicy.postDefaultSettlement(
                variant: HybridSchedulingPolicy.buildVariant,
                millisecondsSinceReturn: gapBeforeSettlement)
            if proposed > 0 {
                let settlingStarted = ProcessInfo.processInfo.systemUptime
                // A new speculative request can enter while this task yields;
                // never treat an old elapsed-time calculation as a lease.
                try? await Task.sleep(nanoseconds: UInt64(proposed * 1_000_000_000))
                guard !Task.isCancelled, eligibleToStart() else {
                    report("backend_stale_request_dropped", nil)
                    return nil
                }
                report("hybrid_post_default_settlement_wait_ms",
                       (ProcessInfo.processInfo.systemUptime - settlingStarted) * 1000)
            }
        }
        // A different Default request can start during the bounded settling
        // wait. Revalidate physical occupation instead of trusting old state.
        if caption.system == .hybridRecovery && !speculation && strategy == .lowLatency &&
           speculative.busy && speculative.requestedStrategy == .appleDefault {
            report("hybrid_default_reentered_during_settlement", nil)
        }
        let requestedKey = "\(caption.source)>\(caption.target)|\(strategy.rawValue)"
        let warm = (lane.session != nil && !lane.invalidated && lane.key == requestedKey) ||
            (lane === confirmed && lane.spareSession != nil && lane.spareKey == requestedKey)
        let competingDefault = caption.system == .hybridRecovery && !speculation && strategy == .lowLatency &&
            speculative.busy && speculative.requestedStrategy == .appleDefault
        let previousDefaultGap: Double? = competingDefault ? nil : gapBeforeSettlement
        if competingDefault { report("hybrid_cross_strategy_overlap", nil) }
        // 2.2.1 (D12): a confirmed Default request starting while the speculative lane also runs Default.
        // Marker only; scheduling is unchanged.
        if caption.system == .hybridRecovery && !speculation && strategy == .appleDefault &&
           speculative.busy && speculative.requestedStrategy == .appleDefault {
            report("hybrid_default_default_overlap", nil)
        }
        install(lane, source: source, target: target, strategy: strategy)
        guard let session = lane.session else { return nil }
        let sharedDefaultTicket: UUID?
        if speculation && strategy == .appleDefault && !warmup {
            guard let lease = lane.sharedDefaultLease.begin() else {
                report("backend_lane_admission_rejected", nil)
                return nil
            }
            sharedDefaultTicket = lease
        } else { sharedDefaultTicket = nil }
        lane.busy = true; lane.ticket = UUID(); lane.caption = caption; lane.cancellationAt = nil
        lane.activityID = activityID; heldByActualCall = true
        lane.requestedStrategy = strategy
        activity.advance(activityID, to: .running)
        let ticket = lane.ticket
        report("requested_" + strategy.rawValue, nil)
        report(speculation ? "speculative_model_submitted" : "confirmed_model_submitted", nil)
        report(warm ? "retained_session_start" : "new_session_start", nil)
        if warm, let createdAt = lane.createdAt {
            report("backend_session_age_ms", (ProcessInfo.processInfo.systemUptime - createdAt) * 1000)
        }
        report(speculation ? "speculative_queue_ms" : "recovery_queue_ms",
               (ProcessInfo.processInfo.systemUptime - enqueued) * 1000)
        let dispatched = ProcessInfo.processInfo.systemUptime
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                var completed = false
                let start = ProcessInfo.processInfo.systemUptime
                let finish: ([String]?) -> Void = { result in
                    guard !completed else { return }
                    completed = true; continuation.resume(returning: result)
                }
                let timeout = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    guard !Task.isCancelled, !completed else { return }
                    lane.invalidated = true; lane.sharedDefaultLease.requestCancellation(); session.cancel()
                    if lane.cancellationAt == nil {
                        lane.cancellationAt = ProcessInfo.processInfo.systemUptime
                        report("cancellation_requested")
                    }
                    self.activity.advance(activityID, to: .cancelling)
                    report("model_timeout", nil)
                    finish(nil)
                }
                Task { @MainActor in
                    report("backend_task_dispatch_ms", (ProcessInfo.processInfo.systemUptime - dispatched) * 1000)
                    report("backend_apple_call_entered", nil)
                    let requests = indices.enumerated().map {
                        TranslationSession.Request(sourceText: caption.units[$0.element], clientIdentifier: String($0.offset))
                    }
                    var output: [String]?
                    do {
                        let response = try await session.translations(from: requests)
                        output = PipelineSafety.orderedTranslations(response.map { ($0.clientIdentifier, $0.targetText) }, count: indices.count)
                    } catch {
                        self.recentlyInstalled.removeValue(forKey: availabilityKey)
                        report("model_error", nil)
                    }
                    timeout.cancel()
                    let finishedAt = ProcessInfo.processInfo.systemUptime
                    if strategy == .appleDefault { self.lastAppleDefaultReturn[languagePairKey] = finishedAt }
                    let serviceMs = (finishedAt - start) * 1000
                    report("backend_apple_call_returned", serviceMs)
                    if let previousDefaultGap {
                        report("hybrid_recovery_post_default_service_ms", serviceMs)
                        if serviceMs >= 800 { report("hybrid_slow_post_default_ms", serviceMs) }
                    } else if caption.system == .hybridRecovery && !speculation &&
                              strategy == .lowLatency && !competingDefault {
                        report("hybrid_recovery_no_recent_overlap_service_ms", serviceMs)
                        if serviceMs >= 800 {
                            report("hybrid_unexplained_slow_recovery_ms", serviceMs)
                        }
                    }
                    report(output == nil ? "model_batch_failed" : "model_batch_completed", serviceMs)
                    if output != nil {
                        // Warm-up completion is accounted for by warmupEvent.
                        // Do not also count it as a live model request.
                        if !warmup {
                            self.modelRequestCompleted?(caption.source, caption.target, strategy, serviceMs)
                        }
                        report(speculation ? "speculative_model_completed" : "confirmed_model_completed", serviceMs)
                    }
                    report(speculation ? "speculative_service_ms" : "recovery_service_ms", serviceMs)
                    if competingDefault {
                        report("hybrid_overlapped_recovery_ms", serviceMs)
                        // Service time includes non-overlapping work; this second
                        // metric measures simultaneous lane occupancy only.
                        let overlapEnd = speculative.busy ? finishedAt : (speculative.lastFinishedAt ?? dispatched)
                        let overlapMs = max(0, min(finishedAt, overlapEnd) - dispatched) * 1000
                        report("hybrid_simultaneous_model_overlap_ms", overlapMs)
                    }
                    if lane.ticket == ticket {
                        if let sharedDefaultTicket,
                           !lane.sharedDefaultLease.finish(sharedDefaultTicket, successful: output != nil) {
                            lane.invalidated = true
                        }
                        lane.lastFinishedAt = finishedAt
                        lane.lastFinishedPair = languagePairKey
                        if let cancelled = lane.cancellationAt {
                            report("cancelled_call_returned", (ProcessInfo.processInfo.systemUptime - cancelled) * 1000)
                        }
                        lane.busy = false; lane.caption = nil; lane.cancellationAt = nil
                        lane.activityID = nil
                        if lane.invalidated || output == nil {
                            lane.session = nil; lane.key = ""
                            lane.createdAt = nil; lane.completedCalls = 0
                            // Preserve the last physical return time so an
                            // overlapped recovery can measure its actual span.
                        } else {
                            lane.completedCalls += 1
                            report("backend_session_reuse_count", Double(lane.completedCalls))
                        }
                    }
                    self.activity.end(activityID)
                    // 2.2.3 (L5): no-op unless the pinned switch is on; never delays finish().
                    self.refreshAvailabilityIfStale(source: source, target: target, strategy: strategy, key: availabilityKey)
                    finish(lane.invalidated ? nil : output)
                }
            }
        }, onCancel: {
            Task { @MainActor in
                guard lane.ticket == ticket, lane.busy else { return }
                lane.invalidated = true; lane.sharedDefaultLease.requestCancellation(); session.cancel()
                if lane.cancellationAt == nil {
                        lane.cancellationAt = ProcessInfo.processInfo.systemUptime
                        report("cancellation_requested")
                    }
                self.activity.advance(activityID, to: .cancelling)
            }
        })
    }
}
