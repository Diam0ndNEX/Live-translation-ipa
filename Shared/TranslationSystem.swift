import Foundation

/// 2.5.0: two translation systems. Hybrid Recovery was removed (it was either as fast as Low Latency or as slow as
/// Legacy and never combined them; see docs/v2.5.0-specification.md).
enum TranslationSystem: String, CaseIterable, Codable {
    case legacy, lowLatency
    static let referenceSHA = "e94542ce46cdb5b2426fdfd5dc258c932327762b"
    static let referenceVersion = "1.7.2 (58)"
    /// The raw value of the removed mode. Saved settings, saved presets and reports from 2.4.0 and earlier contain it.
    static let removedHybridRawValue = "hybridRecovery"
    /// Set once when a saved Hybrid choice was moved to Low Latency, cleared when the notice was shown.
    static let hybridNoticePendingKey = "hybridRemovalNoticePending"
    static let hybridNoticeShownKey = "hybridRemovalNoticeShown"
    static let migratedHybridReason = "migrated_hybrid_low_latency"
    static let migrationReasons = ["explicit_low_latency", "legacy_or_ambiguous", "persisted", migratedHybridReason]

    /// An unknown name (for example a removed mode in an old saved record) reads as Low Latency instead of failing.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .lowLatency
    }

    var title: String {
        switch self {
        case .legacy: return "Legacy (1.7.2)"
        case .lowLatency: return "Low Latency"
        }
    }
    var explanation: String {
        switch self {
        case .legacy: return "Uses the established 1.7.2 pipeline and Apple default strategy."
        case .lowLatency: return "Uses low latency for both early and confirmed text. Wording may differ from Legacy. Requires iOS 26.4 and the Low Latency language pack for the pair."
        }
    }
    static func migrate(_ defaults: UserDefaults) -> (TranslationSystem, String) {
        if let value = defaults.string(forKey: "translationSystem") {
            if value == removedHybridRawValue {
                // 2.5.0: a saved Hybrid choice (setting, backup or preset) moves to Low Latency once, with a notice.
                defaults.set(TranslationSystem.lowLatency.rawValue, forKey: "translationSystem")
                defaults.set(migratedHybridReason, forKey: "translationSystemMigration")
                if defaults.object(forKey: hybridNoticeShownKey) as? Bool != true {
                    defaults.set(true, forKey: hybridNoticePendingKey)
                }
                return (.lowLatency, migratedHybridReason)
            }
            guard let mode = Self(rawValue: value) else { return (.legacy, "unknown_value_legacy") }
            let saved = defaults.string(forKey: "translationSystemMigration") ?? "persisted"
            return (mode, migrationReasons.contains(saved) ? saved : "persisted")
        }
        let mode: Self
        let reason: String
        // The old opt-in switch had a false default. The old hybridTranslation switch is ignored since 2.5.0.
        if defaults.object(forKey: "lowLatencyTranslation") as? Bool == true {
            mode = .lowLatency; reason = "explicit_low_latency"
        } else { mode = .legacy; reason = "legacy_or_ambiguous" }
        defaults.set(mode.rawValue, forKey: "translationSystem")
        defaults.set(reason, forKey: "translationSystemMigration")
        return (mode, reason)
    }
}

enum RequestedTranslationStrategy: String, Codable {
    case appleDefault, lowLatency
}

/// Device language availability for each requested translation strategy.
/// "Supported" is not installed; an unavailable strategy must never invalidate another.
enum LanguageAssetState: String, Equatable {
    case installed, supported, unsupported, unchecked
}

struct TranslationLanguageCoverage: Equatable {
    let appleDefault: LanguageAssetState
    let lowLatency: LanguageAssetState

    func overall(for system: TranslationSystem) -> LanguageAssetState {
        switch system {
        case .legacy: return appleDefault
        case .lowLatency: return lowLatency
        }
    }

    func nextDownload(for system: TranslationSystem) -> RequestedTranslationStrategy? {
        switch system {
        case .legacy:
            return appleDefault == .supported ? .appleDefault : nil
        case .lowLatency:
            return lowLatency == .supported ? .lowLatency : nil
        }
    }

    func explanation(for system: TranslationSystem) -> String {
        switch system {
        case .legacy:
            switch appleDefault {
            case .installed: return "Apple Default installed for this language pair"
            case .supported: return "Apple Default supports this pair; download required"
            case .unsupported: return "Apple Default does not support this language pair"
            case .unchecked: return "Apple Default availability has not been checked"
            }
        case .lowLatency:
            switch lowLatency {
            case .installed: return "Low Latency language pack installed"
            case .supported: return "Low Latency pack available but not installed"
            case .unsupported: return "Low Latency does not support this language pair"
            case .unchecked: return "Low Latency availability has not been checked"
            }
        }
    }
}

/// 2.5.0: what Start does when Low Latency is selected. Low Latency never falls back to another model by itself:
/// without its language pack the person is asked (Download, Use Legacy, Cancel).
enum LowLatencyPackGate {
    enum Decision: Equatable { case start, askForPack(canDownload: Bool) }
    static func decision(system: TranslationSystem, sourceKnown: Bool, lowLatency: LanguageAssetState) -> Decision {
        guard system == .lowLatency, sourceKnown else { return .start }
        switch lowLatency {
        case .installed, .unchecked: return .start
        case .supported: return .askForPack(canDownload: true)
        case .unsupported: return .askForPack(canDownload: false)
        }
    }
    static let title = "Low Latency needs a language pack"
    static func message(source: String, target: String, canDownload: Bool) -> String {
        let pair = "\(source) to \(target)"
        return canDownload ?
            "The Low Latency pack for \(pair) is not installed. Download it, or use Legacy for this pair." :
            "Low Latency does not support \(pair) on this device. Use Legacy for this pair."
    }
}

enum ConfirmedSourceIdentity {
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

struct ModeCaption: Equatable {
    var system: TranslationSystem? = nil
    var thermal = 0
    let session: UUID
    let caption: String
    let revision: Int
    let source: String
    let target: String
    let rules: String
    let text: String
    let units: [String]
    let keys: [String]
    let firstOCR: Double
    var fingerprint: String { ConfirmedSourceIdentity.normalize(text) }
    var policyCohort: String {
        let tier = thermal <= 1 ? "full_performance" : (thermal == 2 ? "protected" : "emergency")
        return "\(source)>\(target)|tier\(tier)"
    }

    /// Temperature is observation metadata, not a candidate identity boundary.
    /// A nominal/fair transition must not invalidate an active translation.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.system == rhs.system && lhs.session == rhs.session &&
        lhs.caption == rhs.caption && lhs.revision == rhs.revision &&
        lhs.source == rhs.source && lhs.target == rhs.target &&
        lhs.rules == rhs.rules && lhs.text == rhs.text &&
        lhs.units == rhs.units && lhs.keys == rhs.keys &&
        lhs.firstOCR == rhs.firstOCR
    }
    func matches(_ other: Self) -> Bool {
        // Fast exact path for repeated OCR packets. Preserve the strict
        // session/revision/context/unit-key contract before any normalization.
        guard system == other.system, session == other.session, caption == other.caption,
              revision == other.revision, source == other.source, target == other.target,
              rules == other.rules, keys == other.keys else { return false }
        guard text == other.text || fingerprint == other.fingerprint else { return false }
        if units == other.units { return true }
        guard units.count == other.units.count else { return false }
        // The uncommon whitespace/Unicode-equivalent case compares units
        // individually, without building two temporary normalized arrays.
        return zip(units, other.units).allSatisfy { pair in
            pair.0 == pair.1 ||
                ConfirmedSourceIdentity.normalize(pair.0) == ConfirmedSourceIdentity.normalize(pair.1)
        }
    }
}

struct ModeOutput {
    let values: [String]
    let strategies: [RequestedTranslationStrategy?]
    let origins: [String]
    var complete: Bool { !values.isEmpty && values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}


/// Reject delayed UDP packets from a stopped/replaced broadcast, including a
/// quick restart before heartbeat expiry. Retention is bounded to 64 broadcasts.
struct CaptureSessionIdentityGate {
    enum Admission { case current, newSession, rejected }
    private(set) var current: String?
    private var retired: [String] = []
    mutating func admit(_ id: String?) -> Admission {
        guard let id else { return current == nil ? .current : .rejected }
        guard !retired.contains(id) else { return .rejected }
        if id == current { return .current }
        if let current { retire(current) }
        current = id
        return .newSession
    }
    mutating func stop(_ id: String?) -> Bool {
        guard id == current else { return false }
        if let current { retire(current) }
        current = nil
        return true
    }
    private mutating func retire(_ id: String) {
        if !retired.contains(id) { retired.append(id) }
        if retired.count > 64 { retired.removeFirst(retired.count - 64) }
    }
}

enum CaptionClockOrigin {
    static func monotonic(firstSeen: Double?, wallFirstSeen: Double, wallNow: Double, uptimeNow: Double) -> Double {
        if let firstSeen, firstSeen.isFinite, firstSeen >= 0, firstSeen <= uptimeNow { return firstSeen }
        return max(0, uptimeNow - max(0, wallNow - wallFirstSeen))
    }
}
