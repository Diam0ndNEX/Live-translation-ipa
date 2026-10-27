import Foundation

enum PresentationSchedule {
    static func inferredPolicy(saved: String?, minimum: TimeInterval) -> String {
        if let saved, saved == "immediate" || saved == "readable" { return saved }
        return minimum > 0 ? "readable" : "immediate"
    }
    static func remaining(policy: String, minimum: TimeInterval, lastShown: TimeInterval, now: TimeInterval) -> TimeInterval {
        guard policy == "readable" else { return 0 }
        return max(0, min(4, minimum) - max(0, now - lastShown))
    }
    static func isCurrent(generation: Int, context: Int, currentGeneration: Int, currentContext: Int,
                          frozen: Bool, paused: Bool, manual: Bool) -> Bool {
        generation == currentGeneration && context == currentContext && !frozen && (!paused || manual)
    }
}

struct PipelineMeasurement: Identifiable {
    let id = UUID()
    let date: Date
    let stages: LatencyBreakdown
}
