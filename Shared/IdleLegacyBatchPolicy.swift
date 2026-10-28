import Foundation

/// Pure policy for optional foreground-only legacy memory work.
/// A batch contains many translation requests, but at most two concurrent model
/// sessions. Concurrency is NOT equal to the number of remembered sentences.
struct IdleLegacyWorkItem: Sendable {
    let id: Int64
    let source: String
    let text: String
}
struct IdleLegacyWorkChunk: Sendable {
    let source: String
    let items: [IdleLegacyWorkItem]
}
enum IdleLegacyBatchPolicy {
    static let automaticEntries = 24
    static let manualEntries = 48
    static let maximumEntries = 50
    static let perModelBatch = 12

    static func concurrency(thermalFair: Bool) -> Int { thermalFair ? 1 : 2 }
    static func cooldownSeconds(thermalFair: Bool) -> Double { thermalFair ? 20 : 8 }

    /// Stable source-grouping; no cross-language batch can be submitted to a model.
    static func chunks(_ items: [IdleLegacyWorkItem], limit: Int = maximumEntries) -> [IdleLegacyWorkChunk] {
        let bounded = Array(items.prefix(max(1, min(maximumEntries, limit))))
        var order: [String] = []
        var bySource: [String: [IdleLegacyWorkItem]] = [:]
        for item in bounded where !item.text.isEmpty {
            if bySource[item.source] == nil { order.append(item.source) }
            bySource[item.source, default: []].append(item)
        }
        var result: [IdleLegacyWorkChunk] = []
        for source in order {
            let group = bySource[source] ?? []
            for start in stride(from: 0, to: group.count, by: perModelBatch) {
                result.append(IdleLegacyWorkChunk(source: source,
                    items: Array(group[start..<min(group.count, start + perModelBatch)])))
            }
        }
        return result
    }
}
