// ScreenLingo – App – Narrow observation (2.0.0 build 85)
import SwiftUI
import Translation

typealias EngineSlice<Value: Equatable> = ObjectSlice<TranslatorEngine, Value>

/// What the Live hero needs.
struct CaptureSnapshot: Equatable {
    var status: CaptureReadiness.State
    var alive: Bool
    var paused: Bool
    var frozen: Bool
    var waitingToDisplay: Bool
    var translating: Bool
    var pipActive: Bool
    var hasOutput: Bool
    var hasOriginal: Bool

    var headline: String {
        if !alive { return "Ready when you are" }
        if paused { return "Translation paused" }
        if frozen { return "Holding this translation" }
        if waitingToDisplay { return "Holding for readability" }
        return translating ? "Translating…" : "Reading your screen"
    }
    var severity: Severity {
        switch status {
        case .active: return .success
        case .waiting, .connected: return .warning
        case .lost, .timedOut: return .error
        case .idle, .stopped: return .info
        }
    }
    @MainActor static func read(_ e: TranslatorEngine) -> CaptureSnapshot {
        CaptureSnapshot(status: e.captureStatus, alive: e.captureAlive, paused: e.paused, frozen: e.frozen,
                        waitingToDisplay: e.waitingToDisplay, translating: e.isTranslating, pipActive: e.pipActive,
                        hasOutput: !e.translated.isEmpty, hasOriginal: !e.original.isEmpty)
    }
}

/// What the language pair bar and Languages tab need.
struct PairSnapshot: Equatable {
    var source: String
    var target: String
    var detected: String
    var locked: Bool
    var checking: Bool
    var summary: String
    var statuses: [String: LanguageAvailability.Status]
    var languages: [LangItem]
    var recent: [String]
    var downloadMessage: String

    var sourcePackCode: String { source == "auto" ? detected : source }
    var packReady: Bool { statuses[sourcePackCode] == .installed }
    @MainActor static func read(_ e: TranslatorEngine) -> PairSnapshot {
        PairSnapshot(source: e.sourceCode, target: e.targetCode, detected: e.detectedLang, locked: e.lockedLang != nil,
                     checking: e.languageStatusChecking, summary: e.languageSummary, statuses: e.langStatus,
                     languages: e.languages, recent: e.recentPairs, downloadMessage: e.downloadMessage)
    }
}

/// What the Status sheet shows.
struct SystemSnapshot: Equatable {
    var active: TranslationSystem
    var pending: TranslationSystem
    var status: String
    var lastRaw: String
    var changePending: Bool { active != pending }
    @MainActor static func read(_ e: TranslatorEngine) -> SystemSnapshot {
        SystemSnapshot(active: e.activeTranslationSystem, pending: e.pendingTranslationSystem, status: e.status, lastRaw: e.lastRaw)
    }
}

/// What the compact Test row on Live needs.
struct TestSnapshot: Equatable {
    var name: String
    var savedModes: Int
    var recording: Bool
    @MainActor static func read(_ d: Diagnostics) -> TestSnapshot {
        let id = d.currentTestID
        let modes = Set(d.testRuns.filter { $0.testID == id }.map(\.mode))
        return TestSnapshot(name: d.currentTestName, savedModes: modes.count, recording: d.activeRun != nil)
    }
}
