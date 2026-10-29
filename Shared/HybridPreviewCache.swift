import Foundation

/// Preview-only process memory. This type cannot enter the durable writer or
/// the high-fidelity translation RAM bank. Normal and temporary owners are separate.
final class HybridPreviewCache {
    struct Entry {
        let text: String
        let speculativeID: UInt64?
    }
    private var values: [String: Entry] = [:]
    private var order: [String] = []
    let capacity: Int
    init(capacity: Int = 256) { self.capacity = max(1, min(3000, capacity)) }
    var count: Int { values.count }
    func lookup(_ key: String) -> Entry? {
        guard let value = values[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return value
    }
    func insert(_ key: String, text: String, speculativeID: UInt64?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        values[key] = Entry(text: text, speculativeID: speculativeID)
        order.removeAll { $0 == key }; order.append(key)
        if order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
    }
    func clear() { values.removeAll(); order.removeAll() }
}

enum HybridTranslationPolicy {
    static func mayRunPreview(enabled: Bool, manual: Bool, freshOnly: Bool,
                              lowPower: Bool, thermalNominal: Bool) -> Bool {
        enabled && !manual && !freshOnly && !lowPower && thermalNominal
    }
}
