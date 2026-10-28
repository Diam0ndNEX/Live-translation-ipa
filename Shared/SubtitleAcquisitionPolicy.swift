import Foundation

/// Tracks primary empty reads while letting a successful contrast fallback
/// terminate the streak before clear/backoff decisions are made.
struct OCREmptyReadStreak {
    private(set) var count = 0
    mutating func reset() { count = 0 }
    mutating func primaryEmpty() { count += 1 }
    mutating func finish(foundText: Bool) { if foundText { count = 0 } }
    var needsContrastRetry: Bool { count > 0 && count.isMultiple(of: 3) }
    var mayClear: Bool { count >= 4 }
}

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

    /// OCR sometimes changes punctuation or one harmless character while the
    /// same confirmed caption is still waiting for its model result. Do not
    /// cancel that work only to have the duplicate enqueue guard reject the
    /// replacement. Compare *every* row so scrolling lyrics still update.
    static func isSameUnpresentedCaption(activeConfirmed: Bool,
                                         activePresented: Bool,
                                         previousBlocks: [String],
                                         incomingBlocks: [String]) -> Bool {
        activeConfirmed && !activePresented && !previousBlocks.isEmpty &&
            PipelineSafety.isDuplicate(incomingBlocks, previous: previousBlocks)
    }

    /// A tentative next subtitle must not erase a confirmed one that is still
    /// translating. Once the new subtitle is confirmed, ordinary freshness
    /// guards may supersede the older output.
    static func shouldSupersedeActive(activeConfirmed: Bool, activePresented: Bool,
                                      incomingConfirmed: Bool) -> Bool {
        // Once the earlier subtitle was enqueued, start processing the next
        // early sighting immediately; only ongoing confirmed work is protected.
        incomingConfirmed || !activeConfirmed || activePresented
    }
}


/// Session-only OCR group summary; never written to diagnostics or SQLite.
struct MovieTextGroup {
    let text: String
    let x: Double
    let y: Double
    let weight: Double
}

/// A persistent label should not dominate newer subtitle text indefinitely.
/// A single caption/lyric group is never removed, even if it remains unchanged.
struct MovieTextFocus {
    private struct Observation {
        var text: String
        var x: Double
        var y: Double
        var unchangedSince: TimeInterval
        var lastSeen: TimeInterval
        var repeats: Int
    }
    private var prior: [Observation] = []

    mutating func reset() { prior.removeAll() }

    mutating func preferredIndex(in groups: [MovieTextGroup], at now: TimeInterval) -> Int? {
        guard !groups.isEmpty else { return nil }
        let previous = prior.filter { now - $0.lastSeen >= 0 && now - $0.lastSeen < 5 }
        var updated: [Observation] = []
        var used = Set<Int>()
        var stable: [Bool] = []
        for group in groups.prefix(24) {
            let text = TextSim.norm(group.text)
            let matched = previous.indices
                .filter { !used.contains($0) && abs(previous[$0].x - group.x) <= 0.15 &&
                    abs(previous[$0].y - group.y) <= 0.09 }
                .min { a, b in
                    let da = abs(previous[a].x - group.x) + abs(previous[a].y - group.y)
                    let db = abs(previous[b].x - group.x) + abs(previous[b].y - group.y)
                    return da < db
                }
            if let matched { used.insert(matched) }
            let old = matched.map { previous[$0] }
            let unchanged = old.map { $0.text == text || TextSim.similar($0.text, text, 0.97) } ?? false
            let since = unchanged ? (old?.unchangedSince ?? now) : now
            let repeats = unchanged ? min(10000, (old?.repeats ?? 0) + 1) : 1
            updated.append(Observation(text: text, x: group.x, y: group.y,
                unchangedSince: since, lastSeen: now, repeats: repeats))
            stable.append(!text.isEmpty && repeats >= 3 && now - since >= 1.2)
        }
        prior = Array(updated.prefix(24))
        let count = min(groups.count, stable.count)
        guard let fallback = (0..<count).max(by: { groups[$0].weight < groups[$1].weight }) else { return nil }
        guard stable[fallback] else { return fallback }
        // Do not mistake tiny transient UI labels for legitimate dialogue.
        let minimumWeight = groups[fallback].weight * 0.16
        let alternatives = (0..<count).filter { !stable[$0] && groups[$0].weight >= minimumWeight &&
            TextSim.norm(groups[$0].text).count >= 3 }
        return alternatives.max(by: { groups[$0].weight < groups[$1].weight }) ?? fallback
    }
}
