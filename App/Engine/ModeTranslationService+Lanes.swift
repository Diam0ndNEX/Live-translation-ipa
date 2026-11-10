import Foundation
import Translation

extension ModeTranslationService {
    final class Lane {
        var session: TranslationSession?
        var key = ""
        var busy = false
        var ticket = UUID()
        var invalidated = false
        var caption: ModeCaption?
        var cancellationAt: Double?
        var activityID: UUID?
        var requestedStrategy: RequestedTranslationStrategy?
        var createdAt: Double?
        var lastFinishedAt: Double?
        var lastFinishedPair = ""
        var completedCalls = 0
        var sharedDefaultLease = AppleDefaultLeaseState()
        /// v2.0.0 H3: the confirmed lane keeps one idle session for the other
        /// strategy of the same language pair, so Hybrid recoveries that
        /// alternate Default and Low Latency do not recreate sessions.
        var spareSession: TranslationSession?
        var spareKey = ""
        var spareCreatedAt: Double?
    }
    /// Logical lane occupancy, not a claim of physical model residency.
    var mayAdmitHybridSpeculation: Bool {
        !speculative.busy && !confirmed.busy && confirmedDemand == 0 && !warmupLane.busy && hostedTask == nil
    }
    /// Frozen v1.9.5 admission predicate for internal reference A/B tests.
    var mayAdmitReferenceHybridSpeculation: Bool {
        !speculative.busy && !confirmed.busy && !warmupLane.busy && hostedTask == nil
    }
    /// Includes availability/preflight suspension, not only actual Apple work.
    var hasConfirmedLowLatencyDemand: Bool {
        confirmedDemand > 0 || confirmed.busy
    }
    static func pairKey(_ source: String, _ target: String) -> String {
        "\(Locale.Language(identifier: source).minimalIdentifier)>\(Locale.Language(identifier: target).minimalIdentifier)"
    }
}
