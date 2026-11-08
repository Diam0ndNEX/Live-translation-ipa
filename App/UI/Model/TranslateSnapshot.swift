// ScreenLingo – App – UI model: what the Translate screen shows (2.1.0, spec §13.5.1)
// Read from the engine through EngineSlice (narrow observation); fixtures build the same struct by hand.
import SwiftUI

struct RecentLine: Equatable, Identifiable {
    let id: UUID
    let translated: String
    let original: String
    let date: Date
}

struct TranslateSnapshot: Equatable {
    var phase: SessionPhase
    var sourceCode: String
    var targetCode: String
    var sourceName: String
    var targetName: String
    var detected: String
    var packState: PackState
    var translated: String
    var original: String
    var stage: CaptionStage
    var held: Bool
    var paused: Bool
    var pipActive: Bool
    var sessionStarted: Date?
    var modeName: String
    var recentPairs: [String]
    var recent: [RecentLine]
    var prep = PrepFacts()
    /// True while the compose bar has paused capture (U2).
    var manual = false

    var hasOutput: Bool { !translated.isEmpty }
    var canSwap: Bool { sourceCode != "auto" }

    /// The pack line under the language pair (§13.4.3), in plain words.
    var packLine: (text: String, symbol: String, tone: PhaseTone) {
        switch packState {
        case .ready: return ("Works offline", "checkmark.circle.fill", .neutral)
        case .checking: return ("Checking language packs", "arrow.triangle.2.circlepath", .neutral)
        case .autoDetect:
            return (detected == "–" ? "Detects the language as it reads" : "Detected \(detected.uppercased())", "sparkle.magnifyingglass", .neutral)
        case .needsDownload: return ("\(sourceName) pack needs download", "arrow.down.circle", .caution)
        case .unsupported: return ("This pair isn't supported on this device", "xmark.octagon", .failure)
        }
    }

    @MainActor static func read(_ e: TranslatorEngine) -> TranslateSnapshot {
        let pair = PairSnapshot.read(e)
        let phase = SessionPhase.derive(capture: e.captureStatus, alive: e.captureAlive, paused: e.paused,
                                        pipActive: e.pipActive, packReady: pair.packState != .needsDownload && pair.packState != .unsupported,
                                        manual: e.manualMode)
        let stage: CaptionStage = e.isTranslating ? .translating : (e.waitingToDisplay || e.translated.isEmpty ? .reading : .showing)
        let recent = e.history.prefix(5).map {
            RecentLine(id: $0.id, translated: $0.translated, original: $0.original, date: $0.date)
        }
        return TranslateSnapshot(
            phase: phase, sourceCode: pair.source, targetCode: pair.target,
            sourceName: LanguageNames.name(pair.source, in: pair.languages),
            targetName: LanguageNames.name(pair.target, in: pair.languages),
            detected: pair.detected, packState: pair.packState,
            translated: e.translated, original: e.original, stage: stage, held: e.frozen, paused: e.paused,
            pipActive: e.pipActive, sessionStarted: e.sessionStarted,
            modeName: e.activeTranslationSystem.shortName, recentPairs: pair.recent, recent: Array(recent),
            prep: PrepFacts.read(e), manual: e.manualMode)
    }
}

/// What the engine is preparing (languages, sessions, first model run, warm-up), as plain values.
struct PrepFacts: Equatable {
    var title = ""
    var detail = ""
    var phase = TranslationActivity.Phase.waiting
    var since: Date? = nil
    var warmup = ""
    var languages = TranslationReadiness.Step.pending
    var sessions = TranslationReadiness.Step.pending
    var execution = TranslationReadiness.Step.pending
    var conditions = ""

    @MainActor static func read(_ e: TranslatorEngine) -> PrepFacts {
        let activity = e.translationActivity
        let ready = e.displayedReadiness
        return PrepFacts(
            title: activity.title, detail: activity.detail, phase: activity.phase, since: activity.since,
            warmup: e.activeTranslationSystem == .legacy ? "" : e.initialWarmupProgress,
            languages: ready.languages, sessions: ready.sessions, execution: ready.execution,
            conditions: e.currentRuntimeConditions.isEmpty ? e.translationConditions : e.currentRuntimeConditions)
    }
}

enum LanguageNames {
    static func name(_ code: String, in items: [LangItem]) -> String {
        if code == "auto" { return "Auto-detect" }
        if let item = items.first(where: { $0.code == code }) { return item.name }
        return Locale.current.localizedString(forIdentifier: code) ?? code.uppercased()
    }
    /// "pt>en" → "PT → EN"
    static func pairLabel(_ pair: String) -> String {
        pair.replacingOccurrences(of: ">", with: " → ").uppercased()
    }
}

extension TranslationSystem {
    /// The mode name alone (R7): the build identifier lives on the About page.
    var shortName: String {
        switch self {
        case .legacy: return "Legacy"
        case .hybridRecovery: return "Hybrid"
        case .lowLatency: return "Low Latency"
        }
    }
}
