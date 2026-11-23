import Foundation

/// 2.6.2: compares each session in a report with the one before it (oldest first) and says what got worse.
/// Only sessions that the existing comparison rules call comparable are judged (same device, OS, boundary and
/// behaviour switches). Fixed limits, stated in the report; they were not tuned on device data.
enum RunRegression {
    static let latencyLimitPercent = 10.0
    static let latencyLimitMilliseconds = 20.0
    static let minimumSamples = 20
    static let flaggedRateLimit = 0.02 // flagged captions per enqueued caption
    static let judged = ["enqueueLatencyMs", "ocrMs", "confirmationMs", "confirmedModelMs", "speculativeModelMs"]

    struct Flag: Equatable {
        let code: String
        let detail: String
    }

    struct Result {
        let comparable: Bool
        let reason: String
        let flags: [Flag]
        let improvements: [String]
    }

    static func compare(before: DiagnosticSessionExport, after: DiagnosticSessionExport) -> Result {
        let comparison = DiagnosticPerformanceComparison(baseline: before, current: after)
        guard comparison.comparable else {
            return Result(comparable: false, reason: comparison.reason, flags: [], improvements: [])
        }
        var flags: [Flag] = []
        var improvements: [String] = []
        for name in judged {
            guard let b = before.distributions[name], let a = after.distributions[name],
                  b.count >= minimumSamples, a.count >= minimumSamples,
                  let bp = b.p95, let ap = a.p95, bp > 0 else { continue }
            let percent = 100 * (ap - bp) / bp
            if percent >= latencyLimitPercent && ap - bp >= latencyLimitMilliseconds {
                flags.append(Flag(code: "slower_" + name, detail: "\(name) P95 \(Int(bp.rounded())) ms -> \(Int(ap.rounded())) ms (+\(Int(percent.rounded()))%)"))
            } else if percent <= -latencyLimitPercent && bp - ap >= latencyLimitMilliseconds {
                improvements.append("\(name) P95 \(Int(bp.rounded())) ms -> \(Int(ap.rounded())) ms (\(Int(percent.rounded()))%)")
            }
        }
        let beforeStalls = before.counters["stallHangs", default: 0] + before.counters["stallLaneResets", default: 0]
        let afterStalls = after.counters["stallHangs", default: 0] + after.counters["stallLaneResets", default: 0]
        if afterStalls > beforeStalls {
            flags.append(Flag(code: "more_stalls", detail: "stalls and lane resets \(beforeStalls) -> \(afterStalls)"))
        }
        if after.counters["guardTrips", default: 0] > before.counters["guardTrips", default: 0] {
            flags.append(Flag(code: "guard_tripped", detail: "a guard turned a switch off during the later session"))
        }
        let beforeRate = flaggedRate(before), afterRate = flaggedRate(after)
        if let beforeRate, let afterRate, afterRate - beforeRate >= flaggedRateLimit {
            flags.append(Flag(code: "more_flagged_captions", detail: "flagged captions per caption \(percentText(beforeRate)) -> \(percentText(afterRate))"))
        }
        return Result(comparable: true, reason: comparison.reason, flags: flags, improvements: improvements)
    }

    static func flaggedRate(_ session: DiagnosticSessionExport) -> Double? {
        let captions = session.distributions["enqueueLatencyMs"]?.count ?? 0
        guard captions >= minimumSamples else { return nil }
        return Double(session.counters["qFlaggedSaved", default: 0]) / Double(captions)
    }

    static func percentText(_ rate: Double) -> String { String(format: "%.1f%%", rate * 100) }

    /// Report lines for the verdict section. `labels[i]` belongs to `sessions[i]`; sessions are oldest first.
    static func lines(sessions: [DiagnosticSessionExport], labels: [String]) -> [String] {
        guard sessions.count >= 2 else { return [] }
        var out = ["", "**Compared with the session before it** (same device, OS and switches only; limits: P95 +\(Int(latencyLimitPercent))% and +\(Int(latencyLimitMilliseconds)) ms, \(minimumSamples) samples):"]
        for i in 1..<sessions.count {
            let result = compare(before: sessions[i - 1], after: sessions[i])
            if !result.comparable {
                out.append("- \(labels[i]) vs \(labels[i - 1]): not compared (\(result.reason))")
                continue
            }
            if result.flags.isEmpty && result.improvements.isEmpty {
                out.append("- \(labels[i]) vs \(labels[i - 1]): no change beyond the limits")
            }
            for flag in result.flags { out.append("- \(labels[i]) vs \(labels[i - 1]): WORSE [\(flag.code)] \(flag.detail)") }
            for note in result.improvements { out.append("- \(labels[i]) vs \(labels[i - 1]): better, \(note)") }
        }
        return out
    }
}
