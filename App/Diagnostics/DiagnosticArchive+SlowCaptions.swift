import Foundation

/// 2.6.3: the slowest captions of a session with their stage times, kept as plain counters (metadata only), so a
/// report can say which stage made the slow captions slow. Pure; compiled with the DiagnosticArchive test programs.
enum SlowCaptions {
    static let keep = 8
    /// Order of the stage values: total first, then the stages of LatencyBreakdown.
    static let fields = ["total", "ocr", "confirm", "delivery", "queue", "translation", "hold", "render"]
    static let labels = ["total", "OCR", "confirmation", "delivery", "queue", "translation", "display hold", "rendering"]
    /// A slow-caption cause is named when at least this many kept captions took this long and this share agree.
    static let causeMinimumCaptions = 5
    static let causeMinimumMs = 1_200.0
    static let causeShare = 0.6

    static var counterNames: Set<String> {
        Set((1...keep).flatMap { rank in fields.map { "slow\(rank)_\($0)" } })
    }

    /// Keeps the `keep` slowest rows (by total), slowest first.
    static func insert(_ list: inout [[Double]], _ row: [Double]) {
        guard row.count == fields.count, let total = row.first, total.isFinite, total > 0 else { return }
        if list.count >= keep, let last = list.last?.first, total <= last { return }
        let index = list.firstIndex { ($0.first ?? 0) < total } ?? list.count
        list.insert(row, at: index)
        if list.count > keep { list.removeLast(list.count - keep) }
    }

    static func counters(_ list: [[Double]]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (i, row) in list.prefix(keep).enumerated() {
            for (j, field) in fields.enumerated() where j < row.count {
                out["slow\(i + 1)_\(field)"] = Int(max(0, row[j]).rounded())
            }
        }
        return out
    }

    static func rows(_ counters: [String: Int]) -> [[Int]] {
        (1...keep).compactMap { rank -> [Int]? in
            guard let total = counters["slow\(rank)_total"], total > 0 else { return nil }
            return fields.map { counters["slow\(rank)_\($0)", default: 0] }.enumerated().map { $0.offset == 0 ? total : $0.element }
        }
    }

    /// The stage that took the longest in a row (index into `fields`, never the total).
    static func dominant(_ row: [Int]) -> Int {
        guard row.count == fields.count else { return 0 }
        var best = 1
        for i in 2..<row.count where row[i] > row[best] { best = i }
        return best
    }

    /// The stage that dominated most slow captions, when the evidence is clear enough.
    static func cause(_ counters: [String: Int]) -> (stage: String, captions: Int, total: Int)? {
        let slow = rows(counters).filter { Double($0[0]) >= causeMinimumMs }
        guard slow.count >= causeMinimumCaptions else { return nil }
        let groups = Dictionary(grouping: slow, by: dominant)
        guard let top = groups.max(by: { $0.value.count < $1.value.count }),
              Double(top.value.count) >= causeShare * Double(slow.count) else { return nil }
        return (labels[top.key], top.value.count, slow.count)
    }

    static func lines(sessions: [DiagnosticSessionExport], labels sessionLabels: [String]) -> [String] {
        let all = sessions.map { rows($0.counters) }
        guard all.contains(where: { !$0.isEmpty }) else { return [] }
        var out = ["", "Slowest captions (2.6.3; ms per stage; stages can overlap; the longest stage is marked *):", "",
                   "| | rank | " + labels.joined(separator: " | ") + " |",
                   "|---|---|" + String(repeating: "---|", count: labels.count)]
        for (i, list) in all.enumerated() {
            for (rank, row) in list.enumerated() {
                let top = dominant(row)
                let cells = row.enumerated().map { $0.offset == top ? "\($0.element)*" : "\($0.element)" }
                out.append("| \(sessionLabels[i]) | \(rank + 1) | " + cells.joined(separator: " | ") + " |")
            }
        }
        return out
    }
}
