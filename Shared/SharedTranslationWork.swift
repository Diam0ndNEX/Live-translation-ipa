import Foundation

/// Shared, synchronous request preparation for Legacy and Hybrid Apple Default
/// speculation. This does not own an Apple session or serialize model lanes.
/// Identity is deliberately byte-for-byte compatible with existing v4 memory
/// keys so the SQLite and temporary memory formats need no migration.
enum SharedTranslationWork {
    @inline(__always)
    static func unitKey(source: String, target: String, text: String,
                        protectedWords: [String], rules: String) -> String {
        let context = protectedWords.map { "\($0.utf8.count):\($0)" }.joined()
        let version = protectedWords.isEmpty ? "v2" : "v3"
        if !rules.isEmpty { return "v4|\(rules)|\(source)>\(target)|\(context.utf8.count):\(context)|\(text)" }
        return "\(version)|\(source)>\(target)|\(context.utf8.count):\(context)|\(text)"
    }

    /// One model request per distinct unresolved exact-context unit, retaining
    /// original ordering. Duplicated lines still receive the corresponding
    /// response when the caller assembles its output.
    static func unresolvedIndices(keys: [String], values: [String?]) -> [Int]? {
        guard !keys.isEmpty, keys.count == values.count,
              !keys.contains(where: { $0.isEmpty }) else { return nil }
        var seen = Set<String>()
        return values.indices.filter { values[$0] == nil && seen.insert(keys[$0]).inserted }
    }

    /// This is only a volatile reuse gate. A cancelled request may finish on
    /// Apple's side; it never receives presentation authority from this helper.
    static func mayReuse(workEpoch: UUID, currentEpoch: UUID, requestedCancellation: Bool,
                         compatibleContext: Bool) -> Bool {
        workEpoch == currentEpoch && !requestedCancellation && compatibleContext
    }
}


/// A four-entry, synchronous, value-semantic preparation cache. The caller owns
/// the full identity: capture, layout, source, rules, rotation and work epoch.
/// No actor hop, disk access, asynchronous task or model session is introduced.
struct ExactPlanReuseCache<Key: Equatable, Value> {
    private(set) var entries: [(key: Key, value: Value)] = []
    private(set) var hits = 0
    private(set) var misses = 0
    let capacity: Int

    init(capacity: Int = 4) { self.capacity = max(1, min(16, capacity)) }

    mutating func lookup(_ key: Key) -> Value? {
        guard let position = entries.firstIndex(where: { $0.key == key }) else {
            misses += 1
            return nil
        }
        hits += 1
        let entry = entries.remove(at: position)
        entries.append(entry)
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Key) {
        entries.removeAll { $0.key == key }
        entries.append((key, value))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    mutating func clear() { entries.removeAll(keepingCapacity: true) }
    var count: Int { entries.count }
}

/// Common physical-request ownership contract for Legacy and Hybrid Apple
/// Default. Cancellation is advisory and never releases active ownership.
/// A completion may return a reusable session only for an unchanged epoch.
struct AppleDefaultLeaseState {
    private(set) var active: UUID?
    private(set) var epoch = UUID()
    private(set) var cancellationRequested = false
    private(set) var completed = 0

    mutating func begin() -> UUID? {
        guard active == nil else { return nil }
        let ticket = UUID()
        active = ticket
        cancellationRequested = false
        return ticket
    }

    mutating func requestCancellation() {
        if active != nil { cancellationRequested = true }
    }

    mutating func finish(_ ticket: UUID, successful: Bool) -> Bool {
        guard active == ticket else { return false }
        active = nil
        completed += 1
        return successful && !cancellationRequested
    }

    mutating func reset() {
        epoch = UUID()
        requestCancellation()
    }
}
