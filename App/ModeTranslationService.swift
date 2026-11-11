import Foundation
import Translation

/// Installed-language sessions are independent of SwiftUI translationTask lifetimes.
/// There is at most one real Apple request per lane, even after a timeout.
@MainActor
final class ModeTranslationService {
    var hostedIsSpeculative = false
    var hostedTask: Task<[String]?, Never>?
    var hostedActivityID: UUID?
    var activityChanged: ((TranslationBackendActivity) -> Void)?
    var activity = TranslationBackendActivity() { didSet { activityChanged?(activity) } }
    var generation = 0
    var preparationRevision = 0
    let speculative = Lane()
    let confirmed = Lane()
    let warmupLane = Lane()
    var warmupPolicy = InitialWarmupPolicy()
    private var recentlyInstalled: [String: Double] = [:]
    private let installedCheckTTL: Double = 30
    /// 2.2.3 (L5, UNVERIFIED): with the pinned backgroundAvailabilityRefresh switch on (default on since 2.4.0), a cached
    /// "installed" check at least this old is refreshed after a model call returns, so the first request after the
    /// 30 s TTL does not pay the availability check itself. Must stay below installedCheckTTL.
    private let availabilityRefreshAfter: Double = 20
    private var availabilityRefreshing = Set<String>()
    var warmupEvent: ((InitialWarmupEvent) -> Void)?
    var modelRequestCompleted: ((String, String, RequestedTranslationStrategy, Double) -> Void)?
    var warmupSkipDescription = ""
    /// 2.5.0 (item D): characters sent to the model in one completed live call, and its duration. Numbers only.
    var modelLengthObserved: ((Int, Double) -> Void)?
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
                status?("Explicit low latency requires iOS 26.4 or later. Select Legacy to use Apple default.")
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
            // 2.5.0: Low Latency never falls back to another model by itself. The person is told and decides.
            status?("Translation languages unavailable. Open Languages to install the selected pair.")
            return nil
        }
        guard !lane.busy, eligibleToStart() else {
            report("backend_stale_request_dropped", nil)
            return nil
        }
        let requestedKey = "\(caption.source)>\(caption.target)|\(strategy.rawValue)"
        let warm = lane.session != nil && !lane.invalidated && lane.key == requestedKey
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
        let requests = indices.enumerated().map {
            TranslationSession.Request(sourceText: caption.units[$0.element], clientIdentifier: String($0.offset))
        }
        // 2.4.0: the Apple call starts at once in a task of its own that does not run on the main actor. Before, it
        // was started from a new main-actor task, which had to wait for other main-actor work first
        // (backend_task_dispatch_ms, P90 17 to 34 ms in the 2.3.9 device report). As before, the call is not tied to
        // the caller's Swift cancellation: only session.cancel() stops it, and the lane stays occupied until it
        // really returns. The time limit now asks the session to cancel instead of answering early.
        let call = Task.detached(priority: .userInitiated) { () async -> Result<[String]?, Error> in
            do {
                let response = try await session.translations(from: requests)
                return .success(PipelineSafety.orderedTranslations(
                    response.map { ($0.clientIdentifier, $0.targetText) }, count: requests.count))
            } catch {
                return .failure(error)
            }
        }
        report("backend_task_dispatch_ms", (ProcessInfo.processInfo.systemUptime - dispatched) * 1000)
        report("backend_apple_call_entered", nil)
        let start = dispatched
        let timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, lane.ticket == ticket, lane.busy else { return }
            lane.invalidated = true; lane.sharedDefaultLease.requestCancellation(); session.cancel()
            if lane.cancellationAt == nil {
                lane.cancellationAt = ProcessInfo.processInfo.systemUptime
                report("cancellation_requested")
            }
            self.activity.advance(activityID, to: .cancelling)
            report("model_timeout", nil)
        }
        let outcome = await withTaskCancellationHandler(operation: { await call.value }, onCancel: {
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
        timeout.cancel()
        var output: [String]?
        switch outcome {
        case .success(let values): output = values
        case .failure:
            recentlyInstalled.removeValue(forKey: availabilityKey)
            report("model_error", nil)
        }
        let finishedAt = ProcessInfo.processInfo.systemUptime
        let serviceMs = (finishedAt - start) * 1000
        report("backend_apple_call_returned", serviceMs)
        report(output == nil ? "model_batch_failed" : "model_batch_completed", serviceMs)
        if output != nil {
            // Warm-up completion is accounted for by warmupEvent.
            // Do not also count it as a live model request.
            if !warmup {
                modelRequestCompleted?(caption.source, caption.target, strategy, serviceMs)
                if TranslationHotPathAB.modelLengthBuckets {
                    modelLengthObserved?(indices.reduce(0) { $0 + caption.units[$1].count }, serviceMs)
                }
            }
            report(speculation ? "speculative_model_completed" : "confirmed_model_completed", serviceMs)
        }
        report(speculation ? "speculative_service_ms" : "recovery_service_ms", serviceMs)
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
            } else {
                lane.completedCalls += 1
                report("backend_session_reuse_count", Double(lane.completedCalls))
            }
        }
        activity.end(activityID)
        // 2.2.3 (L5): no-op unless the pinned switch is on; never delays the return.
        self.refreshAvailabilityIfStale(source: source, target: target, strategy: strategy, key: availabilityKey)
        return lane.invalidated ? nil : output
    }
}
