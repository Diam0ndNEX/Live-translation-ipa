import Foundation
import Translation

/// Installed-language sessions are independent of SwiftUI translationTask lifetimes.
/// There is at most one real Apple request per lane, even after a timeout.
@MainActor
final class ModeTranslationService {
    private final class Lane {
        var session: TranslationSession?
        var key = ""
        var busy = false
        var ticket = UUID()
        var invalidated = false
        var caption: ModeCaption?
        var cancellationAt: Double?
        var activityID: UUID?
        var requestedStrategy: RequestedTranslationStrategy?
    }
    private var hostedIsSpeculative = false
    private var hostedTask: Task<[String]?, Never>?
    private var hostedActivityID: UUID?
    var activityChanged: ((TranslationBackendActivity) -> Void)?
    private var activity = TranslationBackendActivity() { didSet { activityChanged?(activity) } }
    private var generation = 0
    private var preparationRevision = 0
    private let speculative = Lane()
    private let confirmed = Lane()
    private let warmupLane = Lane()
    private var warmupPolicy = InitialWarmupPolicy()
    var warmupEvent: ((InitialWarmupEvent) -> Void)?
    var modelRequestCompleted: ((String, String, RequestedTranslationStrategy, Double) -> Void)?
    private(set) var warmupSkipDescription = ""
    var event: ((ModeCaption, String, Double?) -> Void)?
    var status: ((String) -> Void)?
    var hostedDefault: (([String], Locale.Language, Locale.Language, Bool) async -> [String]?)?

    func cancel(speculation: Bool) {
        let lane = speculation ? speculative : confirmed
        if hostedIsSpeculative == speculation {
            hostedTask?.cancel()
            if let id = hostedActivityID { activity.advance(id, to: .cancelling) }
        }
        if #available(iOS 26.0, *), lane.busy {
            if lane.cancellationAt == nil {
                lane.cancellationAt = ProcessInfo.processInfo.systemUptime
                if let caption = lane.caption { event?(caption, "cancellation_requested", nil) }
            }
            lane.invalidated = true
            if let id = lane.activityID { activity.advance(id, to: .cancelling) }
            lane.session?.cancel()
        }
    }

    func cancelWarmup() {
        if #available(iOS 26.0, *), warmupLane.busy {
            if warmupLane.cancellationAt == nil, let caption = warmupLane.caption, let strategy = warmupLane.requestedStrategy {
                warmupLane.cancellationAt = ProcessInfo.processInfo.systemUptime
                warmupEvent?(InitialWarmupEvent(id: caption.session, system: caption.system ?? .legacy, testMode: caption.rules,
                    source: caption.source, target: caption.target, strategy: strategy, phase: "cancellation_requested",
                    monotonicTime: ProcessInfo.processInfo.systemUptime, durationMs: nil))
            }
            warmupLane.invalidated = true
            if let id = warmupLane.activityID { activity.advance(id, to: .cancelling) }
            warmupLane.session?.cancel()
        }
    }

    func reset(preserveIdleSessions: Bool = false) {
        cancelWarmup()
        generation += 1
        hostedTask?.cancel()
        if let id = hostedActivityID { activity.advance(id, to: .cancelling) }
        for lane in [speculative, confirmed, warmupLane] {
            if preserveIdleSessions, lane !== warmupLane, !lane.busy, !lane.invalidated { continue }
            if #available(iOS 26.0, *) { lane.session?.cancel() }
            lane.invalidated = true
            if let id = lane.activityID { activity.advance(id, to: .cancelling) }
            if !lane.busy { lane.session = nil; lane.key = "" }
        }
    }

    /// Once per pair/strategy/process. Output is discarded here and never reaches the coordinator.
    func warmInitially(source: String, target: String, system: TranslationSystem, testMode: String, samples: [String]) async -> Int? {
        guard #available(iOS 26.4, *), !samples.isEmpty, !warmupLane.busy,
              !speculative.busy, !confirmed.busy else { return nil }
        let revision = generation
        var completedStrategies = 0
        warmupSkipDescription = ""
        for strategy in InitialWarmupPolicy.strategies(for: system) {
            guard !Task.isCancelled, generation == revision, !warmupLane.busy,
                  !speculative.busy, !confirmed.busy else { return nil }
            guard warmupPolicy.claim(source: source, target: target, strategy: strategy) else {
                warmupSkipDescription = warmupPolicy.skippedReason(source: source, target: target, strategy: strategy)
                continue
            }
            let caption = ModeCaption(system: system, session: UUID(), caption: "initial-warmup", revision: 0,
                source: source, target: target, rules: testMode, text: "",
                units: samples, keys: samples.indices.map { "warmup-\($0)" }, firstOCR: ProcessInfo.processInfo.systemUptime)
            let result = await translate(caption, indices: Array(samples.indices), strategy: strategy, speculation: false, warmup: true)
            let succeeded = !Task.isCancelled && revision == generation && result != nil && !warmupLane.invalidated
            warmupPolicy.finish(source: source, target: target, strategy: strategy, succeeded: succeeded)
            guard succeeded else { return nil }
            // Promote the exercised handle, keeping confirmed recovery independent of a cancelled warm-up.
            let destination = system == .hybridRecovery && strategy == .lowLatency ? confirmed : speculative
            guard !destination.busy else { return nil }
            destination.session?.cancel()
            destination.session = warmupLane.session; destination.key = warmupLane.key; destination.invalidated = false
            warmupLane.session = nil; warmupLane.key = ""
            completedStrategies += 1
        }
        return completedStrategies
    }

    func prepare(source: String, target: String, system: TranslationSystem,
                 progress: ((TranslationReadiness.Preparation) -> Void)? = nil) async -> String {
        let activityID = activity.begin(kind: .preparation, source: source, target: target,
            strategy: .lowLatency, stage: .checkingLanguages)
        defer { activity.end(activityID) }
        preparationRevision &+= 1
        let preparation = preparationRevision
        guard #available(iOS 26.4, *) else {
            progress?(.unavailable)
            return system == .hybridRecovery ? "Fast recovery needs iOS 26.4; Apple default fallback remains available" : "Explicit low latency requires iOS 26.4 or later"
        }
        let revision = generation
        let src = Locale.Language(identifier: source), dst = Locale.Language(identifier: target)
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        progress?(.checkingLanguages)
        guard await availability.status(from: src, to: dst) == .installed else {
            if revision == generation, preparation == preparationRevision, !Task.isCancelled { progress?(.languagesUnavailable) }
            return "Low-latency languages unavailable. Install this pair in Languages."
        }
        guard revision == generation, preparation == preparationRevision, !Task.isCancelled else { return "Preparation superseded" }
        progress?(.languagesInstalled)
        progress?(.creatingSessions)
        activity.advance(activityID, to: .preparingSessions)
        if !confirmed.busy {
            install(confirmed, source: src, target: dst, strategy: .lowLatency)
        }
        if !speculative.busy {
            install(speculative, source: src, target: dst,
                    strategy: system == .lowLatency ? .lowLatency : .appleDefault)
        }
        let pair = "\(src.minimalIdentifier)>\(dst.minimalIdentifier)|"
        let speculativeStrategy: RequestedTranslationStrategy = system == .lowLatency ? .lowLatency : .appleDefault
        let confirmedSession = confirmed.session, speculativeSession = speculative.session
        progress?(.checkingSessions)
        let confirmedSessionReady = await confirmedSession?.isReady == true
        let speculativeSessionReady = await speculativeSession?.isReady == true
        guard revision == generation, preparation == preparationRevision, !Task.isCancelled else { return "Preparation superseded" }
        let confirmedReady = !confirmed.invalidated && confirmed.key == pair + RequestedTranslationStrategy.lowLatency.rawValue && confirmed.session === confirmedSession && confirmedSessionReady
        let speculativeReady = !speculative.invalidated && speculative.key == pair + speculativeStrategy.rawValue && speculative.session === speculativeSession && speculativeSessionReady
        progress?(confirmedReady && speculativeReady ? .sessionsReady : .sessionsWaiting)
        return confirmedReady && speculativeReady ? "Languages and sessions ready; model residency unmeasured" : "Languages installed; waiting for valid session resources"
    }

    @available(iOS 26.0, *)
    private func install(_ lane: Lane, source: Locale.Language, target: Locale.Language,
                         strategy: RequestedTranslationStrategy) {
        let key = "\(source.minimalIdentifier)>\(target.minimalIdentifier)|\(strategy.rawValue)"
        guard lane.session == nil || lane.key != key || lane.invalidated else { return }
        if strategy == .lowLatency {
            guard #available(iOS 26.4, *) else { return }
            lane.session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        } else { lane.session = TranslationSession(installedSource: source, target: target) }
        lane.key = key; lane.invalidated = false
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
            if speculation || Task.isCancelled || ProcessInfo.processInfo.systemUptime - enqueued >= 4 { return nil }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !Task.isCancelled else { return nil }
        let source = Locale.Language(identifier: caption.source), target = Locale.Language(identifier: caption.target)
        activity.advance(activityID, to: .checkingLanguages)
        let availability: LanguageAvailability
        if #available(iOS 26.4, *), strategy == .lowLatency {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else { availability = LanguageAvailability() }
        let pairAvailability = await availability.status(from: source, to: target)
        guard !Task.isCancelled else { return nil }
        guard pairAvailability == .installed else {
            report("unsupported_or_uninstalled_pair", nil)
            status?("Translation languages unavailable. Open Languages to install the selected pair.")
            return nil
        }
        // Availability suspended; recheck the lease before acquiring it.
        guard !lane.busy else { return nil }
        let warm = lane.session != nil && !lane.invalidated && lane.key == "\(caption.source)>\(caption.target)|\(strategy.rawValue)"
        install(lane, source: source, target: target, strategy: strategy)
        guard let session = lane.session else { return nil }
        lane.busy = true; lane.ticket = UUID(); lane.caption = caption; lane.cancellationAt = nil
        lane.activityID = activityID; heldByActualCall = true
        lane.requestedStrategy = strategy
        activity.advance(activityID, to: .running)
        let ticket = lane.ticket
        report("requested_" + strategy.rawValue, nil)
        report(speculation ? "speculative_model_submitted" : "confirmed_model_submitted", nil)
        report(warm ? "retained_session_start" : "new_session_start", nil)
        report(speculation ? "speculative_queue_ms" : "recovery_queue_ms",
               (ProcessInfo.processInfo.systemUptime - enqueued) * 1000)
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
                    lane.invalidated = true; session.cancel()
                    if warmup, lane.cancellationAt == nil { lane.cancellationAt = ProcessInfo.processInfo.systemUptime; report("cancellation_requested") }
                    self.activity.advance(activityID, to: .cancelling)
                    report("model_timeout", nil)
                    finish(nil)
                }
                Task { @MainActor in
                    let requests = indices.enumerated().map {
                        TranslationSession.Request(sourceText: caption.units[$0.element], clientIdentifier: String($0.offset))
                    }
                    var output: [String]?
                    do {
                        let response = try await session.translations(from: requests)
                        output = PipelineSafety.orderedTranslations(response.map { ($0.clientIdentifier, $0.targetText) }, count: indices.count)
                    } catch {
                        report("model_error", nil)
                    }
                    timeout.cancel()
                    report(output == nil ? "model_batch_failed" : "model_batch_completed", nil)
                    if output != nil {
                        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                        self.modelRequestCompleted?(caption.source, caption.target, strategy, elapsed)
                        report(speculation ? "speculative_model_completed" : "confirmed_model_completed", elapsed)
                    }
                    report(speculation ? "speculative_service_ms" : "recovery_service_ms",
                        (ProcessInfo.processInfo.systemUptime - start) * 1000)
                    if lane.ticket == ticket {
                        if let cancelled = lane.cancellationAt {
                            report("cancelled_call_returned", (ProcessInfo.processInfo.systemUptime - cancelled) * 1000)
                        }
                        lane.busy = false; lane.caption = nil; lane.cancellationAt = nil
                        lane.activityID = nil
                        if lane.invalidated || output == nil { lane.session = nil; lane.key = "" }
                    }
                    self.activity.end(activityID)
                    finish(lane.invalidated ? nil : output)
                }
            }
        }, onCancel: {
            Task { @MainActor in
                guard lane.ticket == ticket, lane.busy else { return }
                lane.invalidated = true; session.cancel()
                if warmup, lane.cancellationAt == nil { lane.cancellationAt = ProcessInfo.processInfo.systemUptime; report("cancellation_requested") }
                self.activity.advance(activityID, to: .cancelling)
            }
        })
    }
}
