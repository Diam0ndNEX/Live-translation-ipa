import Foundation

/// These optimizations only change scheduling and repeated work, never source wording.
enum CaptureCadence {
    static func remaining(startedAt: TimeInterval, now: TimeInterval, interval: TimeInterval) -> TimeInterval {
        max(0, interval - max(0, now - startedAt))
    }
}

struct TranslationBatchPlan {
    let unique: [String]
    let uniqueContexts: [String]
    private let positions: [Int]
    init(_ sentences: [String], contexts: [String] = []) {
        var unique: [String] = [], identities: [String] = [], positions: [Int] = [], lookup: [String: Int] = [:]
        for (position, sentence) in sentences.enumerated() {
            let identity = contexts.count == sentences.count ? contexts[position] : sentence
            if let index = lookup[identity] { positions.append(index) }
            else {
                lookup[identity] = unique.count
                positions.append(unique.count)
                unique.append(sentence)
                identities.append(identity)
            }
        }
        self.unique = unique; self.uniqueContexts = identities; self.positions = positions
    }
    func expand(_ results: [String?]) -> [String?]? {
        guard results.count == unique.count else { return nil }
        return positions.map { results[$0] }
    }
}

enum FontSearch {
    /// Find the same largest fitting size as hi, hi-2, …, lo, with logarithmic measurements.
    static func size(high: Double, low: Double, step: Double = 2, fits: (Double) -> Bool) -> Double {
        guard high > low, step > 0 else { return low }
        let count = Int(ceil((high - low) / step))
        var lower = 0, upper = count
        while lower < upper {
            let middle = (lower + upper) / 2
            if fits(max(low, high - Double(middle) * step)) { upper = middle }
            else { lower = middle + 1 }
        }
        return max(low, high - Double(lower) * step)
    }
}

struct LatencyBreakdown: Equatable {
    var recognition = 0.0
    var confirmation = 0.0
    var delivery = 0.0
    var queue = 0.0
    var translation = 0.0
    var displayHold = 0.0
    var rendering = 0.0
    var total = 0.0
    var requestsSaved = 0
}
