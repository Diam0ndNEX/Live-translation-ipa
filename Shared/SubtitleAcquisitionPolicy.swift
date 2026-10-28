import Foundation

/// Conservative, testable screen-change and live-caption scheduling policy.
/// A missed subtitle is more costly than an occasional extra OCR pass.
enum SubtitleAcquisitionPolicy {
    /// A global mean alone can overlook a short text change in a largely static frame.
    /// Sparse high-contrast sample changes are a second signal, never a reason to skip OCR.
    static func changed(previous: [UInt8], current: [UInt8]) -> Bool {
        guard !current.isEmpty, previous.count == current.count else { return true }
        var total = 0
        var strongChanges = 0
        for index in current.indices {
            let delta = abs(Int(current[index]) - Int(previous[index]))
            total += delta
            if delta >= 16 { strongChanges += 1 }
        }
        return Double(total) / Double(current.count) > 1.5 || strongChanges >= 2
    }

    /// Never allow the unchanged-image optimization to defer recognition for seconds
    /// while new dialogue could have appeared in only a small part of the image.
    static func maximumUnchangedDelay(movie: Bool) -> TimeInterval {
        movie ? 0.55 : 1.5
    }

    /// A new subtitle should wake Movie OCR promptly after quiet scenes.
    static func idleMultiplier(movie: Bool, enabled: Bool, secondsSinceText: TimeInterval) -> Double {
        guard enabled, secondsSinceText > 8 else { return 1.0 }
        return movie ? 1.15 : 2.5
    }

    /// A tentative next subtitle must not erase a confirmed one that is still
    /// translating. Once the new subtitle is confirmed, ordinary freshness
    /// guards may supersede the older output.
    static func shouldSupersedeActive(activeConfirmed: Bool, incomingConfirmed: Bool) -> Bool {
        incomingConfirmed || !activeConfirmed
    }
}
