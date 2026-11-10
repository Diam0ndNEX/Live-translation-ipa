import Foundation

enum TranslationSystem: String, CaseIterable, Codable {
    case legacy, hybridRecovery, lowLatency
    static let referenceSHA = "e94542ce46cdb5b2426fdfd5dc258c932327762b"
    static let referenceVersion = "1.7.2 (58)"
    var title: String {
        switch self {
        case .legacy: return "Legacy (1.7.2)"
        case .hybridRecovery: return "Hybrid Recovery"
        case .lowLatency: return "Low Latency"
        }
    }
    var explanation: String {
        switch self {
        case .legacy: return "Uses the established 1.7.2 pipeline and Apple default strategy."
        case .hybridRecovery: return "Uses Apple Default ahead and Low Latency for confirmed recovery. Automatically reduces speculative work when it causes repeated waste or slow overlapping requests. Device acceptance pending."
        case .lowLatency: return "Uses low latency for both early and confirmed text. Wording may differ from Legacy. Requires iOS 26.4 and installed supported languages."
        }
    }
    static func migrate(_ defaults: UserDefaults) -> (TranslationSystem, String) {
        if let value = defaults.string(forKey: "translationSystem") {
            guard let mode = Self(rawValue: value) else { return (.legacy, "unknown_value_legacy") }
            let saved = defaults.string(forKey: "translationSystemMigration") ?? "persisted"
            let reasons = ["explicit_hybrid", "explicit_low_latency", "legacy_or_ambiguous", "persisted"]
            return (mode, reasons.contains(saved) ? saved : "persisted")
        }
        let mode: Self
        let reason: String
        // These old switches were opt-in, with false defaults. Hybrid took precedence.
        if defaults.object(forKey: "hybridTranslation") as? Bool == true {
            mode = .hybridRecovery; reason = "explicit_hybrid"
        } else if defaults.object(forKey: "lowLatencyTranslation") as? Bool == true {
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
        case .hybridRecovery:
            if appleDefault == .installed || lowLatency == .installed { return .installed }
            if appleDefault == .supported || lowLatency == .supported { return .supported }
            if appleDefault == .unchecked || lowLatency == .unchecked { return .unchecked }
            return .unsupported
        }
    }

    func nextDownload(for system: TranslationSystem) -> RequestedTranslationStrategy? {
        switch system {
        case .legacy:
            return appleDefault == .supported ? .appleDefault : nil
        case .lowLatency:
            return lowLatency == .supported ? .lowLatency : nil
        case .hybridRecovery:
            // Prefer completing fast recovery if default is already usable.
            if lowLatency == .supported { return .lowLatency }
            if appleDefault == .supported { return .appleDefault }
            return nil
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
        case .hybridRecovery:
            if appleDefault == .installed && lowLatency == .installed {
                return "Apple Default and Low Latency installed"
            }
            if appleDefault == .installed {
                return lowLatency == .supported ?
                    "Apple Default ready; install Low Latency for faster recovery" :
                    "Apple Default ready; Low Latency recovery unavailable for this pair"
            }
            if lowLatency == .installed {
                return appleDefault == .supported ?
                    "Low Latency ready; Apple Default requires download" :
                    "Low Latency ready; Apple Default unavailable for this pair"
            }
            if overall(for: system) == .unsupported { return "Neither strategy supports this language pair" }
            if overall(for: system) == .supported { return "No installed strategy for this pair; download required" }
            return "Checking Apple Default and Low Latency language availability"
        }
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

/// Per-language-pair and thermal-cohort timing guides the matching speculation
/// hedge. Unknown performance has a bounded cold-start fallback; completed
/// samples choose the likely Default finish and recovery crossover.
enum SpeculationWaitPolicy {
    static func remaining(elapsed: Double, ordinary: [Double], recovery: [Double], coldCeiling: Double) -> Double {
        let age = max(0, elapsed)
        let ceiling = max(0, min(coldCeiling, 0.70))
        guard age < ceiling else { return 0 }
        let ageBudget = ceiling - age
        let sortedDefault = ordinary.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard sortedDefault.count >= 5 else { return min(ageBudget, max(0, 0.45 - age)) }
        let expectedDefault = sortedDefault[min(sortedDefault.count - 1, Int(Double(sortedDefault.count - 1) * 0.75))]
        let remainingDefault = max(0, expectedDefault - age)
        guard remainingDefault > 0 else { return 0 }
        let validRecovery = recovery.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard validRecovery.count >= 5 else { return min(ageBudget, remainingDefault) }
        let recoveryMedian = validRecovery[validRecovery.count / 2]
        // Fast recovery can start sooner; a slow contended recovery should
        // not preempt an Apple Default request already nearing completion.
        let hedgeBudget = max(0.10, min(0.65, recoveryMedian * 0.75))
        return max(0, min(ageBudget, remainingDefault, hedgeBudget))
    }
}
