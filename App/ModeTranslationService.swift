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
    }
    private let speculative = Lane()
    private let confirmed = Lane()
    var event: ((ModeCaption, String, Double?) -> Void)?
    var status: ((String) -> Void)?

    func cancel(speculation: Bool) {
        let lane = speculation ? speculative : confirmed
        if #available(iOS 26.0, *), lane.busy {
            lane.invalidated = true
            lane.session?.cancel()
        }
    }

    func reset() {
        for lane in [speculative, confirmed] {
            if #available(iOS 26.0, *) { lane.session?.cancel() }
            lane.invalidated = true
            if !lane.busy { lane.session = nil; lane.key = "" }
        }
    }

    func prepare(source: String, target: String, system: TranslationSystem) async -> String {
        guard #available(iOS 26.4, *) else { return "Explicit low latency requires iOS 26.4 or later" }
        let src = Locale.Language(identifier: source), dst = Locale.Language(identifier: target)
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        guard await availability.status(from: src, to: dst) == .installed else {
            return "Low-latency languages unavailable. Install this pair in Languages."
        }
        if !confirmed.busy {
            install(confirmed, source: src, target: dst, strategy: .lowLatency)
        }
        if !speculative.busy {
            install(speculative, source: src, target: dst,
                    strategy: system == .lowLatency ? .lowLatency : .appleDefault)
        }
        return "Languages and sessions ready; model residency unmeasured"
    }

    @available(iOS 26.4, *)
    private func install(_ lane: Lane, source: Locale.Language, target: Locale.Language,
                         strategy: RequestedTranslationStrategy) {
        let key = "\(source.minimalIdentifier)>\(target.minimalIdentifier)|\(strategy.rawValue)"
        guard lane.session == nil || lane.key != key || lane.invalidated else { return }
        lane.session = strategy == .lowLatency ?
            TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency) :
            TranslationSession(installedSource: source, target: target)
        lane.key = key; lane.invalidated = false
    }

    func translate(_ caption: ModeCaption, indices: [Int], strategy: RequestedTranslationStrategy,
                   speculation: Bool) async -> [String]? {
        guard #available(iOS 26.4, *) else {
            status?("Explicit low latency requires iOS 26.4 or later. Select Legacy to use the established pipeline.")
            event?(caption, "unsupported_os", nil)
            return nil
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
        let availability = strategy == .lowLatency ? LanguageAvailability(preferredStrategy: .lowLatency) : LanguageAvailability()
        guard await availability.status(from: source, to: target) == .installed, !Task.isCancelled else {
            event?(caption, "unsupported_or_uninstalled_pair", nil)
            status?("Translation languages unavailable. Open Languages to install the selected pair.")
            return nil
        }
        // Availability suspended; recheck the lease before acquiring it.
        guard !lane.busy else { return nil }
        let warm = lane.session != nil && !lane.invalidated && lane.key == "\(caption.source)>\(caption.target)|\(strategy.rawValue)"
        install(lane, source: source, target: target, strategy: strategy)
        guard let session = lane.session else { return nil }
        lane.busy = true; lane.ticket = UUID()
        let ticket = lane.ticket
        event?(caption, "requested_" + strategy.rawValue, nil)
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
                    self.event?(caption, speculation ? "speculative_service_ms" : "recovery_service_ms",
                        (ProcessInfo.processInfo.systemUptime - start) * 1000)
                    if lane.ticket == ticket {
                        lane.busy = false
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
