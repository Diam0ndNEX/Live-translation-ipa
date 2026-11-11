import Foundation
import Translation

extension ModeTranslationService {
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
            lane.sharedDefaultLease.requestCancellation()
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
            lane.sharedDefaultLease.reset()
            if preserveIdleSessions, lane !== warmupLane, !lane.busy, !lane.invalidated { continue }
            if #available(iOS 26.0, *) { lane.session?.cancel() }
            lane.invalidated = true
            if let id = lane.activityID { activity.advance(id, to: .cancelling) }
            if !lane.busy {
                lane.session = nil; lane.key = ""
                lane.createdAt = nil; lane.completedCalls = 0
                lane.lastFinishedAt = nil
                lane.lastFinishedPair = ""
            }
        }
    }

    /// Once per pair/strategy/process. Output is discarded here and never reaches the coordinator.
    /// `repeatable` (2.5.0, item A): the warm-up at capture start and after a quiet stretch runs again even when
    /// this pair was already warmed earlier in the process.
    func warmInitially(source: String, target: String, system: TranslationSystem, testMode: String, samples: [String],
                       repeatable: Bool = false) async -> Int? {
        guard #available(iOS 26.4, *), !samples.isEmpty, !warmupLane.busy,
              !speculative.busy, !confirmed.busy else { return nil }
        let revision = generation
        var completedStrategies = 0
        warmupSkipDescription = ""
        for strategy in InitialWarmupPolicy.strategies(for: system) {
            guard !Task.isCancelled, generation == revision, !warmupLane.busy,
                  !speculative.busy, !confirmed.busy else { return nil }
            guard repeatable || warmupPolicy.claim(source: source, target: target, strategy: strategy) else {
                warmupSkipDescription = warmupPolicy.skippedReason(source: source, target: target, strategy: strategy)
                continue
            }
            let caption = ModeCaption(system: system, session: UUID(), caption: "initial-warmup", revision: 0,
                source: source, target: target, rules: testMode, text: "",
                units: samples, keys: samples.indices.map { "warmup-\($0)" }, firstOCR: ProcessInfo.processInfo.systemUptime)
            let result = await translate(caption, indices: Array(samples.indices), strategy: strategy, speculation: false, warmup: true)
            let succeeded = !Task.isCancelled && revision == generation && !warmupLane.invalidated &&
                result?.count == samples.count &&
                result?.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
            guard succeeded else {
                warmupPolicy.finish(source: source, target: target, strategy: strategy, succeeded: false)
                return completedStrategies > 0 ? completedStrategies : nil
            }
            // Promote only an actual successful idle session, never an abandoned handle.
            let destination = speculative
            guard !destination.busy, let session = warmupLane.session else {
                warmupPolicy.finish(source: source, target: target, strategy: strategy, succeeded: false)
                return completedStrategies > 0 ? completedStrategies : nil
            }
            destination.session?.cancel()
            destination.session = session; destination.key = warmupLane.key; destination.invalidated = false
            destination.createdAt = warmupLane.createdAt
            destination.completedCalls = warmupLane.completedCalls
            destination.lastFinishedAt = warmupLane.lastFinishedAt
            destination.lastFinishedPair = warmupLane.lastFinishedPair
            warmupLane.session = nil; warmupLane.key = ""
            warmupLane.createdAt = nil; warmupLane.completedCalls = 0
            warmupLane.lastFinishedAt = nil
            warmupLane.lastFinishedPair = ""
            warmupPolicy.finish(source: source, target: target, strategy: strategy, succeeded: true)
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
            return "Explicit low latency requires iOS 26.4 or later"
        }
        let revision = generation
        let src = Locale.Language(identifier: source), dst = Locale.Language(identifier: target)
        progress?(.checkingLanguages)
        let lowState = await LanguageAvailability(preferredStrategy: .lowLatency).status(from: src, to: dst)
        guard revision == generation, preparation == preparationRevision, !Task.isCancelled else {
            return "Preparation superseded"
        }
        let lowInstalled = lowState == .installed
        guard lowInstalled else {
            progress?(.languagesUnavailable)
            return lowState == .unsupported ?
                "Low Latency does not support this pair. Choose Legacy for it." :
                "The required language pack is not installed. Open Languages for this pair."
        }
        progress?(.languagesInstalled)
        progress?(.creatingSessions)
        activity.advance(activityID, to: .preparingSessions)
        let pair = "\(src.minimalIdentifier)>\(dst.minimalIdentifier)|"
        let speculativeStrategy = RequestedTranslationStrategy.lowLatency
        let speculativeInstalled = lowInstalled
        if lowInstalled && !confirmed.busy {
            install(confirmed, source: src, target: dst, strategy: .lowLatency)
        }
        if speculativeInstalled && !speculative.busy {
            install(speculative, source: src, target: dst, strategy: speculativeStrategy)
        }
        let confirmedSession = lowInstalled ? confirmed.session : nil
        let speculativeSession = speculativeInstalled ? speculative.session : nil
        progress?(.checkingSessions)
        let confirmedSessionReady = await confirmedSession?.isReady == true
        let speculativeSessionReady = await speculativeSession?.isReady == true
        guard revision == generation, preparation == preparationRevision, !Task.isCancelled else {
            return "Preparation superseded"
        }
        let confirmedReady = lowInstalled && !confirmed.invalidated &&
            confirmed.key == pair + RequestedTranslationStrategy.lowLatency.rawValue &&
            confirmed.session === confirmedSession && confirmedSessionReady
        let speculativeReady = !speculative.invalidated &&
            speculative.key == pair + speculativeStrategy.rawValue &&
            speculative.session === speculativeSession && speculativeSessionReady
        let ready = speculativeReady && confirmedReady
        progress?(ready ? .sessionsReady : .sessionsWaiting)
        return ready ? "Languages and sessions ready; model residency unmeasured" :
            "Languages installed; waiting for valid session resources"
    }

    @available(iOS 26.0, *)
    func install(_ lane: Lane, source: Locale.Language, target: Locale.Language,
                         strategy: RequestedTranslationStrategy) {
        let key = "\(source.minimalIdentifier)>\(target.minimalIdentifier)|\(strategy.rawValue)"
        guard lane.session == nil || lane.key != key || lane.invalidated else { return }
        if strategy == .lowLatency {
            guard #available(iOS 26.4, *) else { return }
            lane.session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        } else { lane.session = TranslationSession(installedSource: source, target: target) }
        lane.key = key; lane.invalidated = false
        lane.createdAt = ProcessInfo.processInfo.systemUptime
        lane.lastFinishedAt = nil
        lane.lastFinishedPair = ""
        lane.completedCalls = 0
    }
}
