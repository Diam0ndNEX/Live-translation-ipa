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
    }
    private var hostedIsSpeculative = false
    private var hostedTask: Task<[String]?, Never>?
    private var generation = 0
    private let speculative = Lane()
    private let confirmed = Lane()
    var event: ((ModeCaption, String, Double?) -> Void)?
    var status: ((String) -> Void)?
    var hostedDefault: (([String], Locale.Language, Locale.Language, Bool) async -> [String]?)?

    func cancel(speculation: Bool) {
        let lane = speculation ? speculative : confirmed
        if hostedIsSpeculative == speculation { hostedTask?.cancel() }
        if #available(iOS 26.0, *), lane.busy {
            if lane.cancellationAt == nil {
                lane.cancellationAt = ProcessInfo.processInfo.systemUptime
                if let caption = lane.caption { event?(caption, "cancellation_requested", nil) }
            }
            lane.invalidated = true
            lane.session?.cancel()
        }
    }

    func reset() {
        generation += 1
        hostedTask?.cancel()
        for lane in [speculative, confirmed] {
            if #available(iOS 26.0, *) { lane.session?.cancel() }
            lane.invalidated = true
            if !lane.busy { lane.session = nil; lane.key = "" }
        }
    }

    func prepare(source: String, target: String, system: TranslationSystem) async -> String {
        guard #available(iOS 26.4, *) else { return "Explicit low latency requires iOS 26.4 or later" }
        let revision = generation
        let src = Locale.Language(identifier: source), dst = Locale.Language(identifier: target)
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        guard await availability.status(from: src, to: dst) == .installed else {
            return "Low-latency languages unavailable. Install this pair in Languages."
        }
        guard revision == generation, !Task.isCancelled else { return "Preparation superseded" }
        if !confirmed.busy {
            install(confirmed, source: src, target: dst, strategy: .lowLatency)
        }
        if !speculative.busy {
            install(speculative, source: src, target: dst,
                    strategy: system == .lowLatency ? .lowLatency : .appleDefault)
        }
        return "Languages and sessions ready; model residency unmeasured"
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
                   speculation: Bool) async -> [String]? {
        if strategy == .lowLatency {
            guard #available(iOS 26.4, *) else {
                status?("Explicit low latency requires iOS 26.4 or later. Select Legacy or Hybrid Recovery to use Apple default.")
                event?(caption, "unsupported_os", nil)
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
            event?(caption, "requested_appleDefault", nil)
            let task = Task { @MainActor in
                await self.hostedDefault?(indices.map { caption.units[$0] }, Locale.Language(identifier: caption.source),
                    Locale.Language(identifier: caption.target), speculation)
            }
            hostedTask = task; hostedIsSpeculative = speculation
            let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
            hostedTask = nil
            return result
        }
        let lane = speculation ? speculative : confirmed
        let enqueued = ProcessInfo.processInfo.systemUptime
        // One current confirmed waiter; superseded tasks exit without taking a slot.
        while lane.busy {
            if speculation || Task.isCancelled || ProcessInfo.processInfo.systemUptime - enqueued >= 4 { return nil }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !Task.isCancelled else { return nil }
        let source = Locale.Language(identifier: caption.source), target = Locale.Language(identifier: caption.target)
        let availability: LanguageAvailability
        if #available(iOS 26.4, *), strategy == .lowLatency {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else { availability = LanguageAvailability() }
        let pairAvailability = await availability.status(from: source, to: target)
        guard !Task.isCancelled else { return nil }
        guard pairAvailability == .installed else {
            event?(caption, "unsupported_or_uninstalled_pair", nil)
            status?("Translation languages unavailable. Open Languages to install the selected pair.")
            return nil
        }
        // Availability suspended; recheck the lease before acquiring it.
        guard !lane.busy else { return nil }
        let warm = lane.session != nil && !lane.invalidated && lane.key == "\(caption.source)>\(caption.target)|\(strategy.rawValue)"
        install(lane, source: source, target: target, strategy: strategy)
        guard let session = lane.session else { return nil }
        lane.busy = true; lane.ticket = UUID(); lane.caption = caption; lane.cancellationAt = nil
        let ticket = lane.ticket
        event?(caption, "requested_" + strategy.rawValue, nil)
        event?(caption, speculation ? "speculative_model_submitted" : "confirmed_model_submitted", nil)
        event?(caption, warm ? "retained_session_start" : "new_session_start", nil)
        event?(caption, speculation ? "speculative_queue_ms" : "recovery_queue_ms",
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
                    self.event?(caption, "model_timeout", nil)
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
                        self.event?(caption, "model_error", nil)
                    }
                    timeout.cancel()
                    self.event?(caption, output == nil ? "model_batch_failed" : "model_batch_completed", nil)
                    if output != nil {
                        self.event?(caption, speculation ? "speculative_model_completed" : "confirmed_model_completed",
                            (ProcessInfo.processInfo.systemUptime - start) * 1000)
                    }
                    self.event?(caption, speculation ? "speculative_service_ms" : "recovery_service_ms",
                        (ProcessInfo.processInfo.systemUptime - start) * 1000)
                    if lane.ticket == ticket {
                        if let cancelled = lane.cancellationAt {
                            self.event?(caption, "cancelled_call_returned", (ProcessInfo.processInfo.systemUptime - cancelled) * 1000)
                        }
                        lane.busy = false; lane.caption = nil; lane.cancellationAt = nil
                        if lane.invalidated || output == nil { lane.session = nil; lane.key = "" }
                    }
                    finish(lane.invalidated ? nil : output)
                }
            }
        }, onCancel: {
            Task { @MainActor in
                guard lane.ticket == ticket, lane.busy else { return }
                lane.invalidated = true; session.cancel()
            }
        })
    }
}
