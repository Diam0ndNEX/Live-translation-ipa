import Foundation

/// Bounded, in-memory cache for unchanged sentence segmentation. This holds only
/// temporary derived ranges; persistent translation memory remains independent.
struct SegmentationCache {
    private struct Entry {
        let units: [String]
        let lastUsed: UInt64
    }
    private var values: [String: Entry] = [:]
    private var clock: UInt64 = 0
    let capacity: Int

    init(capacity: Int = 512) {
        self.capacity = max(1, min(capacity, 2048))
    }

    var count: Int { values.count }

    mutating func lookup(_ key: String) -> [String]? {
        guard let hit = values[key] else { return nil }
        clock &+= 1
        values[key] = Entry(units: hit.units, lastUsed: clock)
        return hit.units
    }

    mutating func insert(_ key: String, units: [String]) {
        guard !units.isEmpty else { return }
        clock &+= 1
        values[key] = Entry(units: units, lastUsed: clock)
        if values.count > capacity, let oldest = values.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            values[oldest] = nil
        }
    }

    mutating func clear() { values.removeAll(keepingCapacity: false); clock = 0 }
}
