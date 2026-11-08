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

    
/// Build-time A/B controls used for the v1.9.5 comparison matrix. Defaults are
/// the optimized implementations; define each reference flag separately with
/// SWIFT_ACTIVE_COMPILATION_CONDITIONS to isolate L0 and F0 without a setting,
/// model-strategy change, or an extra runtime branch in the selected path.
///
/// 2.2.1 (D13): the same two switches can also be set at run time (Advanced > Experimental features). The setting is
/// copied into a "pinned" value when a session starts, so a change applies from the next session and never mid-run.
/// The compile flags above still override both, for the CI reference builds. Defaults are the optimized paths.
///
/// 2.2.3 (L5): a third runtime switch, backgroundAvailabilityRefresh, is pinned the same way but defaults to OFF
/// (current behaviour). It is not a build-flag switch and does not change the `label`.
enum TranslationHotPathAB {
    static let planSettingKey = "hotPathReuseLowLatencyPlan"
    static let unitsSettingKey = "hotPathReuseLegacyUnits"
    static let planPinnedKey = "hotPathReuseLowLatencyPlanPinned"
    static let unitsPinnedKey = "hotPathReuseLegacyUnitsPinned"
    static let availabilityRefreshSettingKey = "backgroundAvailabilityRefresh"
    static let availabilityRefreshPinnedKey = "backgroundAvailabilityRefreshPinned"
    // 2.2.3 (L3, L4): Hybrid-only arms, default OFF = current behaviour.
    static let hybridBackoffSettingKey = "hybridRelaxedBackoff"
    static let hybridBackoffPinnedKey = "hybridRelaxedBackoffPinned"
    static let hybridGuardSettingKey = "hybridShorterGuard"
    static let hybridGuardPinnedKey = "hybridShorterGuardPinned"
    // 2.2.3 (L2): Legacy only, default OFF = current behaviour.
    static let legacyOwnLaneSettingKey = "legacyConfirmedOwnLane"
    static let legacyOwnLanePinnedKey = "legacyConfirmedOwnLanePinned"

    private static func pinned(_ key: String) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
    }

    /// Called when a session starts: the settings become the values the hot path reads.
    static func pinSettings(_ defaults: UserDefaults = .standard) {
        defaults.set((defaults.object(forKey: planSettingKey) as? Bool) ?? true, forKey: planPinnedKey)
        defaults.set((defaults.object(forKey: unitsSettingKey) as? Bool) ?? true, forKey: unitsPinnedKey)
        defaults.set((defaults.object(forKey: availabilityRefreshSettingKey) as? Bool) ?? false, forKey: availabilityRefreshPinnedKey)
        defaults.set((defaults.object(forKey: hybridBackoffSettingKey) as? Bool) ?? false, forKey: hybridBackoffPinnedKey)
        defaults.set((defaults.object(forKey: hybridGuardSettingKey) as? Bool) ?? false, forKey: hybridGuardPinnedKey)
        defaults.set((defaults.object(forKey: legacyOwnLaneSettingKey) as? Bool) ?? false, forKey: legacyOwnLanePinnedKey)
    }

    static var reuseStandaloneLowLatencyPlan: Bool {
        #if SCREENLINGO_REFERENCE_LL_PLAN
        return false
        #else
        return pinned(planPinnedKey)
        #endif
    }

    static var reuseLegacyPreparedUnits: Bool {
        #if SCREENLINGO_REFERENCE_LEGACY_UNITS
        return false
        #else
        return pinned(unitsPinnedKey)
        #endif
    }

    /// 2.2.3 (L3): Hybrid skips fewer early Apple Default requests after wasted ones. Default OFF.
    static var hybridRelaxedBackoff: Bool {
        (UserDefaults.standard.object(forKey: hybridBackoffPinnedKey) as? Bool) ?? false
    }
    /// 2.2.3 (L2): a Legacy confirmed caption starts without waiting for a cancelled, different-text speculative
    /// call to finish unwinding. iOS 26 direct sessions only. Default OFF.
    static var legacyConfirmedOwnLane: Bool {
        (UserDefaults.standard.object(forKey: legacyOwnLanePinnedKey) as? Bool) ?? false
    }
    /// 2.2.3 (L4): shorter Hybrid switch-guard window and post-Default settling wait. Default OFF.
    static var hybridShorterGuard: Bool {
        (UserDefaults.standard.object(forKey: hybridGuardPinnedKey) as? Bool) ?? false
    }

    /// 2.2.3 (L5): refresh a cached language-availability check in the background. Default OFF.
    static var refreshAvailabilityInBackground: Bool {
        (UserDefaults.standard.object(forKey: availabilityRefreshPinnedKey) as? Bool) ?? false
    }

    static var label: String {
        let legacy = reuseLegacyPreparedUnits ? "L1" : "L0"
        let fast = reuseStandaloneLowLatencyPlan ? "F1" : "F0"
        return legacy + "_" + fast
    }
}
