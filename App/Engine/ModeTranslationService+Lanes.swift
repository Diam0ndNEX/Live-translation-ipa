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
    }
    static func pairKey(_ source: String, _ target: String) -> String {
        "\(Locale.Language(identifier: source).minimalIdentifier)>\(Locale.Language(identifier: target).minimalIdentifier)"
    }
}
