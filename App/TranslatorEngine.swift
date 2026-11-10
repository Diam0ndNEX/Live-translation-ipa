// Screen Translator – App – v0.11.0
import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

enum TranslateMode: String, CaseIterable, Identifiable {
    case movie, game, comic
    var id: String { rawValue }
    var title: String {
        switch self { case .movie: "Movie / subtitles"; case .game: "Game / apps"; case .comic: "Comic / manga" }
    }
}
enum OCRArea: String, CaseIterable, Identifiable {
    case smart, full, bottom, top, middle, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: "Smart (auto)"; case .full: "Full screen"; case .bottom: "Bottom third"
        case .top: "Top half"; case .middle: "Middle band"; case .custom: "Custom…"
        }
    }
    func range() -> ClosedRange<Double> {   // y: 0 = bottom, 1 = top
        switch self {
        case .smart: return 0...1
        case .full: return 0...1
        case .bottom: return 0...0.33
        case .top: return 0.5...1
        case .middle: return 0.3...0.7
        case .custom:
            let a = (UserDefaults.standard.object(forKey: "customY0") as? Double) ?? 0
            let b = (UserDefaults.standard.object(forKey: "customY1") as? Double) ?? 0.5
            return ExportFormat.normalizedArea(a, b)
        }
    }
}
enum WindowSize: String, CaseIterable, Identifiable {
    case small, normal, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var size: CGSize {
        switch self {
        case .small: CGSize(width: 720, height: 200)
        case .normal: CGSize(width: 720, height: 360)
        case .large: CGSize(width: 720, height: 540)
        }
    }
}
enum SpeedPreset: String, CaseIterable, Identifiable {
    case fast, balanced, sharp, automatic
    var id: String { rawValue }
    var title: String {
        switch self { case .fast: "Fast"; case .balanced: "Balanced"; case .sharp: "Sharp (small text)"; case .automatic: "Auto (adaptive)" }
    }
    var maxEdge: Double {
        switch self { case .fast: 1000; case .balanced: 1400; case .sharp: 2000; case .automatic: 1400 }
    }
    var interval: Double {
        switch self { case .fast: 0.12; case .balanced: 0.22; case .sharp: 0.4; case .automatic: 0.22 }
    }
}

struct LangItem: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

struct HistoryItem: Identifiable, Codable {
    var id = UUID()
    let original: String
    let translated: String
    var date = Date()
    var starred = false
    var sourceLanguage: String? = nil
    var targetLanguage: String? = nil
    var note: String? = nil
}
extension HistoryItem: HistoryTrimmable {}

@MainActor
final class TranslatorEngine: ObservableObject {
    /// Everything a preset remembers.
    static let presetKeys = [
        "source", "target", "mode", "area", "customY0", "customY1", "speed", "stability", "minTextH", "ignoreList",
        "frameRot", "dropNoise", "boost", "skipUnchanged", "subtitleAwareChangeDetection", "preserveRelatedMovieGroups", "rapidTextTracking", "joinAdjacentText", "activeTextFocus", "cleanOCR", "slang", "speakerDetect", "highlightNames",
        "langLock", "neverTranslate", "sourceFixes", "glossary", "winSize", "theme", "textSize", "pipFont",
        "showOriginal", "autoClear", "clearHold", "minDisplay", "autoOpenPiP", "haptics", "speak", "speechRate",
        "autoCopy", "adaptive", "idleMinutes", "translateAhead", "keepWarm", "remember", "translationSystem", "lowLatencyTranslation", "incrementalBatchRecovery", "adaptiveSpeculation", "protectConfirmedPresentation", "predictiveWarmup",
        "displayPolicy", "pipWeight", "pipAlignment", "pipLineSpacing", "pipPadding", "originalFraction", "pipScale", "speakerAccent", "heartbeatInterval", "hapticStrength", "autoCopyFormat", "interruptSpeech", "ocrConfidence", "ocrCorrection", "idleBackoff", "coolMode", "adaptiveOCR", "adaptiveConfirmation", "subtitleTracking", "selectiveSpeculation", "speculationConfidence", "confirmationDeadline", "smartCool", "steadyCaptions", "languageRecovery", "deduplicateCopies", "continuousRotation", "contextualLanguage"
    ]
    /// App look & behaviour that presets do not touch.
    static let interfaceKeys = ["memoryRAMCapacity", "memorySoftLimit", "testRunSaving", "suppressOwnInterface", "directPiPBuffer", "hybridSwitchGuard", "pixelConfirmation", "eventDrivenOCR", "fastOCR", "legacySharedSession", "legacyIdleValidationEnabled", "accent", "keepAwake", "saveHistory", "historyRetentionDays", "uiHaptics", "homePresets", "homeTools", "homeQuick", "homeStatus", "homeRecent", "privateSession", "diagIncludeText", "readerFont", "readerSpacing", "readerWidth", "historyCapacity", "diagSamples", "diagnosticsEnabled", "detailedCollection", "freshTranslationTest", "temporaryMemoryTest", "showSessionSpeakers", "homeMetrics", "homeQuickExpanded", "homeDetailsExpanded", "photoOCREdge", "photoAutoTranslate", "sessionLimit", "readerSize", "readerOriginal", "readerAlignment", "appearance", "cjkSingleCharacters", "hybridSchedulerVariant", "hotPathReuseLowLatencyPlan", "hotPathReuseLegacyUnits", "liveWarmupLegacy"]
    static var settingKeys: [String] { presetKeys + interfaceKeys }
    static let defaults: [String: Any] = [
        "suppressOwnInterface": true, "memoryRAMCapacity": 3000, "memorySoftLimit": 100000, "testRunSaving": "automatic", "directPiPBuffer": false, "hybridSwitchGuard": true,
        "pixelConfirmation": true, "eventDrivenOCR": true, "fastOCR": false, "legacySharedSession": true, "liveWarmupLegacy": true,
        "source": "auto", "target": "en", "mode": "movie", "area": "smart", "customY0": 0.0, "customY1": 0.5,
        "speed": "balanced", "stability": 2, "minTextH": 0.0, "ignoreList": "", "frameRot": "auto",
        "dropNoise": true, "boost": 1, "skipUnchanged": true, "subtitleAwareChangeDetection": false, "preserveRelatedMovieGroups": false, "rapidTextTracking": true, "joinAdjacentText": true, "activeTextFocus": true, "cleanOCR": true, "slang": true,
        "speakerDetect": true, "highlightNames": true, "langLock": true, "neverTranslate": "", "sourceFixes": "",
        "glossary": "", "winSize": "normal", "theme": "dark", "textSize": "auto", "pipFont": "standard",
        "showOriginal": false, "autoClear": true, "clearHold": 1.0, "minDisplay": 0.0, "autoOpenPiP": true,
        "haptics": false, "speak": false, "speechRate": 0.5, "autoCopy": false, "adaptive": true, "idleMinutes": 0,
        "translateAhead": true, "keepWarm": true, "remember": true, "translationSystem": "legacy", "lowLatencyTranslation": false, "incrementalBatchRecovery": false,
        "adaptiveSpeculation": true, "protectConfirmedPresentation": true, "predictiveWarmup": true,
        "displayPolicy": "immediate", "pipWeight": "bold", "pipAlignment": "left", "pipLineSpacing": 0.0,
        "pipPadding": 24.0, "originalFraction": 0.27, "pipScale": 1.0, "speakerAccent": "blue", "heartbeatInterval": 1.0,
        "readerFont": "rounded", "readerSpacing": 8.0, "readerWidth": "full", "historyCapacity": 500,
        "diagSamples": 600, "appearance": "system", "cjkSingleCharacters": true, "hybridSchedulerVariant": "evidenceBounded", "hotPathReuseLowLatencyPlan": true, "hotPathReuseLegacyUnits": true, "homeMetrics": true, "homeQuickExpanded": false,
        "homeDetailsExpanded": false, "hapticStrength": "light", "autoCopyFormat": "translation", "interruptSpeech": true,
        "photoOCREdge": 2400, "photoAutoTranslate": false,
        "adaptiveOCR": true, "adaptiveConfirmation": false, "subtitleTracking": true, "selectiveSpeculation": true,
        "speculationConfidence": 0.85, "confirmationDeadline": 0.6, "smartCool": true, "steadyCaptions": true,
        "languageRecovery": true, "deduplicateCopies": true, "continuousRotation": false, "contextualLanguage": true,
        "coolMode": false, "diagnosticsEnabled": true, "detailedCollection": false, "freshTranslationTest": false, "temporaryMemoryTest": false, "showSessionSpeakers": true,
        "legacyIdleValidationEnabled": false, "privateSession": false, "diagIncludeText": false, "sessionLimit": 0, "readerSize": 28.0,
        "readerOriginal": true, "readerAlignment": false, "ocrConfidence": 0.3, "ocrCorrection": true, "idleBackoff": true
    ]

    // Settings that live in the engine
    @Published var sourceCode: String {
        didSet { guard oldValue != sourceCode else { return }; UserDefaults.standard.set(sourceCode, forKey: "source"); languageSelectionChanged(); directSession = nil; noteRecentPair() }
    }
    @Published var targetCode: String {
        didSet {
            guard oldValue != targetCode else { return }
            UserDefaults.standard.set(targetCode, forKey: "target"); languageSelectionChanged(); directSession = nil; langStatus = [:]; availCache.removeAll()
            noteRecentPair()
            Task { await refreshStatus(); await prewarm() }
        }
    }
    @Published var paused = false {
        didSet {
            invalidatePending(); syncConfig()
            // 2.2.1 (E2): after a resume the idle timer and the session timer start again. Without this the next
            // tick saw the old values and paused again about a second later.
            if oldValue && !paused { lastTextDate = Date(); limitBase = Date() }
            if !paused { enqueue(latestBlocks) }
        }
    }
    @Published var frozen = false
    @Published var manualMode = false
    @Published var sessionStarted: Date?
    @Published var sessionTranslations = 0
    @Published var sessionCharacters = 0
    @Published private(set) var downloadMessage = ""
    /// The language whose pack download was requested and has not finished (success or failure) yet (U4).
    @Published private(set) var downloadInFlight: String?
    /// The language of the last request, so a failed download can offer "Try again".
    private(set) var lastDownloadCode: String?
    @Published var isTranslating = false
    @Published var waitingToDisplay = false
    var presentationTask: Task<Void, Never>?
    var presentationID = UUID()
    var undoHistory: [HistoryItem]?
    @Published var toastText: String?
    @Published var detectedLang = "–"
    @Published var recentPairs: [String] = []
    @Published var memoryCount = 0
    // Languages
    @Published var languages: [LangItem] = TranslatorEngine.fallbackLanguages
    @Published var langStatus: [String: LanguageAvailability.Status] = [:]
    @Published var defaultLangStatus: [String: LanguageAssetState] = [:]
    @Published var lowLatencyLangStatus: [String: LanguageAssetState] = [:]
    @Published var languageStatusChecking = false
    var languageStatusTicket = UUID()

    static func languageState(_ status: LanguageAvailability.Status) -> LanguageAssetState {
        switch status {
        case .installed: return .installed
        case .supported: return .supported
        case .unsupported: return .unsupported
        @unknown default: return .unchecked
        }
    }

    static func platformStatus(_ status: LanguageAssetState) -> LanguageAvailability.Status? {
        switch status {
        case .installed: return .installed
        case .supported: return .supported
        case .unsupported: return .unsupported
        case .unchecked: return nil
        }
    }

    func languageCoverage(for code: String) -> TranslationLanguageCoverage {
        TranslationLanguageCoverage(appleDefault: defaultLangStatus[code] ?? .unchecked,
                                    lowLatency: lowLatencyLangStatus[code] ?? .unchecked)
    }

    var languageSummary: String {
        let code = sourceCode != "auto" ? sourceCode :
            (detectedLang != "–" ? detectedLang : (lockedLang ?? ""))
        guard !code.isEmpty else { return "Automatic source: select or detect a language to check its packs" }
        return languageCoverage(for: code).explanation(for: pendingTranslationSystem)
    }

    @Published var lockedLang: String? = nil { didSet { if diag.enabled { diag.s.lockedLang = lockedLang ?? "–" } } }
    // Output + diagnostics
    @Published var original = ""
    @Published var translated = ""
    @Published var status = "Idle"
    @Published var warmupStatus = "Waiting for source language"
    @Published var legacyIdleValidationStatus = "Disabled"
    @Published private(set) var legacyValidatedThisSession = 0
    @Published private(set) var legacyBatchTotal = 0
    @Published private(set) var legacyBatchCompleted = 0
    @Published private(set) var legacyBatchSkipped = 0
    @Published private(set) var legacyBatchWorkers = 0
    @Published private(set) var legacyBatchActive = false
    @Published private(set) var legacyBatchProcessed = 0
    @Published private(set) var legacyEntriesPerMinute = 0.0
    @Published private(set) var legacyEstimatedRemainingMinutes: Double?
    @Published private(set) var legacyValidationElapsedSeconds = 0.0
    @Published private(set) var warmupLastDurationMs: Double?
    @Published var captureAlive = false {
        // 2.2.2: leaving the app during a live session opens the floating window by itself (if the setting is on).
        didSet { if captureAlive != oldValue { pip.setAutomaticStart(captureAlive && flag("autoOpenPiP", true)) } }
    }
    @Published var captureStatus = CaptureReadiness.State.idle
    var captureReadiness = CaptureReadiness()
    @Published var frames = 0
    @Published var ocrCount = 0
    @Published var extensionVersion = "–"
    @Published var pipActive = false
    @Published var lastRaw = ""
    @Published var ocrMs: Double = 0
    @Published var translateMs: Double = 0
    @Published var extFreeMB: Double = 0
    @Published var history: [HistoryItem] = [] { didSet { historyWriter.schedule() } }
    /// 2.2.1 (E15): the whole Library used to be encoded and written on every caption, on the main thread.
    /// Changes are now written once after a second without changes; `flushHistorySave()` writes at once.
    private lazy var historyWriter: DebouncedAction = DebouncedAction(delay: .seconds(1)) { [weak self] in self?.saveHistory() }
    func flushHistorySave() { historyWriter.flush() }
    // Translation session plumbing
    @Published var legacyConfig: TranslationSession.Configuration?
    @Published var downloadConfig: TranslationSession.Configuration?

    let pip = PiPRenderer()
    let server = LoopbackServer()
    let diag = Diagnostics()
    let presets = PresetStore()
    let latency = LatencyMonitor()

    @Published var activeTranslationSystem = TranslationSystem.legacy
    @Published var pendingTranslationSystem = TranslationSystem.legacy
    @Published private(set) var modeAvailability = ""
    @Published private(set) var modeWorkActivity: TranslationActivity?
    private var modeActivityCaption: ModeCaption?
    private var modeActivitySelected = false
    private var preparationTicket = UUID()
    private var lastModePreparationPair = ""
    private var lastModePreparationAt = Date.distantPast

    @Published var modelReadiness = TranslationReadiness()
    @Published var backendActivity = TranslationBackendActivity()
    @Published private(set) var currentRuntimeConditions = ""
    @Published var initialWarmupProgress = ""
    var initialWarmupTask: Task<Void, Never>?
    var initialWarmupID = UUID()
    var observedModelRuns: [String: (at: Date, milliseconds: Double?)] = [:]
    /// v2.0.0 L2 (diagnostics only): Legacy model calls in flight per
    /// TranslationSession and the last return, to split confirmed model time
    /// by whether another session's call was running or ended < 1.5 s earlier.
    private var legacyModelInFlight: [ObjectIdentifier: Int] = [:]
    private var legacyLastModelReturn: (session: ObjectIdentifier, at: Double)?

    func modelRunKey(_ source: String, _ target: String, _ strategy: RequestedTranslationStrategy) -> String {
        source + ">" + target + "|" + strategy.rawValue
    }

    private func recordModelRun(source: String, target: String, strategy: RequestedTranslationStrategy,
                                milliseconds: Double?, at: Date = Date()) {
        guard !source.isEmpty, !target.isEmpty, source != target else { return }
        observedModelRuns[modelRunKey(source, target, strategy)] = (at, milliseconds)
        if observedModelRuns.count > 128,
           let oldest = observedModelRuns.min(by: { $0.value.at < $1.value.at }) {
            observedModelRuns.removeValue(forKey: oldest.key)
        }
    }

    var translationActivity: TranslationActivity {
        if activeTranslationSystem != .legacy, let activity = backendActivity.activity { return activity }
        if paused { return TranslationActivity(title: "Translation paused", detail: captureAlive ? "Capture is still connected. Resume to translate." : "Resume translation when you are ready.", phase: .waiting) }
        if activeTranslationSystem != .legacy, let work = modeWorkActivity, work.phase == .working || work.phase == .attention { return work }
        if activeTranslationSystem != .legacy {
            if displayedReadiness.activity.phase == .attention { return displayedReadiness.activity }
            if sourceCode == "auto", modelReadiness.source.isEmpty {
                return TranslationActivity(title: "Waiting for source language", detail: "Read a caption or choose a source language before preparation can run.", phase: .waiting)
            }
            return TranslationBackendActivity.idle(capture: captureAlive,
                ownInterfaceVisible: appInterfaceVisible && flag("suppressOwnInterface", true), modelObserved: modelReadiness.completedAt != nil)
        }
        if activeTranslationSystem == .legacy, isTranslating, modelReadiness.execution != .working {
            return TranslationActivity(title: "Processing current caption", detail: "Checking memory and scheduling complete translation units", phase: .working)
        }
        if activeTranslationSystem == .legacy, !captureAlive, modelReadiness.execution == .complete,
           modelReadiness.completedAt != nil {
            return TranslationActivity(title: "Idle · previous model run completed",
                detail: "A previous warm-up or translation succeeded. No model request is running now; iOS residency is unknown.",
                phase: .waiting)
        }
        if modelReadiness.activeSince != nil || modelReadiness.sessions == .complete || modelReadiness.languages == .blocked || modelReadiness.sessions == .blocked || modelReadiness.execution == .blocked {
            return modelReadiness.activity
        }
        if sourceCode == "auto", modelReadiness.source.isEmpty {
            return TranslationActivity(title: "Waiting for source language", detail: "Automatic needs a caption or a recent confirmed language before preparation can run.", phase: .waiting)
        }
        if activeTranslationSystem == .legacy {
            if !flag("keepWarm", true) { return TranslationActivity(title: "Idle warm-up is off", detail: "The model will run when live text requires translation.", phase: .waiting) }
            if !runtimePolicy.allowsPrewarming || ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
                return TranslationActivity(title: "Warm-up deferred by current conditions", detail: "Power, temperature or the current test policy limits idle work. Live text keeps priority.", phase: .waiting)
            }
            if directSession == nil, Date().timeIntervalSince(lastWarm) < 25 {
                return TranslationActivity(title: "Idle warm-up deferred", detail: "The existing warm-up cooldown is active. Live text can still request translation.", phase: .waiting)
            }
        }
        return modelReadiness.activity
    }

    private func refreshModePreparation(source: String, target: String, system: TranslationSystem) async {
        guard system == activeTranslationSystem, system != .legacy else { return }
        let ticket = UUID(), session = modeSessionID
        preparationTicket = ticket
        if modelReadiness.source != source || modelReadiness.target != target {
            modelReadiness = TranslationReadiness(source: source, target: target)
            restoreModelRun(source: source, target: target, system: system)
        }
        let result = await modeService.prepare(source: source, target: target, system: system) { [weak self] stage in
            guard let self, self.preparationTicket == ticket, self.modeSessionID == session else { return }
            self.modelReadiness.prepare(stage)
        }
        guard preparationTicket == ticket else { return }
        if result == "Preparation superseded" || Task.isCancelled {
            modelReadiness.activeSince = nil
            if modelReadiness.languages == .working { modelReadiness.languages = .pending }
            if modelReadiness.sessions == .working { modelReadiness.sessions = .pending }
        }
        guard !Task.isCancelled, session == modeSessionID, system == activeTranslationSystem,
              target == targetCode, source == (sourceCode == "auto" ? detectedLang : sourceCode), result != "Preparation superseded" else { return }
        modeAvailability = result; warmupStatus = result
    }
    private var captureIdentity = CaptureSessionIdentityGate()
    var modeSessionID = UUID()
    var modeDiagnosticEpochs: [UUID: Date] = [:]
    private var modeRevision = 0
    private var modeLastIdentity = ""
    private var modeMemoryOrigins: [String: String] = [:]
    /// v2.0.0 G6: the SQLite outcome of the first-sighting probe, reused by the
    /// confirmation probe of the same key moments later (RAM is still checked
    /// live first). Timeouts are never reused.
    private var recentSQLiteProbes: [String: (hit: MemoryLookupResult, at: Double, context: Int, session: UUID)] = [:]
    private var modePlans: [String: ([[CaptionTranslationUnit]], Packet, ModeCaption)] = [:]
    private var modePreparedPlans = ExactPlanReuseCache<ModePlanIdentity, ModePreparedPlan>(capacity: 4)

    private var modeModelTimings: [String: ModeModelTiming] = [:]
    private var modeConfirmationUptime: [String: Double] = [:]
    private var modeResultReadyUptime: [String: Double] = [:]
    // Hash only once per full capture-session/caption revision. The trace
    // never exports OCR text or an unhashed fingerprint. This removes repeated
    // SHA-256 and hex formatting from the high-frequency LL/Hybrid event path.
    private var modeFingerprintDigests: [String: String] = [:]
    let modeService = ModeTranslationService()
    lazy var modeCoordinator = ThreeModeCoordinator(
        lookup: { [weak self] caption in await self?.lookupModeMemory(caption) ?? caption.keys.map { _ in nil } },
        translate: { [weak self] caption, indices, strategy, speculative in
            await self?.modeService.translate(caption, indices: indices, strategy: strategy, speculation: speculative)
        },
        cancel: { [weak self] speculative in self?.modeService.cancel(speculation: speculative) },
        selected: { [weak self] caption, output, reason in self?.selectModeResult(caption, output: output, reason: reason) },
        event: { [weak self] caption, reason, ms in self?.noteModeEvent(caption, reason: reason, duration: ms) },
        status: { [weak self] message in
            self?.modeAvailability = message; self?.status = message; self?.isTranslating = false
            self?.modeWorkActivity = TranslationActivity(title: "Translation needs attention", detail: message, phase: .attention)
            self?.modeActivitySelected = true
        })

    func activateTranslationSystem() {
        let selection = TranslationSystem.migrate(ud)
        pendingTranslationSystem = selection.0
        if activeTranslationSystem != selection.0 {
            if activeTranslationSystem == .legacy, let at = modelReadiness.completedAt {
                recordModelRun(source: modelReadiness.source, target: modelReadiness.target,
                               strategy: .appleDefault, milliseconds: modelReadiness.durationMs, at: at)
            }
            modelReadiness = TranslationReadiness()
            initialWarmupProgress = ""
            startupWarmupTask?.cancel(); startupWarmupTask = nil
            idleValidationTask?.cancel(); idleValidationTask = nil
            invalidatePending()
            directSession = nil; directKey = ""; availCache.removeAll()
        }
        if activeTranslationSystem != selection.0 { diag.endRun(reason: "modeChanged"); refreshModeDiagnosticEpoch() } // a run never mixes modes
        activeTranslationSystem = selection.0
        modeCoordinator.system = selection.0
        // 2.2.1 (D13): the A/B settings are read here, at the start of a session, so a change never applies mid-run.
        HybridSchedulingPolicy.pinSetting()
        TranslationHotPathAB.pinSettings()
        modeCoordinator.hybridVariant = HybridSchedulingPolicy.buildVariant
        diag.modeActiveSystem = selection.0.rawValue
        diag.modePendingSystem = selection.0.rawValue
        diag.modeMigration = selection.1
        modeAvailability = selection.0 == .legacy ? "Apple default; effective model identity unavailable" : "Checking installed low-latency languages"
        if sourceCode != "auto" {
            if modelReadiness.source.isEmpty { modelReadiness = TranslationReadiness(source: sourceCode, target: targetCode) }
            restoreModelRun(source: sourceCode, target: targetCode, system: selection.0)
        }
        if #unavailable(iOS 26.4), selection.0 != .legacy {
            modeAvailability = selection.0 == .lowLatency ? "Explicit low latency requires iOS 26.4 or later" : "Fast recovery needs iOS 26.4; Apple default fallback remains available"
        }
        if selection.0 != .legacy, sourceCode != "auto" {
            let session = modeSessionID, source = sourceCode, target = targetCode
            Task { [weak self] in
                guard let self else { return }
                guard session == self.modeSessionID else { return }
                if !self.captureAlive { await self.prewarm() }
                else { await self.refreshModePreparation(source: source, target: target, system: selection.0) }
            }
        }
        if selection.0 == .legacy, !captureAlive, directSession == nil {
            Task { [weak self] in await self?.prewarm() }
        }
    }

    private func noteModeEvent(_ caption: ModeCaption, reason: String, duration: Double?) {
        if caption.session == modeSessionID {
            if reason == "confirmed" {
                if modeConfirmationUptime.count >= 256 { modeConfirmationUptime.removeAll() }
                modeConfirmationUptime[modeModelKey(caption)] = ProcessInfo.processInfo.systemUptime
            }
            if reason.hasPrefix("selected_") {
                if modeResultReadyUptime.count >= 256 { modeResultReadyUptime.removeAll() }
                modeResultReadyUptime[modeModelKey(caption)] = ProcessInfo.processInfo.systemUptime
            }
            if reason == "speculative_model_submitted" {
                modeCoordinator.noteSpeculativeModelSubmitted(caption)
            }
            // Keep the regular Diagnostics translation counters current for
            // both new modes. Legacy records these in its original scheduler.
            if diag.enabled {
                switch reason {
                case "speculation_admitted": diag.s.specStarted += 1
                case "speculation_ready": diag.s.specCompleted += 1
                case "speculation_failed": diag.s.specDiscarded += 1
                case "speculative_model_submitted": diag.s.specModelRequests += 1
                case "hybrid_speculation_throttled":
                    diag.s.specSkipped += 1
                    diag.s.adaptiveSpeculationSkipped += 1
                case "hybrid_speculation_backend_busy": diag.s.specSkipped += 1
                case "recovery_failed_missing": diag.s.failures += 1
                default: break
                }
            }
            if reason == "confirmed" || reason == "speculation_admitted" {
                modeActivityCaption = caption; modeActivitySelected = false
            }
            if modeActivityCaption?.matches(caption) == true, !modeActivitySelected,
               let activity = TranslationActivity.event(reason) {
                modeWorkActivity = activity
                if reason.hasPrefix("pip_enqueue_") || reason == "pip_held_unchanged" ||
                    reason == "display_failed" { modeActivitySelected = true }
            }
            if modeActivityCaption?.matches(caption) == true {
                if modelReadiness.source != caption.source || modelReadiness.target != caption.target { modelReadiness = TranslationReadiness(source: caption.source, target: caption.target) }
                if reason == "speculative_model_submitted" || reason == "confirmed_model_submitted" {
                    modelReadiness.beginExecution(label: "Running translation request")
                } else if reason == "speculative_model_completed" || reason == "confirmed_model_completed" {
                    modelReadiness.finishExecution(success: true, milliseconds: duration)
                } else if reason == "model_batch_failed" {
                    if !modeActivitySelected {
                        modelReadiness.finishExecution(success: false, milliseconds: duration)
                    } else if modelReadiness.execution == .working {
                        modelReadiness.execution = modelReadiness.completedAt == nil ? .pending : .complete
                        modelReadiness.activeSince = nil
                        modelReadiness.explanation = "Unneeded model work ended after the caption result was selected."
                    }
                }
            }
        }
        guard modeDiagnosticEpochs[caption.session] == diag.started else { return }
        if caption.session == modeSessionID, reason == "model_batch_completed",
           let duration, duration.isFinite, duration >= 0 {
            translateMs = duration
            diag.recordModeModel(ms: duration, system: caption.system ?? activeTranslationSystem)
        }
        if caption.session == modeSessionID, let duration, duration.isFinite, duration >= 0 {
            if reason == "speculative_model_completed" || reason == "confirmed_model_completed" {
                let key = modeModelKey(caption)
                if modeModelTimings.count >= 256 && modeModelTimings[key] == nil {
                    modeModelTimings.removeAll()
        modeConfirmationUptime.removeAll(); modeResultReadyUptime.removeAll()
                }
                var timing = modeModelTimings[key] ?? ModeModelTiming()
                if reason == "speculative_model_completed" { timing.speculative = duration }
                else { timing.confirmed = duration }
                modeModelTimings[key] = timing
            }
        }
        if ["speculative_model_submitted", "confirmed_model_submitted", "model_batch_failed", "model_batch_completed", "speculative_model_completed", "confirmed_model_completed"].contains(reason) {
            diag.noteModelState(reason, durationMs: duration, candidate: caption.caption)
        }
        if caption.session == modeSessionID,
           reason == "hybrid_simultaneous_model_overlap_ms", let duration,
           let fullRecovery = modeModelTimings[modeModelKey(caption)]?.confirmed {
            // Use physical simultaneous lane occupancy, not the entire
            // Low Latency service time, to drive speculative admission.
            modeCoordinator.noteOverlappingRecovery(serviceMilliseconds: fullRecovery,
                                                    simultaneousMilliseconds: duration)
        }
        if caption.session == modeSessionID, reason == "hybrid_default_fallback" {
            modeAvailability = "Fast recovery unavailable; using Apple default for this caption"
        }
        // Diagnostics can be disabled without paying the SHA-256 work for
        // every request phase; while enabled, reuse the same privacy-safe digest
        // for every stage of this exact caption revision.
        if diag.enabled {
            let key = modeModelKey(caption)
            let fingerprint: String
            if let cached = modeFingerprintDigests[key] {
                fingerprint = cached
            } else {
                fingerprint = SHA256.hash(data: Data(caption.fingerprint.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                if modeFingerprintDigests.count >= 256 {
                    modeFingerprintDigests.removeAll(keepingCapacity: true)
                }
                modeFingerprintDigests[key] = fingerprint
            }
            diag.noteModeEvent(session: caption.session, caption: caption.caption, revision: caption.revision,
                source: caption.source, target: caption.target,
                fingerprint: fingerprint, reason: reason, firstOCR: caption.firstOCR,
                duration: duration, mode: caption.system?.rawValue)
        }
    }

    private func handleModeCaption(_ blocks: [String], packet: Packet) {
        let started = ProcessInfo.processInfo.systemUptime
        let text = blocks.joined(separator: "\n")
        // Source routing is deliberately repeated on the independent confirmed
        // OCR read; an earlier tentative language guess is never reused blindly.
        guard let choice = detectSource(text, record: packet.stable != false),
              choice.language.languageCode != Locale.Language(identifier: targetCode).languageCode else { return }
        let source = choice.language.minimalIdentifier
        let identity = "\(packet.candidateID ?? "manual")|\(source)|\(targetCode)|\(ConfirmedSourceIdentity.normalize(text))"
        if identity != modeLastIdentity { modeRevision += 1; modeLastIdentity = identity }
        let rulesToken = memoryRuleToken
        let captionID = packet.candidateID ?? "manual-\(modeRevision)"
        let planIdentity = ModePlanIdentity(session: modeSessionID, candidate: captionID,
            system: activeTranslationSystem, source: source, target: targetCode,
            rules: rulesToken, configuration: packet.rev ?? -1, rotation: rotRev,
            context: contextRevision, orientation: packet.orient, blocks: blocks,
            layout: packet.lines.map(ModeLayout.init))
        let plan: ModePreparedPlan
        let reused: Bool
        let planReuseEnabled = activeTranslationSystem != .lowLatency ||
            TranslationHotPathAB.reuseStandaloneLowLatencyPlan
        if planReuseEnabled, let cached = modePreparedPlans.lookup(planIdentity) {
            plan = cached
            reused = true
        } else {
            let cleaningEnabled = flag("cleanOCR", true)
            let sourceFixes = pairs("sourceFixes")
            let slangEnabled = flag("slang", true)
            let speakersEnabled = flag("speakerDetect", true)
            let protectedWords = list("neverTranslate", lower: false)
            let languageCode = choice.language.languageCode?.identifier ?? source
            var rows: [[CaptionTranslationUnit]] = []
            var keys: [String] = [], inputs: [String] = []
            for block in blocks {
                let clean = cleanedSource(block, enabled: cleaningEnabled, fixes: sourceFixes)
                let parts = preparedSourceUnits(clean, language: languageCode,
                    slang: slangEnabled, speakers: speakersEnabled, protected: protectedWords)
                var row: [CaptionTranslationUnit] = []
                for part in parts {
                    row.append(CaptionTranslationUnit(label: part.label, sentences: part.sentences,
                        out: part.sentences.map { _ in nil }, tokens: part.tokens))
                    for sentence in part.sentences {
                        inputs.append(sentence)
                        keys.append(SharedTranslationWork.unitKey(source: source, target: targetCode, text: sentence,
                            protectedWords: part.tokens.map { "\($0.0)=\($0.1)" }, rules: rulesToken))
                    }
                }
                rows.append(row)
            }
            plan = ModePreparedPlan(rows: rows, keys: keys, inputs: inputs)
            modePreparedPlans.insert(plan, for: planIdentity)
            reused = false
        }
        guard !plan.inputs.isEmpty else { return }
        let monotonicOrigin = CaptionClockOrigin.monotonic(firstSeen: packet.firstSeenMonotonic,
            wallFirstSeen: packet.firstSeenAt ?? packet.ts ?? Date().timeIntervalSince1970,
            wallNow: Date().timeIntervalSince1970, uptimeNow: ProcessInfo.processInfo.systemUptime)
        let caption = ModeCaption(system: activeTranslationSystem, thermal: ProcessInfo.processInfo.thermalState.rawValue,
            session: modeSessionID, caption: captionID, revision: modeRevision,
            source: source, target: targetCode, rules: rulesToken, text: text,
            units: plan.inputs, keys: plan.keys, firstOCR: monotonicOrigin)
        let confirmed = packet.stable != false
        if confirmed, let current = modeCoordinator.current, current.matches(caption),
           current.revision == caption.revision { return }
        noteModeEvent(caption, reason: reused ? "mode_plan_reused_ms" : "mode_plan_built_ms",
            duration: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        if confirmed {
            isTranslating = true
            activeCandidateID = captionID; activeCandidateText = text
            activeCandidateConfirmed = true; activeCandidatePresented = false
            latestBlocks = blocks
            modePlans = [captionID: (plan.rows, packet, caption)]
            detectedLang = source
            noteModeEvent(caption, reason: "confirmed", duration: nil)
        }
        let thermal = ProcessInfo.processInfo.thermalState
        let admitted = speculationAllowed && !ProcessInfo.processInfo.isLowPowerModeEnabled &&
            memoryTestMode.allowsSpeculation && flag("translateAhead", true) &&
            thermal != .serious && thermal != .critical &&
            SpeculationPolicy.credible(lines: packet.lines, threshold: num("speculationConfidence", 0.85))
        modeCoordinator.allowsReuse = memoryTestMode.allowsReuse && !bypassMemory
        let fastPack = languageCoverage(for: source).lowLatency
        let fastPackKnownMissing = fastPack == .supported || fastPack == .unsupported
        modeCoordinator.fastRecoveryInstalled = !fastPackKnownMissing
        modeCoordinator.adaptiveHybrid = flag("adaptiveSpeculation", true) && !fastPackKnownMissing
        modeCoordinator.hybridSwitchGuard = flag("hybridSwitchGuard", true)
        if confirmed, activeTranslationSystem != .legacy {
            let pair = source + ">" + caption.target + "|" + activeTranslationSystem.rawValue
            let needsCheck = modelReadiness.source != source || modelReadiness.target != caption.target ||
                (modelReadiness.sessions != .complete && modelReadiness.sessions != .working)
            if needsCheck && !backendActivity.executing &&
                (pair != lastModePreparationPair || Date().timeIntervalSince(lastModePreparationAt) >= 5) {
                lastModePreparationPair = pair
                lastModePreparationAt = Date()
                let session = modeSessionID, system = activeTranslationSystem
                Task { [weak self] in
                    guard let self, session == self.modeSessionID, !self.backendActivity.executing else { return }
                    await self.refreshModePreparation(source: source, target: caption.target, system: system)
                }
            }
        }
        modeCoordinator.observe(caption, confirmed: confirmed, speculate: admitted)
    }

    private func lookupModeMemory(_ caption: ModeCaption) async -> [String?] {
        let bank = ram, context = contextRevision
        let canReadPersistent = allowsPersistentTranslations && memoryReady &&
            flag("remember", true) && !flag("privateSession", false)
        // Most live subtitles have exactly one translation unit. Resolve that
        // directly without allocating duplicate-key maps/sets, while retaining
        // the identical RAM -> SQLite -> fresh ordering and all invalidation
        // checks. Multi-unit captions continue through the existing path.
        if caption.keys.count == 1 {
            guard context == contextRevision, caption.session == modeSessionID else {
                return [nil]
            }
            let key = caption.keys[0]
            if let hit = bank.values[key] {
                if modeMemoryOrigins.count >= 3000 { modeMemoryOrigins.removeAll() }
                let saved = bank.savedKeys.contains(key)
                modeMemoryOrigins[key] = saved ? "saved_ram" : "ram"
                noteModeEvent(caption, reason: saved ? "memory_saved_ram_hit" : "memory_session_hit", duration: nil)
                return [hit]
            }
            guard canReadPersistent else { return [nil] }
            let hit: MemoryLookupResult
            let uptime = ProcessInfo.processInfo.systemUptime
            if let recent = recentSQLiteProbes[key], recent.context == context,
               recent.session == caption.session, uptime - recent.at < 3 {
                hit = recent.hit
                noteModeEvent(caption, reason: "memory_probe_reused", duration: nil)
            } else {
                hit = await memoryStore.lookup(key: key)
                if hit.outcome != "timeout" {
                    if recentSQLiteProbes.count >= 64 { recentSQLiteProbes.removeAll() }
                    recentSQLiteProbes[key] = (hit, ProcessInfo.processInfo.systemUptime, context, caption.session)
                }
            }
            guard context == contextRevision, caption.session == modeSessionID else {
                return [nil]
            }
            guard let value = hit.value else { return [nil] }
            if modeMemoryOrigins.count >= 3000 { modeMemoryOrigins.removeAll() }
            modeMemoryOrigins[key] = hit.outcome == "normalized_hit" ? "normalized" : hit.origin
            let origin = hit.origin == "legacy" ? "memory_legacy_hit" :
                (hit.origin == "normalized" ? "memory_normalized_hit" : "memory_persistent_hit")
            noteModeEvent(caption, reason: origin, duration: hit.durationMs)
            return [value]
        }
        var output: [String?] = []
        output.reserveCapacity(caption.keys.count)
        // Repeated subtitle units share one identity. Never perform duplicate
        // SQLite reads for identical keys within a caption; preserve order.
        var resolved: [String: String] = [:]
        var missing: Set<String> = []
        for key in caption.keys {
            guard context == contextRevision, caption.session == modeSessionID else {
                return caption.keys.map { _ in nil }
            }
            if let earlier = resolved[key] {
                output.append(earlier)
                continue
            }
            if missing.contains(key) {
                output.append(nil)
                continue
            }
            if let hit = bank.values[key] {
                if modeMemoryOrigins.count >= 3000 { modeMemoryOrigins.removeAll() }
                let saved = bank.savedKeys.contains(key)
                modeMemoryOrigins[key] = saved ? "saved_ram" : "ram"
                noteModeEvent(caption, reason: saved ? "memory_saved_ram_hit" : "memory_session_hit", duration: nil)
                resolved[key] = hit
                output.append(hit)
                continue
            }
            if canReadPersistent {
                let hit = await memoryStore.lookup(key: key)
                guard context == contextRevision, caption.session == modeSessionID else {
                    return caption.keys.map { _ in nil }
                }
                if let value = hit.value {
                    if modeMemoryOrigins.count >= 3000 { modeMemoryOrigins.removeAll() }
                    modeMemoryOrigins[key] = hit.outcome == "normalized_hit" ? "normalized" : hit.origin
                    let origin = hit.origin == "legacy" ? "memory_legacy_hit" :
                        (hit.origin == "normalized" ? "memory_normalized_hit" : "memory_persistent_hit")
                    noteModeEvent(caption, reason: origin, duration: hit.durationMs)
                    resolved[key] = value
                    output.append(value)
                } else {
                    missing.insert(key)
                    output.append(nil)
                }
            } else {
                missing.insert(key)
                output.append(nil)
            }
        }
        return output
    }

    private func selectModeResult(_ caption: ModeCaption, output: ModeOutput, reason: String) {
        let commitBegan = ProcessInfo.processInfo.systemUptime
        guard caption.session == modeSessionID, let (template, packet, expected) = modePlans[caption.caption],
              caption == expected, caption.source == (sourceCode == "auto" ? detectedLang : Locale.Language(identifier: sourceCode).minimalIdentifier),
              caption.target == targetCode, caption.rules == memoryRuleToken else { return }
        var rows = template, index = 0
        for b in rows.indices { for u in rows[b].indices { for i in rows[b][u].out.indices {
            guard index < output.values.count else { return }
            rows[b][u].out[i] = output.values[index]; index += 1
        } } }
        guard let result = CaptionAssembly.complete(rows, glossary: pairs("glossary")), index == output.values.count else { return }
        if diag.enabled {
            diag.s.translations += 1; diag.s.chars += caption.text.count; diag.s.sentences += output.values.count
            for i in output.values.indices {
                let origin = output.origins[i]
                if origin == "speculation" { diag.s.specHits += 1; diag.recordMemory(.speculativeHit, candidate: caption.caption) }
                else if origin == "compatible_memory" || origin == "session_low_latency" || origin == "session_apple_default" {
                    let provenance = origin.hasPrefix("session_") ? "ram" : (modeMemoryOrigins[caption.keys[i]] ?? "ram")
                    let saved = ["persistent", "legacy", "normalized", "saved_ram"].contains(provenance)
                    if saved { diag.s.savedHits += 1 } else { diag.s.cacheHits += 1 }
                    let outcome: MemoryDiagnosticOutcome = provenance == "persistent" ? .persistentHit : (provenance == "legacy" ? .legacyHit : (provenance == "normalized" ? .normalizedHit : .ramHit))
                    diag.recordMemory(outcome, candidate: caption.caption)
                } else {
                    diag.s.cacheMisses += 1
                    // 2.3.1: Legacy records .bypassed when memory reuse is switched off; these modes recorded .miss.
                    diag.recordMemory((memoryTestMode.allowsReuse && !bypassMemory) ? .miss : .bypassed, candidate: caption.caption)
                }
                if memoryTestMode == .temporaryMemory {
                    if origin == "speculation" || origin == "compatible_memory" ||
                       origin == "session_low_latency" || origin == "session_apple_default" { diag.noteTemporaryReuse() }
                    else { diag.recordMemory(.temporaryMiss, candidate: caption.caption) }
                }
            }
        }
        // LL values never enter the shared preferred namespace, even in RAM.
        if memoryTestMode.allowsReuse {
            // The caption text is the same for every unit: evaluate language
            // evidence at most once per caption, not once per Default unit.
            var captionConfidence: Double?
            for i in output.values.indices where output.strategies[i] == .appleDefault {
                ram.values[caption.keys[i]] = output.values[i]; touchCache(caption.keys[i])
                let confidence: Double
                if sourceCode != "auto" {
                    confidence = 1
                } else if let known = captionConfidence {
                    confidence = known
                } else {
                    let measured = languageEvidence(caption.text, limit: 5).1.filter {
                        SourceLanguageRouter.sameLanguage($0.key.rawValue, caption.source)
                    }.values.max() ?? 0
                    captionConfidence = measured
                    confidence = measured
                }
                if TranslationUnitPlanning.mayRemember(caption.units[i], confirmed: true),
                   MemoryRetentionPolicy.mayPersist(privateSession: flag("privateSession", false), selectedSource: sourceCode != "auto", confidence: confidence, confirmed: true) {
                    queueMemory(caption.keys[i], output.values[i], independentlyConfirmed: output.origins[i] == "recovery", knownDefault: true)
                }
            }
            trimCache()
        }
        let now = Date()
        let origin = now.timeIntervalSince1970 - max(0, ProcessInfo.processInfo.systemUptime - caption.firstOCR)
        let backend = modeModelTimings[modeModelKey(caption)]
        let modelProcessing: Double
        if output.origins.contains("recovery") {
            modelProcessing = backend?.confirmed ?? 0
        } else if output.origins.contains("speculation") {
            modelProcessing = backend?.speculative ?? 0
        } else {
            modelProcessing = 0
        }
        let timing = PresentationTiming(packet: packet, firstSeen: origin, queuedAt: now,
            processingAt: now, processingMs: modelProcessing,
            savedRequests: output.origins.filter {
                $0 == "compatible_memory" || $0 == "session_low_latency" || $0 == "session_apple_default"
            }.count, readyAt: now)
        isTranslating = false
        status = "\(caption.source) → \(caption.target) ✓"
        let presented = show(caption.text, result, timing: timing)
        if presented {
            let pipAt = ProcessInfo.processInfo.systemUptime
            noteModeEvent(caption, reason: "mode_commit_to_pip_ms",
                duration: max(0, pipAt - commitBegan) * 1000)
            if let confirmedAt = modeConfirmationUptime[modeModelKey(caption)] {
                noteModeEvent(caption, reason: "mode_confirmation_to_pip_ms",
                    duration: max(0, pipAt - confirmedAt) * 1000)
            }
            if let readyAt = modeResultReadyUptime[modeModelKey(caption)] {
                noteModeEvent(caption, reason: "mode_ready_to_pip_ms",
                    duration: max(0, pipAt - readyAt) * 1000)
            }
            diag.recordModeSelection(sentences: output.values.count, source: caption.source, target: caption.target)
            noteModeEvent(caption, reason: lastShowReusedFrame ? "pip_held_unchanged" : "pip_enqueue_" + reason,
                duration: max(0, ProcessInfo.processInfo.systemUptime - caption.firstOCR) * 1000)
        } else { noteModeEvent(caption, reason: "display_failed", duration: nil) }
    }

    private var contextRevision = 0
    private var generation = 0
    var legacyRequestID = UUID()
    var legacySpeculative = false
    private var latestBlocks: [String] = []
    var lastHandled = ""
    var queued: [String]?
    private var queuedTs: Double = 0
    private var currentTs: Double = 0
    private var queuedPacket: Packet?
    private var currentPacket: Packet?
    var queuedAt = Date()
    private var currentQueuedAt = Date()
    private var processingStarted = Date()
    var savedRequests = 0
    var warming = false
    var legacyValidationBusy = false
    var idleValidationTask: Task<Void, Never>?
    var legacyValidationCursor: Int64 = 0
    var legacyValidationExhausted = false
    var legacyScanFingerprint = ""
    @Published var legacyValidationInventory: [String: Int] = [:]
    @Published var legacyScanReasons: [String: Int] = [:]

    private var lastIdleValidationAttempt = Date.distantPast
    private var legacyBatchStartedAt = Date.distantPast
    private var legacyAverageRate = 0.0
    var languageCache: [String: (NLLanguage?, [NLLanguage: Double])] = [:]
    private var drainTask: Task<Void, Never>?
    private var activeCandidateText = ""
    var activeCandidateID: String?
    private var activeCandidateConfirmed = false
    private var activeCandidatePresented = false
    private var activeCandidateConfirmedAt = Date.distantPast
    var deferredConfirmedPacket: Packet?
    var confirmedHandoffDeadlineTask: Task<Void, Never>?
    var deferredConfirmedReceivedAt = Date.distantPast
    private var specPacket: Packet?
    private var currentSpeculativeText: String?
    private var subtitleRegions = SubtitleRegions()
    private var movieTextFocus = MovieTextFocus()
    private var languageFailures = 0
    var rulesSnapshot = "", rulesDigest = ""
    var busy = false
    private var activeQueueOwner = ModelQueueOwner.scheduling
    private var queuedWaitOwner = ModelQueueOwner.scheduling
    private var modelUnitKeysInFlight = Set<String>()
    private var modelContextInFlight: Int?
    var showing = false
    private var lastShowReusedFrame = false
    var pendingTexts: [String] = []
    var legacyContinuation: CheckedContinuation<[String]?, Never>?
    private var lastPacketDate = Date.distantPast
    private var lastTextDate = Date()
    /// Where the session-limit countdown starts: the session start, or the last resume (E2).
    var limitBase: Date?
    private var lastShowDate = Date.distantPast
    private let modelPerf = OSSignposter(subsystem: "com.diam0ndnex.screenlingo", category: "model")
    var directSession: TranslationSession?
    private let speculativeSessions = SpeculativeSessionOwner<TranslationSession> { session in
        if #available(iOS 26.0, *) { session.cancel() }
    }
    var directKey = ""
    var clearTask: Task<Void, Never>?
    private var tickCount = 0
    private var lastThermalSyncState: ProcessInfo.ThermalState?
    var toastToken = 0
    // Translation speed system
    var specQueued: [String]?
    private var lastSpecText = ""
    private var lastWarm = Date.distantPast
    private var lastUnresolvedWarmupNotice = Date.distantPast
    private var startupWarmupTask: Task<Void, Never>?
    var warmupSession: TranslationSession?
    var warmupSuperseded = false
    let memoryStore = TranslationMemoryStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScreenLingo/TranslationMemory", isDirectory: true))
    @Published var memoryHealth: MemoryStoreHealth?
    @Published var memoryPendingWrites = 0
    @Published var memoryFailure: String?
    var pendingMemory: [String: String] = [:]
    var pendingDefaultStrategy: [String: String] = [:]
    // A proof is recorded only when the current model generated the result for a
    // confirmed subtitle; speculative/ RAM/ SQLite reuse never counts as proof.
    var pendingLegacyProof: [String: String] = [:]
    var memorySaving = false
    var memoryCoalescingTask: Task<Void, Never>?
    private var appInterfaceVisible = true
    var memoryMutationInProgress = false
    var memoryRetryAttempts = 0
    var storageFullRetryNotBefore = Date.distantPast
    var memoryPressureCapacity: Int?
    let processMemory = ProcessTranslationMemory()
    @Published var memoryTestMode = TranslationTestMode.normal
    @Published var temporaryMemoryEntries = 0
    var memoryReady = false
    var segmentationCache = SegmentationCache(capacity: 512)
    private var bypassMemory = false
    var memoryRevision = 0
    var memoryDirty = false
    private var lastMemorySave = Date.distantPast
    var availCache: [String: (Date, LanguageAvailability.Status)] = [:]
    var suppressRecent = false
    let speech = AVSpeechSynthesizer()
    // Reading-order calibration
    private var orderVote = 0.0
    private var votesSinceChange = 0
    private var trial = 0
    var autoRot = 0
    private var rotRev = 0
    private var calibrated = false
    // Language lock
    var languageRouter = SourceLanguageRouter()
    var languageContext = LanguageContext()
    private var rotationBudget = RotationBudget()
    private var lastConfiguredRotation = "auto"
    private var lastCaptureOrientation: Int?

    // Self-reading protection: what the PiP window currently shows, and where it is on screen
    let placeholderGrams = TextSim.grams("Waiting for screen text… Listening…")
    var renderedGrams = TextSim.grams("Waiting for screen text… Listening…")
    var sourceGrams: Set<String> = []
    var pipRegion: CGRect?
    var pipRegionStamp = Date.distantPast

    init() {
        PresetRecognitionPolicy.migrate(UserDefaults.standard)
        let migration = TranslationSystem.migrate(UserDefaults.standard)
        activeTranslationSystem = migration.0; pendingTranslationSystem = migration.0
        diag.modeActiveSystem = migration.0.rawValue; diag.modePendingSystem = migration.0.rawValue
        diag.modeMigration = migration.1
        modeAvailability = migration.0 == .legacy ? "Apple default; effective model identity unavailable" : "Checking installed low-latency languages"
        sourceCode = UserDefaults.standard.string(forKey: "source") ?? "auto"
        targetCode = UserDefaults.standard.string(forKey: "target") ?? "en"
        memoryTestMode = TranslationTestMode(freshRequests: flag("freshTranslationTest", false),
                                           temporaryMemory: flag("temporaryMemoryTest", false))
        diag.translationTestMode = memoryTestMode
        diag.ramEntryCount = { [weak self] in
            guard let self, self.memoryTestMode.allowsReuse else { return 0 }
            return self.ram.values.count
        }
        UserDefaults.standard.removeObject(forKey: "persistDiagnosticSessions") // migrated: saving is now testRunSaving (automatic)
        Task { [weak diag] in await diag?.recoverRuns() } // leftover checkpoints become "Recovered (incomplete)" runs
        modeDiagnosticEpochs[modeSessionID] = diag.started
        modeCoordinator.system = activeTranslationSystem
        modeCoordinator.hybridSpeculationPermitted = { [weak self] in
            guard let self else { return false }
            switch self.modeCoordinator.hybridVariant {
            case .reference195: return self.modeService.mayAdmitReferenceHybridSpeculation
            case .recoveryFirst, .evidenceBounded: return self.modeService.mayAdmitHybridSpeculation
            }
        }
        modeCoordinator.appleDefaultGapMs = { [weak self] caption in
            self?.modeService.appleDefaultGapMs(source: caption.source, target: caption.target)
        }
        modeService.mayStartModel = { [weak self] caption, speculative in
            guard let self, self.modeCoordinator.shouldStartModel(caption, speculative: speculative) else { return false }
            // A request can suspend on RAM or language availability after it
            // was admitted. Check *again* immediately before acquiring the
            // real speculative Apple session, never just at OCR observation.
            if speculative && caption.system == .hybridRecovery &&
                self.modeCoordinator.hybridVariant != .reference195 &&
                self.modeService.hasConfirmedLowLatencyDemand { return false }
            return true
        }
        modeService.hostedDefault = { [weak self] texts, source, target, speculative in
            await self?.translateLegacy(texts, source: source, target: target, speculative: speculative)
        }
        modeService.event = { [weak self] caption, reason, ms in self?.noteModeEvent(caption, reason: reason, duration: ms) }
        modeService.modelRequestCompleted = { [weak self] source, target, strategy, ms in
            self?.recordModelRun(source: source, target: target, strategy: strategy, milliseconds: ms)
        }
        modeService.activityChanged = { [weak self] activity in self?.backendActivity = activity }
        modeService.warmupEvent = { [weak self] observation in
            guard let self else { return }
            self.diag.noteInitialWarmup(observation)
            if observation.phase == "model_completed" {
                self.recordModelRun(source: observation.source, target: observation.target,
                                    strategy: observation.strategy, milliseconds: observation.durationMs)
            }
            guard observation.system == self.activeTranslationSystem,
                  !self.captureAlive, self.initialWarmupTask?.isCancelled == false,
                  observation.source == self.modelReadiness.source, observation.target == self.targetCode else { return }
            let strategy = observation.strategy == .lowLatency ? "Low latency" : "Apple default"
            if observation.phase == "model_submitted" {
                self.initialWarmupProgress = "Warming \(strategy) · \(observation.source) → \(observation.target)"
                self.modelReadiness.beginExecution(label: "Initial warm-up · " + strategy)
            } else if observation.phase == "model_completed" {
                self.modelReadiness.finishExecution(success: true, milliseconds: observation.durationMs)
                self.warmupLastDurationMs = observation.durationMs
                self.initialWarmupProgress = "\(strategy) warm-up completed · output discarded"
            } else if observation.phase == "model_batch_failed" || observation.phase == "model_timeout" {
                self.initialWarmupProgress = "\(strategy) warm-up did not complete; live translation can retry normally"
                self.modelReadiness.execution = self.modelReadiness.completedAt == nil ? .pending : .complete
                self.modelReadiness.activeSince = nil
            }
        }
        modeService.status = { [weak self] message in self?.modeAvailability = message }
        server.onPacket = { [weak self] packet in self?.handle(packet) }
        server.start()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        pip.setSize(windowSize.size)
        pip.onStatus = { [weak self] s in Task { @MainActor in self?.status = s } }
        pip.onStartFailed = { [weak self] in
            Task { @MainActor in
                self?.diag.noteRuntimeState("pip_start_failed")
                self?.toast("The floating window could not open. Stay in ScreenLingo and try again.")
            }
        }
        pip.onActiveChange = { [weak self] a in
            Task { @MainActor in
                self?.pipActive = a
                if a { self?.idleValidationTask?.cancel() }
                self?.diag.log(a ? "Floating window opened" : "Floating window closed")
            }
        }
        if ud.object(forKey: "displayPolicy") == nil {
            ud.set(PresentationSchedule.inferredPolicy(saved: nil, minimum: num("minDisplay", 0)), forKey: "displayPolicy")
        }
        lastConfiguredRotation = frameRotMode
        recentPairs = ud.stringArray(forKey: "recentPairs") ?? []
        loadHistory()
        loadMemory()
        presets.onApplied = { [weak self] in
            self?.reloadSettings()
            if let n = self?.presets.active?.name { self?.diag.log("Preset applied: \(n)") }
        }
        presets.applyStartup()
        diag.log("App started \(AppVersion.full)")
        diag.noteRuntimeState("app_started")
        startupWarmupTask = Task { [weak self] in
            await self?.prewarm()
            self?.startupWarmupTask = nil
        } // Prepare a recent source pair before capture, when possible.
    }

    func tick() {
        tickCount += 1
        let conditions = translationConditions
        if currentRuntimeConditions != conditions { currentRuntimeConditions = conditions }
        if activeTranslationSystem != .legacy, initialWarmupTask != nil,
           ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            interruptWarmupForLiveWork()
            initialWarmupProgress = "Initial warm-up deferred by power or temperature conditions"
        }
        captureReadiness.tick(at: ProcessInfo.processInfo.systemUptime)
        publishCaptureStatus()
        let alive = Date().timeIntervalSince(lastPacketDate) < 5
        let thermalState = ProcessInfo.processInfo.thermalState
        if lastThermalSyncState != thermalState {
            lastThermalSyncState = thermalState
            // Restore full capture policy promptly after serious/critical
            // without touching active translation sessions or persistent memory.
            if alive { syncConfig() }
        }
        if captureAlive && !alive {
            status = "Capture stopped – iOS may have closed the capture extension. Tap the broadcast icon again (try Speed: Fast)."
            diag.log("Capture stopped")
            diag.noteRuntimeState("heartbeat_timeout")
            diag.pauseRun(reason: "heartbeatTimeout", frames: frames)
            if activeTranslationSystem != .legacy { invalidatePending() }
        }
        if captureAlive != alive { captureAlive = alive }
        if alive, let started = limitBase ?? sessionStarted, int("sessionLimit", 0) > 0,
           Date().timeIntervalSince(started) >= Double(int("sessionLimit", 0)) * 60, !paused {
            paused = true
            toast("Session timer reached – translation paused. Turn Pause off to continue; the timer starts again.")
            diag.noteRuntimeState("session_time_limit")
        }
        if activeTranslationSystem != .legacy,
           ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            modeCoordinator.reduceSpeculation(memoryPressure: false)
        }
        diag.noteThermalState()
        diag.tick(alive: alive, paused: paused, frozen: frozen)
        if tickCount % 5 == 0 { saveMemory() }
        if tickCount % 60 == 0 { applyHistoryRetention() }
        if tickCount % 5 == 0 { refreshLegacyScanContext() }
        if tickCount % 5 == 0, flag("legacyIdleValidationEnabled", false),
           !legacyValidationExhausted, mayRunIdleValidation {
            let fair = ThermalPerformancePolicy.automaticPressure(for: ProcessInfo.processInfo.thermalState)
            if Date().timeIntervalSince(lastIdleValidationAttempt) >=
                IdleLegacyBatchPolicy.cooldownSeconds(thermalFair: fair) {
                startLegacyValidation(maxEntries: IdleLegacyBatchPolicy.automaticEntries)
            }
        }
        if alive, !paused, tickCount % 10 == 0, Date().timeIntervalSince(lastTextDate) > 8,
           Date().timeIntervalSince(lastWarm) > 25 {
            Task { await prewarm() }
        }
        UIApplication.shared.isIdleTimerDisabled = alive && flag("keepAwake", true)
        if tickCount % 10 == 0, alive { syncConfig() }        // refreshes adaptive performance
        let idle = int("idleMinutes", 0)
        if idle > 0, alive, !paused, Date().timeIntervalSince(lastTextDate) > Double(idle) * 60 {
            paused = true
            status = "Paused after \(idle) min without text. Turn Pause off to resume; the idle timer starts again."
            diag.log("Auto-paused (idle)")
            diag.noteRuntimeState("idle_auto_pause")
        }
    }

    /// Called when the user changes the frame-rotation setting.
    func rotationSettingChanged() {
        rotationBudget.reset()
        lastConfiguredRotation = frameRotMode
        autoRot = 0; trial = 0; orderVote = 0; votesSinceChange = 0; calibrated = false
        rotRev += 1
        invalidatePending()
        syncConfig()
    }

    private func languageSelectionChanged() {
        modelReadiness = TranslationReadiness()
        invalidatePending()
        languageRouter.reset(); languageContext.reset(); rotationBudget.reset()
        languageFailures = 0
        lockedLang = nil
        detectedLang = "–"
        latestBlocks = []
        // Re-evaluate automatic rotation from ReplayKit orientation, not the previous language's guess.
        autoRot = 0; trial = 0; orderVote = 0; votesSinceChange = 0; calibrated = false
        if diag.enabled { diag.s.orderVote = 0; diag.s.calibrated = false }
        // Reject in-flight OCR for the old pair and request fresh confirmation of static text.
        rotRev += 1
        syncConfig()
        diag.event(.language, "Source selection changed: \(sourceCode) → \(targetCode)")
        if activeTranslationSystem != .legacy { Task { [weak self] in await self?.prewarm() } }
    }

    func testModeSettingsChanged() {
        let next = TranslationTestMode(freshRequests: flag("freshTranslationTest", false),
                                       temporaryMemory: flag("temporaryMemoryTest", false))
        guard next != memoryTestMode else { return }
        // Close the old measurement cohort before changing cache access policy.
        diag.reset()
        invalidatePending()
        idleValidationTask?.cancel()
        memoryTestMode = next
        diag.translationTestMode = next
        diag.startingRAMEntries = next.allowsReuse ? ram.values.count : 0
        if temporaryMemoryEntries != processMemory.temporary.values.count {
            temporaryMemoryEntries = processMemory.temporary.values.count
        }
        bypassMemory = false
        rotRev += 1
        syncConfig()
        if let health = memoryHealth { applyMemoryHealth(health) }
    }

    func diagnosticsSettingsChanged() {
        diag.collectionChanged()
        modeModelTimings.removeAll()
        // Collection reset starts a new diagnostic epoch without stopping
        // capture. Continue accepting current-mode events in that new cohort.
        modeDiagnosticEpochs[modeSessionID] = diag.started
        if diag.enabled {
            diag.s.lockedLang = lockedLang ?? "–"
            diag.s.rotation = effectiveRot
            diag.s.orderVote = orderVote
            diag.s.calibrated = calibrated && !rotationBudget.exhausted
        }
    }

    func resetDiagnostics() {
        diag.reset()
        modeModelTimings.removeAll()
        modeDiagnosticEpochs[modeSessionID] = diag.started
        if diag.enabled {
            diag.s.lockedLang = lockedLang ?? "–"
            diag.s.rotation = effectiveRot
            diag.s.orderVote = orderVote
            diag.s.calibrated = calibrated && !rotationBudget.exhausted
        }
    }

    /// Own-app visibility is observable; video playback in another app is not.
    /// Do not translate ScreenLingo's diagnostic/settings interface back into PiP.
    func setAppInterfaceVisible(_ visible: Bool) {
        guard visible != appInterfaceVisible else { return }
        appInterfaceVisible = visible
        rotRev += 1 // Reject packets produced before the visibility boundary.
        invalidatePending()
        diag.noteRuntimeState(visible ? "app_interface_visible" : "external_capture_period")
        syncConfig()
    }

    func pipelineSettingsChanged() {
        diag.noteRuntimeState("capture_config_changed")
        invalidatePending()
        rotRev += 1
        syncConfig()
    }

    /// Sends OCR area, source-language hint, speed and rotation to the extension.
    func syncConfig() {
        let r = area.range()
        var maxEdge = speed.maxEdge, interval = speed.interval
        if flag("adaptive", true) {
            switch ProcessInfo.processInfo.thermalState {
            case .serious: maxEdge *= 0.75; interval *= 1.5
            case .critical: maxEdge *= 0.55; interval *= 2.5
            default: break
            }
            if ProcessInfo.processInfo.isLowPowerModeEnabled { interval *= 1.5 }
            if extFreeMB > 0 && extFreeMB < 12 { maxEdge = min(maxEdge, 800) }
        }
        let intelligentCool = flag("coolMode", false) && flag("smartCool", true)
        if !intelligentCool { interval = runtimePolicy.captureInterval(interval) }
        if diag.enabled {
            diag.s.rotation = effectiveRot
            diag.noteCapturePolicy(edge: maxEdge, interval: interval,
                coolMode: flag("coolMode", false),
                memoryPressure: extFreeMB > 0 && extFreeMB < 12,
                workloadPressure: busy && queued != nil)
        }
        server.send(Config(lang: SourceLanguageRouter.captureLanguage(selected: sourceCode, locked: lockedLang), y0: r.lowerBound, y1: r.upperBound,
                           maxEdge: maxEdge, interval: interval, paused: paused || manualMode,
                           stability: int("stability", 2), rot: effectiveRot, rev: rotRev,
                           boost: int("boost", 1), skipUnchanged: flag("skipUnchanged", true),
                           subtitleAwareChangeDetection: flag("subtitleAwareChangeDetection", false),
                           speculate: speculationAllowed && flag("translateAhead", true), confidence: num("ocrConfidence", 0.3),
                           correction: flag("ocrCorrection", true), idleBackoff: flag("idleBackoff", true),
                           movieMode: flag("rapidTextTracking", true),
                           rapidTextTracking: flag("rapidTextTracking", true),
                           captureDiagnostics: diag.enabled,
                           adaptiveOCR: speed == .automatic || (speed == .balanced && flag("adaptiveOCR", true)),
                           adaptiveConfirmation: flag("adaptiveConfirmation", false), subtitleTracking: flag("subtitleTracking", true),
                           confirmationDeadline: num("confirmationDeadline", 0.6), smartCool: intelligentCool,
                           pressure: flag("adaptive", true) && (intelligentCool || speed == .automatic || (speed == .balanced && flag("adaptiveOCR", true))) && (ThermalPerformancePolicy.automaticPressure(for: ProcessInfo.processInfo.thermalState) || (busy && queued != nil)),
                           selectiveSpeculation: flag("selectiveSpeculation", true), speculationConfidence: num("speculationConfidence", 0.85),
                           detailCeiling: (ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical || (extFreeMB > 0 && extFreeMB < 12)) ? maxEdge : 2400,
                           confirmationBurst: !flag("coolMode", false),
                           appInterfaceVisible: appInterfaceVisible && flag("suppressOwnInterface", true),
                           focusedCaptionOCR: activeTranslationSystem != .legacy && flag("subtitleTracking", true),
                           strictCaptionIdentity: activeTranslationSystem != .legacy,
                           pixelConfirmation: flag("pixelConfirmation", true),
                           eventDrivenOCR: flag("eventDrivenOCR", true),
                           fastOCR: flag("fastOCR", false),
                           cjkSingleCharacters: flag("cjkSingleCharacters", true),
                           independentHeartbeat: TranslationHotPathAB.independentHeartbeat ? true : nil))
    }

    // MARK: PiP
    /// Starts the PiP window (retrying while iOS gets ready), then calls `done`.
    /// Set when "Open the floating window when capture starts" could not run because the app was not active (E17).
    var autoOpenSkipped = false

    /// Invalidate suspended work before changing language, capture state, or settings.
    private func invalidatePending() {
        if activeTranslationSystem != .legacy {
            modelReadiness.sessions = modelReadiness.sessions == .complete ? .idle : .pending
            modelReadiness.execution = modelReadiness.completedAt == nil ? .pending : .idle
            modelReadiness.activeSince = nil
            modelReadiness.explanation = "Current caption work was invalidated. Retained session handles need rechecking; a previous completed model run remains historical evidence."
        } else if modelReadiness.execution == .working {
            modelReadiness.execution = .pending; modelReadiness.activeSince = nil
            modelReadiness.explanation = "Previous work was interrupted; waiting for the current request."
        }
        modeWorkActivity = nil; modeActivityCaption = nil; modeActivitySelected = false
        preparationTicket = UUID()
        // A new capture/mode context deserves a fresh session readiness check.
        // The five-second retry throttle applies only within one unchanged context.
        lastModePreparationPair = ""
        lastModePreparationAt = .distantPast
        interruptWarmupForLiveWork()
        modeSessionID = UUID(); modeLastIdentity = ""; modePlans.removeAll(); modeMemoryOrigins.removeAll()
        modePreparedPlans.clear(); preparedUnits.clear()
        modeFingerprintDigests.removeAll(keepingCapacity: true)
        modeModelTimings.removeAll()
        if modeDiagnosticEpochs.count >= 64 { modeDiagnosticEpochs.removeAll() }
        modeDiagnosticEpochs[modeSessionID] = diag.started
        modeCoordinator.reset(); modeService.reset(preserveIdleSessions: true)
        contextRevision += 1
        generation += 1
        cancelDrain(preemptSpeculation: true)
        speculativeSessions.reset()
        deferredConfirmedPacket = nil
        confirmedHandoffDeadlineTask?.cancel()
        confirmedHandoffDeadlineTask = nil
        activeCandidateID = nil; activeCandidateText = ""
        movieTextFocus.reset()
        activeCandidateConfirmed = false; activeCandidatePresented = false
        cancelPresentation()
        queued = nil
        queuedPacket = nil
        queuedTs = Date().timeIntervalSince1970
        specQueued = nil
        lastHandled = ""
        lastSpecText = ""
        clearTask?.cancel()
        clearTask = nil
    }

    func toggleFrozenOutput() {
        frozen.toggle()
        invalidatePending()
        if !frozen, !latestBlocks.isEmpty { enqueue(latestBlocks) }
        status = frozen ? "Floating window frozen – capture continues" : "Live again"
    }

    func beginWorkspace() {
        manualMode = true
        lockedLang = nil; languageRouter.reset()
        clearOutput()
        invalidatePending()
        syncConfig()
    }

    func endWorkspace() {
        manualMode = false
        invalidatePending()
        syncConfig()
        if !paused { enqueue(latestBlocks) }
    }

    func translateText(_ text: String) {
        guard manualMode else { return }
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12000))
        guard !trimmed.isEmpty else { toast("Enter some text first"); return }
        frozen = false
        invalidatePending()
        queuedTs = Date().timeIntervalSince1970
        queuedPacket = nil
        enqueue([trimmed])
    }

    func clearOutput() {
        invalidatePending()
        showing = false; original = ""; translated = ""
        renderedGrams = placeholderGrams; sourceGrams = []
        pip.render(original: "", translated: "Listening…", showOriginal: false)
    }

    func eraseHistory() {
        undoHistory = nil
        history = []
        historyWriter.cancel()      // the empty list must not be written again after the keys are removed
        ud.removeObject(forKey: "historyData")
        ud.removeObject(forKey: "screenlingo.history.v1")
    }

    func timingSettingsChanged() {
        invalidatePending()
        pip.configureHeartbeat()
        syncConfig()
        if !paused, !manualMode { enqueue(latestBlocks) }
    }

    // MARK: History storage
    func saveHistory() {
        // Private translations are excluded when history is populated in show().
        // Explicit edits/deletions of existing history must still survive restart.
        guard flag("saveHistory", true) else { return }
        let started = ProcessInfo.processInfo.systemUptime
        let days = int("historyRetentionDays", 0)
        let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 86400) : Date.distantPast
        let retained = HistoryPolicy.trimmed(history.filter { $0.starred || $0.date >= cutoff }, capacity: historyCapacity)
        if let d = try? JSONEncoder().encode(retained) { ud.set(d, forKey: "historyData") }
        diag.noteHistorySave(ms: (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }

    func applyHistoryRetention() {
        let days = int("historyRetentionDays", 0)
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let kept = history.filter { $0.starred || $0.date >= cutoff }
        if kept.count != history.count { history = kept }     // no write when nothing expired (E15)
    }

    // MARK: Packets from the extension
    private func handle(_ incoming: Packet) {
        let p = incoming
        let now = Date()
        if p.kind == "stopped" {
            guard captureIdentity.stop(p.captureSessionID) else { return }
            captureReadiness.receive(frames: p.frames, session: p.captureSessionID, stopped: true, at: ProcessInfo.processInfo.systemUptime)
            publishCaptureStatus()
            captureAlive = false; lastPacketDate = .distantPast
            invalidatePending()
            diag.noteRuntimeState("heartbeat_timeout")
            diag.pauseRun(reason: "captureStopped", frames: frames)
            return
        }
        let captureAdmission = captureIdentity.admit(p.captureSessionID)
        guard captureAdmission != .rejected else { return }
        captureReadiness.receive(frames: p.frames, session: p.captureSessionID, stopped: false, at: ProcessInfo.processInfo.systemUptime)
        publishCaptureStatus()
        if captureAdmission == .newSession, captureAlive { invalidatePending(); captureAlive = false; diag.pauseRun(reason: "newCaptureSession", frames: frames) }
        let wasAlive = captureAlive
        lastPacketDate = now
        if !captureAlive { captureAlive = true }
        if frames != p.frames { frames = p.frames }
        if extensionVersion != p.version { extensionVersion = p.version }
        if let t = p.ocrMs, t != ocrMs { ocrMs = t }
        if let m = p.memFreeMB, m != extFreeMB { extFreeMB = m }
        if p.kind != "ocr" || p.rev == nil || p.rev == rotRev {
            let transit = p.sentMonotonic.map { max(0, ProcessInfo.processInfo.systemUptime - $0) * 1000 }
                ?? p.ts.map { max(0, now.timeIntervalSince1970 - $0) * 1000 }
            diag.onPacket(p, transport: transit)
        }

        if !wasAlive {
            activateTranslationSystem()
            diag.beginRun(sameBroadcast: captureAdmission == .current, frames: p.frames); refreshModeDiagnosticEpoch() // v2.0.0 build 84: one Test Run per broadcast, after the active mode is known
            interruptWarmupForLiveWork()
            startupWarmupTask?.cancel() // Live capture takes priority over idle prewarming.
            startupWarmupTask = nil
            idleValidationTask?.cancel()
            idleValidationTask = nil
            sessionStarted = now; limitBase = now
            sessionTranslations = 0; sessionCharacters = 0
            diag.log("Capture connected (extension v\(p.version))")
            diag.noteRuntimeState("capture_connected")
            lastTextDate = now
            syncConfig()
            // Do not launch a second synthetic model job as capture starts.
            // Startup preparation runs before capture; live text owns first use.
            // Capture just started: make sure the floating window is up too.
            // 2.2.1 (E17): the window opens only while ScreenLingo is still in front. When the person has already
            // switched to the video app the skip is recorded, and the window opens once when the app is active again.
            if flag("autoOpenPiP", true), !pip.isActive {
                if UIApplication.shared.applicationState == .active { startPiP() }
                else {
                    autoOpenSkipped = true
                    diag.noteRuntimeState("pip_auto_open_skipped_not_active")
                }
            }
        }
        if let orientation = p.orient {
            if let previous = lastCaptureOrientation, previous != orientation, frameRotMode == "auto" {
                rotationSettingChanged()
                diag.log("Capture orientation changed; restarting bounded calibration")
            }
            lastCaptureOrientation = orientation
        }
        if p.kind == "ping" { syncConfig(); return }          // keeps the extension's settings fresh
        handleContent(p, receivedAt: now)
    }

    /// Local handoffs never masquerade as fresh transport packets, extend the
    /// capture heartbeat, or count OCR/confirmation work twice.
    func handleContent(_ incoming: Packet, receivedAt: Date, replayed: Bool = false) {
        var p = incoming
        let now = Date()
        if replayed {
            guard captureAlive, now.timeIntervalSince(receivedAt) >= 0,
                  now.timeIntervalSince(receivedAt) < 1.2 else {
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                    stage: "stability", reason: "handoff_expired")
                return
            }
            diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                stage: "stability", reason: "handoff_replayed")
        }
        if paused || manualMode || (appInterfaceVisible && flag("suppressOwnInterface", true)) { return }
        if let rev = p.rev, rev != rotRev { return }
        if p.kind == "clear" {
            deferredConfirmedPacket = nil
            confirmedHandoffDeadlineTask?.cancel()
            confirmedHandoffDeadlineTask = nil
            invalidatePending(); latestBlocks = []; handleClear(); return
        }
        guard p.kind == "ocr" else { return }
        if diag.detailedCollection && !replayed {
            diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                                      stage: "frame_arrival", reason: "accepted")
        }
        extractingConfirmedPacket = p.stable != false
        let candidateTexts = extractTexts(p.lines, count: p.stable != false && !replayed)
        guard !candidateTexts.isEmpty else {
            if diag.detailedCollection {
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                                          stage: "ocr_filtering", reason: "rejected_empty")
            }
            return
        }
        // Both Legacy and new modes must count accepted confirmed packets.
        // Do this before dispatch, without counting a local replay twice.
        if p.stable != false && !replayed && diag.enabled { diag.s.confirmedCandidatePackets += 1 }
        if activeTranslationSystem != .legacy {
            handleModeCaption(candidateTexts, packet: p)
            return
        }
        let candidateText = candidateTexts.map(TextSim.norm).joined(separator: "\n")
        // Admission must precede generation changes, cancellation and continuity
        // accounting. Rejected fragments never become active confirmed work.
        if SubtitleAcquisitionPolicy.rejectsDisplayedFragment(confirmed: p.stable != false,
            text: candidateTexts.joined(separator: "\n"), displayed: original,
            age: Date().timeIntervalSince(lastShowDate)) {
            if diag.detailedCollection {
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                    stage: "duplicate_detection", reason: "rejected_recent_fragment")
            }
            return
        }
        let equivalentActiveCaption = SubtitleAcquisitionPolicy.isSameUnpresentedCaption(
            activeConfirmed: activeCandidateConfirmed,
            activePresented: activeCandidatePresented,
            previousBlocks: latestBlocks,
            incomingBlocks: candidateTexts)
        let handoffDelay = SubtitlePerformancePolicy.confirmedHandoffDelay(
            age: now.timeIntervalSince(activeCandidateConfirmedAt))
        if !replayed, handoffDelay > 0, flag("protectConfirmedPresentation", true),
           flag("steadyCaptions", true), p.candidateID != nil,
           activeCandidateText != candidateText,
           activeCandidateConfirmed, !activeCandidatePresented,
           p.stable != false, busy || queued != nil || waitingToDisplay,
           !equivalentActiveCaption {
            // One-slot, latest-wins handoff. The existing result gets a bounded
            // completion opportunity; replacement never renews the deadline.
            deferredConfirmedPacket = p
            deferredConfirmedReceivedAt = receivedAt
            // Keep the first deadline when the one-slot replacement changes.
            // Repeated packets cannot renew the grace period indefinitely.
            if confirmedHandoffDeadlineTask == nil {
                confirmedHandoffDeadlineTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(handoffDelay))
                    guard let self, !Task.isCancelled,
                          let pending = self.deferredConfirmedPacket else { return }
                    self.deferredConfirmedPacket = nil
                    self.confirmedHandoffDeadlineTask = nil
                    // Replay once, bypassing handoff protection to prevent a loop.
                    self.handleContent(pending, receivedAt: self.deferredConfirmedReceivedAt, replayed: true)
                }
            }
            if diag.enabled { diag.s.confirmedHandoffDeferred += 1 }
            diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                stage: "stability", reason: "confirmed_handoff_deferred")
            return
        }
        if flag("steadyCaptions", true), let candidate = p.candidateID,
           activeCandidateText != candidateText && !equivalentActiveCaption {
            let confirmed = p.stable != false
            // Tentative OCR jitter must never cancel a previously confirmed subtitle.
            // Its confirmed replacement can still supersede outdated work.
            guard SubtitleAcquisitionPolicy.shouldSupersedeActive(
                activeConfirmed: activeCandidateConfirmed, activePresented: activeCandidatePresented,
                incomingConfirmed: confirmed) else {
                if diag.enabled { diag.s.deferredEarlyCandidates += 1 }
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                    stage: "stability", reason: "deferred_early_candidate")
                return
            }
            if let previous = activeCandidateID {
                diag.trace(previous, stage: "superseded", detail: "Confirmed replacement or early candidate")
                if activeCandidateConfirmed && !activeCandidatePresented && diag.enabled {
                    diag.s.supersededUnpresentedConfirmed += 1
                    // 2.3.0: measurement only. Whether the replaced caption's translation had started, and its age.
                    diag.noteConfirmedSupersession(workStarted: busy && activeQueueOwner == .confirmed,
                        ageMs: max(0, now.timeIntervalSince(activeCandidateConfirmedAt) * 1000))
                }
            }
            activeCandidateID = candidate; activeCandidateText = candidateText
            activeCandidateConfirmed = confirmed; activeCandidatePresented = false
            activeCandidateConfirmedAt = confirmed ? now : .distantPast
            deferredConfirmedPacket = nil
            confirmedHandoffDeadlineTask?.cancel()
            confirmedHandoffDeadlineTask = nil
            clearTask?.cancel(); clearTask = nil
            generation += 1
            cancelPresentation()
            queued = nil; specQueued = nil
            let shared = sharedInFlightUnits(candidateTexts)
            if shared == 0 { cancelDrain(preemptSpeculation: confirmed) }
            else if activeQueueOwner == .confirmed { diag.noteSharedModelUnits(shared, confirmed: true) }
        } else if p.stable != false {
            if !activeCandidateConfirmed { activeCandidateConfirmedAt = now }
            activeCandidateConfirmed = true
            if equivalentActiveCaption && activeCandidateText != candidateText {
                diag.notePipelineDecision(candidate: activeCandidateID,
                    frameIndex: p.frames, stage: "duplicate_detection",
                    reason: "preserved_confirmed_work")
            }
        }
        // Overlay-only OCR changes must not supersede the same filtered subtitle.
        if flag("steadyCaptions", true), p.candidateID != nil { p.candidateID = activeCandidateID }
        if p.stable == false, let firstSeen = p.firstSeenAt {
            diag.trace(p.candidateID, stage: "first OCR", detail: "Capture first sighting",
                       at: Date(timeIntervalSince1970: firstSeen), frameIndex: p.frames)
        }
        diag.trace(p.candidateID, stage: p.stable == false ? "seen" : "confirmed", detail: p.confirmationReason ?? "legacy confirmation")
        if let candidate = p.candidateID {
            let first = p.firstSeenAt ?? p.ts ?? Date().timeIntervalSince1970
            diag.registerLegacyModeCaption(session: modeSessionID, caption: candidate,
                source: sourceCode == "auto" ? (detectedLang == "–" ? "auto" : detectedLang) : sourceCode,
                target: targetCode,
                fingerprint: SHA256.hash(data: Data(ConfirmedSourceIdentity.normalize(candidateTexts.joined(separator: "\n")).utf8)).map { String(format: "%02x", $0) }.joined(),
                firstOCR: ProcessInfo.processInfo.systemUptime - max(0, Date().timeIntervalSince1970 - first),
                confirmed: p.stable != false)
        }
        // First, unconfirmed sighting: translate quietly now so the result is ready the moment the text is confirmed.
        if p.stable == false {
            if speculationAllowed && flag("translateAhead", true) {
                let minimumSpecConfidence = flag("coolMode", false) ?
                    max(0.95, num("speculationConfidence", 0.85)) : num("speculationConfidence", 0.85)
                let credible = !flag("selectiveSpeculation", true) ||
                    SpeculationPolicy.credible(lines: p.lines, threshold: minimumSpecConfidence)
                #if SCREENLINGO_REFERENCE_LEGACY_ADMISSION
                let admittedByHistory = ram.speculationWindow.allowsOpportunity(
                    enabled: flag("adaptiveSpeculation", true))
                #else
                // A low-confidence rejected OCR packet is not an opportunity to
                // send model work. Do not consume the bounded governor's probe
                // budget on one. The user-defined threshold is unchanged.
                if !credible {
                    if diag.enabled { diag.s.specSkipped += 1; diag.s.legacyLowConfidenceSkips += 1 }
                    diag.notePipelineDecision(candidate: p.candidateID,
                        frameIndex: p.frames, stage: "stability",
                        reason: "legacy_speculation_low_confidence")
                    return
                }
                let highConfidence = SpeculationPolicy.credible(
                    lines: p.lines, threshold: max(0.95, minimumSpecConfidence))
                let admittedByHistory = ram.speculationWindow.allowsCredibleOpportunity(
                    enabled: flag("adaptiveSpeculation", true), strongCandidate: highConfidence)
                #endif
                guard admittedByHistory else {
                    if diag.enabled {
                        diag.s.adaptiveSpeculationSkipped += 1
                        if ram.speculationWindow.savedMemoryDominant { diag.s.legacyAdaptiveSavedSkips += 1 }
                        else { diag.s.legacyAdaptiveLowYieldSkips += 1 }
                    }
                    if ram.speculationWindow.savedMemoryDominant { diag.noteMemoryAwareSpeculationSkip() }
                    diag.notePipelineDecision(candidate: p.candidateID,
                        frameIndex: p.frames, stage: "stability",
                        reason: ram.speculationWindow.savedMemoryDominant ?
                            "legacy_speculation_saved_memory_backoff" : "legacy_speculation_low_yield_backoff")
                    return
                }
                guard credible else {
                    if diag.enabled {
                        diag.s.specSkipped += 1
                        diag.s.legacyLowConfidenceSkips += 1
                    }
                    if diag.detailedCollection {
                        diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                            stage: "stability", reason: "legacy_speculation_low_confidence")
                    }
                    return
                }
                specPacket = p
                speculate(candidateTexts)
            }
            return
        }
        ocrCount += 1
        lastRaw = String(p.lines.map(\.t).joined(separator: " ").prefix(160))

        // Is text arriving upside down? Votes only count packets made with the current rotation.
        let revision = rotRev
        updateOrderVote(removeOwnOutput(p.lines))
        guard revision == rotRev else {
            if diag.detailedCollection {
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                                          stage: "rotation", reason: "rejected_revision")
            }
            return
        }

        let texts = candidateTexts
        latestBlocks = texts
        clearTask?.cancel()
        clearTask = nil
        queuedTs = p.firstSeenAt ?? p.ts ?? now.timeIntervalSince1970
        queuedPacket = p
        enqueue(texts.map { String($0.prefix(400)) })
    }

    /// Turns raw OCR lines into the text blocks worth translating (area, rules, own window, blocks, noise…).
    /// `count` is false for early sightings so the statistics are not counted twice.
    /// 2.2.1 (E13): a one-character CJK line is translated only when it came from a confirmed packet (not the early
    /// sighting) and the Advanced setting is on.
    var extractingConfirmedPacket = false
    private func extractTexts(_ lines: [OCRLine], count: Bool) -> [String] {
        let range = area.range()
        let minH = num("minTextH", 0)
        let ignore = list("ignoreList", lower: true)
        var cand: [OCRLine] = []
        for l in lines {
            if count && diag.enabled { diag.s.linesIn += 1 }
            if !range.contains(l.y) { if count && diag.enabled { diag.s.dropArea += 1 }; continue }
            if l.h < minH { if count && diag.enabled { diag.s.dropSmall += 1 }; continue }
            if ignore.contains(where: { l.t.lowercased().contains($0) }) { if count && diag.enabled { diag.s.dropIgnore += 1 }; continue }
            cand.append(l)
        }
        let n1 = cand.count
        cand = removeOwnOutput(cand)
        if count && diag.enabled { diag.s.dropSelf += n1 - cand.count }
        var allBlocks = makeBlocks(cand)
        if flag("deduplicateCopies", true) {
            var regions = subtitleRegions
            allBlocks = regions.deduplicated(allBlocks)
            if count { subtitleRegions = regions }
        }
        if count && diag.enabled { diag.s.blocksIn += allBlocks.count }
        let blocks = selectBlocks(allBlocks, diagnosticCount: count)
        if count && diag.enabled { diag.s.blocksKept += blocks.count }
        var texts: [String] = []
        for b in blocks {
            let t = blockText(b)
            let singleCJK = allowsSingleCJK(t)
            if TextSim.norm(t).count < 2 && !singleCJK { continue }
            if flag("dropNoise", true) && TextIntel.isNoise(t, allowSingleCJK: singleCJK) { if count && diag.enabled { diag.s.dropNoise += 1 }; continue }
            if isTargetLanguage(t) { if count && diag.enabled { diag.s.dropTarget += b.count }; continue }
            texts.append(t)
        }
        return dedupe(texts).map { String($0.prefix(400)) }
    }

    /// Queues a quiet, low-priority translation that only fills the cache.
    private func speculate(_ blocks: [String]) {
        guard speculationAllowed else { return }
        // Confirmed translations own the model. A changing subtitle should not
        // multiply low-priority speculative work while a confirmed job is busy.
        guard !busy, queued == nil else {
            if diag.enabled {
                diag.s.specSkipped += 1
                diag.s.legacyBusySpeculationSkips += 1
            }
            return
        }
        let thermal = ProcessInfo.processInfo.thermalState
        if ProcessInfo.processInfo.isLowPowerModeEnabled || thermal == .serious || thermal == .critical { return }
        let joined = blocks.joined(separator: "\n")
        guard !frozen, joined != lastHandled, joined != lastSpecText else {
            if diag.enabled { diag.s.legacyDuplicateSpeculationSkips += 1 }
            return
        }
        if flag("selectiveSpeculation", true), TextSim.similar(joined, lastSpecText, 0.97) {
            if diag.enabled {
                diag.s.specSkipped += 1
                diag.s.legacyDuplicateSpeculationSkips += 1
            }
            return
        }
        lastSpecText = joined
        specQueued = blocks
        startDrain()
    }

    // MARK: Reading-order calibration
    /// Reads each text block forwards and backwards; if backwards reads more naturally, the frame is upside down.
    private func updateOrderVote(_ lines: [OCRLine]) {
        guard !calibrated || flag("continuousRotation", false) else { return }
        var diff = 0.0
        for b in makeBlocks(lines) where b.count >= 2 {
            let fwd = readingOrder(b).map(\.t)
            diff += TextIntel.orderScore(fwd) - TextIntel.orderScore(Array(fwd.reversed()))
        }
        guard diff != 0 else { return }
        orderVote = max(-30, min(30, orderVote * 0.8 + diff))
        votesSinceChange += 1
        if diag.enabled { diag.s.orderVote = orderVote }
        guard frameRotMode == "auto" else { return }
        if RotationBudget.sufficientEvidence(vote: orderVote, samples: votesSinceChange) {
            if calibrated && flag("continuousRotation", false) { rotationBudget.reset() }
            guard let nextRotation = rotationBudget.next() else { return }
            autoRot = nextRotation
            rotRev += 1
            invalidatePending()
            orderVote = 0; votesSinceChange = 0; calibrated = false
            if diag.enabled { diag.s.calibrated = false }
            if rotationBudget.exhausted {
                calibrated = true
                if diag.enabled { diag.s.calibrated = false }
                diag.log("Rotation probes exhausted; holding capture orientation until device orientation or settings change")
            } else { diag.log("Reading order looks reversed → trying rotation \(autoRot * 90)°") }
            syncConfig()
        } else if orderVote > 4 && !calibrated {
            calibrated = true
            if diag.enabled { diag.s.calibrated = true }
            diag.log("Reading order OK at rotation \(autoRot * 90)°")
        }
    }

    /// Optional active-text prioritization works with every preset category.
    private func selectBlocks(_ blocks: [[OCRLine]], diagnosticCount: Bool) -> [[OCRLine]] {
        guard !blocks.isEmpty else { return [] }
        let maxH = blocks.map { blockHeight($0) }.max() ?? 0
        var kept = blocks
        if flag("activeTextFocus", true) {
            let beforeHeightFilter = kept.count
            // Tiny dialogue must not be excluded because a persistent label uses a larger font.
            kept = blocks.filter { blockHeight($0) >= max(0.006, maxH * 0.20) }
            if kept.isEmpty { kept = blocks }
            // Aligned visible lyrics are one reading group, even with separate OCR boxes.
            let sorted = kept.sorted { ($0.first?.y ?? 0) > ($1.first?.y ?? 0) }
            var groups: [[[OCRLine]]] = []
            for block in sorted {
                let x = block.map(\.x).reduce(0, +) / Double(block.count)
                let y = block.map(\.y).reduce(0, +) / Double(block.count)
                if let i = groups.firstIndex(where: { group in
                    guard let previous = group.last else { return false }
                    let px = previous.map(\.x).reduce(0, +) / Double(previous.count)
                    let py = previous.map(\.y).reduce(0, +) / Double(previous.count)
                    return abs(px - x) <= 0.12 && abs(py - y) <= max(0.12, blockHeight(block) * 4.2)
                }) { groups[i].append(block) } else { groups.append([block]) }
            }
            let summaries = groups.map { group -> MovieTextGroup in
                let lines = group.flatMap { $0 }
                let x = lines.reduce(0.0) { $0 + $1.x } / Double(max(1, lines.count))
                let y = lines.reduce(0.0) { $0 + $1.y } / Double(max(1, lines.count))
                return MovieTextGroup(text: lines.map(\.t).joined(separator: " "), x: x, y: y,
                    weight: group.reduce(0.0) { $0 + blockWeight($1) })
            }
            // A label becomes background only after repeated, spatially stable OCR.
            // A lone held subtitle/lyrics group remains eligible for translation.
            let strongest = summaries.indices.max(by: { summaries[$0].weight < summaries[$1].weight })
            let chosen = movieTextFocus.preferredIndex(in: summaries, at: Date().timeIntervalSince1970)
            diag.noteMovieSelection(groups: groups.count,
                filteredSmall: beforeHeightFilter - kept.count,
                temporalOverride: chosen != nil && chosen != strongest,
                confirmed: diagnosticCount)
            if let chosen {
                kept = groups[chosen]
                if flag("preserveRelatedMovieGroups", false) {
                    // Opt-in lyrics mode: keep only nearby aligned secondary groups.
                    let focus = summaries[chosen]
                    for index in groups.indices where index != chosen {
                        let other = summaries[index]
                        let aligned = abs(focus.x - other.x) <= 0.10
                        let close = abs(focus.y - other.y) <= 0.24
                        let substantial = other.weight >= focus.weight * 0.26
                        if aligned && close && substantial { kept.append(contentsOf: groups[index]) }
                    }
                }
            } else { kept = [] }
        } else if area == .smart {
            kept = blocks.filter { blockHeight($0) >= maxH * 0.4 }
        }
        kept = Array(kept.sorted { blockWeight($0) > blockWeight($1) }.prefix(6))
        func top(_ b: [OCRLine]) -> Double { b.map { $0.y + $0.h / 2 }.max() ?? 0 }
        func left(_ b: [OCRLine]) -> Double { b.map { $0.x - ($0.w ?? 0) / 2 }.min() ?? 0 }
        return kept.sorted { a, b in
            let ra = Int((1 - top(a)) * 14), rb = Int((1 - top(b)) * 14)
            return ra != rb ? ra < rb : left(a) < left(b)
        }
    }

    private func enqueue(_ blocks: [String]) {
        if activeTranslationSystem != .legacy {
            guard !blocks.isEmpty else { return }
            var packet = Packet(kind: "ocr", version: AppVersion.full, frames: frames, lines: [])
            packet.candidateID = "manual-\(UUID().uuidString)"; packet.stable = true
            packet.firstSeenAt = Date().timeIntervalSince1970
            handleModeCaption(blocks, packet: packet)
            return
        }
        let joined = blocks.joined(separator: "\n")
        guard !blocks.isEmpty, joined != lastHandled else { return }
        if PipelineSafety.isDuplicate(blocks, previous: lastHandled.components(separatedBy: "\n")) { return }
        generation += 1
        cancelPresentation()
        lastHandled = joined
        if queued != nil { diag.noteQueueReplacement() }
        // Confirmed OCR supersedes unstarted speculation; the currently
        // executing model retains its physical session until it returns.
        if SubtitlePerformancePolicy.discardPendingSpeculation(
            confirmedIncoming: true, speculativePending: specQueued != nil) {
            specQueued = nil
            diag.noteModelState("legacy_queued_speculation_superseded")
        }
        queued = blocks
        queuedAt = Date()
        queuedWaitOwner = busy ? activeQueueOwner : .scheduling
        if presentQueuedFromRAMIfComplete() { return }
        if SubtitlePerformancePolicy.preemptSpeculation(activeText: currentSpeculativeText, confirmedText: joined) {
            // Different input cannot supply an exact whole-caption reuse result.
            // Cancellation unwinds the single drain before confirmed work starts.
            let shared = sharedInFlightUnits(blocks)
            if shared == 0 {
                if diag.enabled { diag.s.specPreemptionRequested += 1 }
                cancelDrain(preemptSpeculation: true)
                detachCancelledSpeculationIfEnabled()
            }
            else { diag.noteSharedModelUnits(shared) }
        } else if currentSpeculativeText == joined {
            if diag.enabled { diag.s.specMatchingConfirmation += 1 }
            diag.noteLegacySpeculationInFlightMatch(candidate: queuedPacket?.candidateID)
        }
        startDrain()
    }

    /// 2.2.3 (L2). With the switch on (iOS 26 direct sessions only) the confirmed caption starts now instead of
    /// after the cancelled speculative call returns. The confirmed call uses the direct session; the speculative call
    /// owns its own disposable session, so the two never share a session. The old drain exits on resume.
    private func detachCancelledSpeculationIfEnabled() {
        guard TranslationHotPathAB.legacyConfirmedOwnLane, activeTranslationSystem == .legacy,
              busy, activeQueueOwner == .speculative else { return }
        guard #available(iOS 26.0, *) else { return }
        drainEpoch += 1
        detachedSpeculationAt = Date()
        busy = false
        drainTask = nil
        activeQueueOwner = .scheduling
        currentSpeculativeText = nil
        diag.noteModelState("legacy_confirmed_own_lane")
    }

    @discardableResult
    private func presentQueuedFromRAMIfComplete() -> Bool {
        guard let blocks = queued else { return false }
        let joined = blocks.joined(separator: "\n")
        // A complete exact RAM result needs no model lane. Never bypass OCR
        // confirmation, generation checks or the presentation policy.
        let cacheProbeStarted = Date()
        // Exact confirmed text with an explicitly selected source language can
        // use the complete RAM caption even when the model lane is idle.
        // Previously this shortcut was restricted to a busy lane, forcing an
        // unnecessary full processing pass for the same reusable result.
        // Automatic source selection still runs through language detection.
        if sourceCode != "auto", !bypassMemory, memoryTestMode.allowsReuse,
           let key = ExactCaptionIdentity.key(blocks: blocks, source: sourceCode,
                                              target: targetCode, rules: memoryRuleToken),
           let ready = cachedCaption(blocks, identity: key) {
            queued = nil
            if diag.enabled { diag.s.translations += 1; diag.s.chars += blocks.joined().count }
            translateMs = Date().timeIntervalSince(cacheProbeStarted) * 1000
            languageFailures = 0
            diag.recordQueueWait(owner: queuedWaitOwner,
                durationMs: max(0, cacheProbeStarted.timeIntervalSince(queuedAt) * 1000),
                candidate: queuedPacket?.candidateID)
            status = "\(sourceCode) → \(targetCode) ✓"
            if memoryTestMode == .temporaryMemory { diag.noteTemporaryReuse(count: ready.sentences) }
            let now = Date()
            let timing = PresentationTiming(packet: queuedPacket, firstSeen: queuedTs,
                queuedAt: queuedAt, processingAt: cacheProbeStarted, processingMs: translateMs,
                savedRequests: 0, readyAt: now)
            diag.recordTranslate(ms: translateMs, sentences: ready.sentences, from: sourceCode,
                                 to: targetCode, preview: ready.translated)
            diag.trace(queuedPacket?.candidateID, stage: "ready", detail: "Complete exact RAM caption")
            schedulePresentation(joined, ready.translated, generation: generation,
                                 context: contextRevision, timing: timing)
            return true
        }
        return false
    }

    private func handleClear() {
        guard !frozen, flag("autoClear", true), showing, clearTask == nil else { return }
        let hold = num("clearHold", 1.0)
        if hold <= 0 { performClear(); return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled else { return }
            self?.performClear()
        }
    }

    /// Swift Task cancellation alone may leave Apple's model request running.
    /// Only the disposable speculative session receives explicit cancellation;
    /// confirmed work retains its own warm session and the drain still awaits unwind.
    private func cancelDrain(preemptSpeculation: Bool) {
        drainTask?.cancel()
        if preemptSpeculation, speculativeSessions.cancelActive() {
            diag.noteModelState("speculative_stop_requested")
        }
    }

    /// 2.2.3 (L2): bumped when a cancelled speculative drain is detached so a confirmed drain can start at once.
    /// A drain that finds its epoch changed must not touch shared drain state. Never changes with the switch off.
    private var drainEpoch = 0
    private var detachedSpeculationAt: Date?

    private func startDrain() {
        guard !busy, drainTask == nil, queued != nil || specQueued != nil else { return }
        interruptWarmupForLiveWork()
        drainTask = Task(priority: .userInitiated) { await drain() }
    }

    private func drain() async {
        guard !busy else { return }
        busy = true
        let epoch = drainEpoch
        defer {
            if epoch == drainEpoch {
                busy = false
                activeQueueOwner = .scheduling
                drainTask = nil
                replayDeferredConfirmedIfPossible()
                startDrain()
            }
        }
        while queued != nil || specQueued != nil {
            guard !Task.isCancelled, epoch == drainEpoch else { return }
            if deferredConfirmedPacket != nil, activeCandidatePresented, !waitingToDisplay { return }
            if let b = queued {
                queued = nil
                currentTs = queuedTs; currentPacket = queuedPacket; currentQueuedAt = queuedAt
                diag.recordQueueWait(owner: queuedWaitOwner,
                    durationMs: max(0, Date().timeIntervalSince(queuedAt) * 1000),
                    candidate: queuedPacket?.candidateID)
                activeQueueOwner = .confirmed
                await process(b, display: true)
            } else if let sp = specQueued {
                specQueued = nil
                currentPacket = specPacket
                if speculationAllowed {
                    activeQueueOwner = .speculative
                    currentSpeculativeText = sp.joined(separator: "\n")
                    await process(sp, display: false)
                    if epoch == drainEpoch { currentSpeculativeText = nil }
                    else if let at = detachedSpeculationAt {
                        diag.noteModelState("legacy_detached_speculation_released",
                                            durationMs: max(0, Date().timeIntervalSince(at) * 1000))
                    }
                }
            }
        }
    }

    /// Keep a completed unit, never a partial sentence. The old caption is not
    /// presented or persisted; a queued replacement must assemble every unit.
    private func retainCompletedModelUnit(key: String, value: String,
        context: Int, rules: String, destination: String, mode: TranslationTestMode,
        bank: TranslationRAMBank, confirmed: Bool, speculativeID: UInt64?, epoch: Date) {
        guard context == contextRevision, mode == memoryTestMode, bank === ram,
              mode.allowsReuse, !bypassMemory, rules == memoryRuleToken,
              destination == targetCode,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bank.values[key] == nil else { return }
        bank.values[key] = value
        bank.savedKeys.remove(key)
        if !confirmed {
            if bank.specKeys.insert(key).inserted, diag.started == epoch { diag.noteSpeculativeUnit("retained") }
            if let speculativeID { bank.speculativeOrigins[key] = speculativeID }
        }
        touchCache(key)
        trimCache()
        if diag.started == epoch {
            if confirmed { diag.noteCompletedWorkRecovery(1) }
            else if diag.enabled { diag.s.specRetainedUnits += 1 }
        }
        // A needed result may arrive before unrelated units in the old batch.
        // This uses the existing complete-caption and presentation safeguards.
        presentQueuedFromRAMIfComplete()
    }

    private var preparedUnits = ExactPlanReuseCache<PreparedUnitIdentity, [PreparedSourceUnit]>(capacity: 12)

    /// Shared by real processing and the in-flight exact-key overlap check.
    private func preparedSourceUnits(_ text: String, language: String, slang: Bool,
                                     speakers: Bool, protected: [String]) -> [PreparedSourceUnit] {
        let key = PreparedUnitIdentity(text: text, language: language, slang: slang,
                                       speakers: speakers, protected: protected, context: contextRevision)
        let reuseEnabled = activeTranslationSystem != .legacy ||
            TranslationHotPathAB.reuseLegacyPreparedUnits
        if reuseEnabled, let cached = preparedUnits.lookup(key) { return cached }
        let expanded = slang ? TextIntel.expandSlang(text, lang: language) : text
        let parts = speakers ? TextIntel.splitDialogue(expanded) : [(label: String?.none, text: expanded)]
        let output = parts.map { part in
            let tokens = TextIntel.protect(part.text, words: protected)
            return PreparedSourceUnit(label: part.label, sentences: splitSentences(tokens.text), tokens: tokens.tokens)
        }
        preparedUnits.insert(output, for: key)
        return output
    }

    /// Synchronous and RAM-only: safe while the model lane is awaiting unrelated work.
    /// Probe every current unit before consuming provenance or confirming any result.
    private func cachedCaption(_ blocks: [String], identity: String) -> ExactCaptionResult? {
        if let ready = ram.captions[identity] {
            diag.noteExactCaptionReuse()
            return ready
        }
        guard sourceCode != "auto", memoryTestMode.allowsReuse, !bypassMemory else { return nil }
        let source = Locale.Language(identifier: sourceCode)
        guard source.languageCode != Locale.Language(identifier: targetCode).languageCode else { return nil }
        let id = source.minimalIdentifier
        let rules = memoryRuleToken
        let never = list("neverTranslate", lower: false)
        let fixes = pairs("sourceFixes")
        var units: [[CaptionTranslationUnit]] = []
        var hits: [(key: String, text: String, value: String, lookupMs: Double)] = []
        for raw in blocks {
            let text = cleanedSource(raw, enabled: flag("cleanOCR", true), fixes: fixes)
            var row: [CaptionTranslationUnit] = []
            for part in preparedSourceUnits(text, language: source.languageCode?.identifier ?? id,
                    slang: flag("slang", true), speakers: flag("speakerDetect", true), protected: never) {
                var values: [String?] = []
                for sentence in part.sentences {
                    let key = SharedTranslationWork.unitKey(source: id, target: targetCode, text: sentence,
                        protectedWords: part.tokens.map { "\($0.0)=\($0.1)" }, rules: rules)
                    let lookupStarted = ProcessInfo.processInfo.systemUptime
                    guard let value = ram.values[key],
                          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    hits.append((key, sentence, value,
                        (ProcessInfo.processInfo.systemUptime - lookupStarted) * 1000))
                    values.append(value)
                }
                row.append(CaptionTranslationUnit(label: part.label, sentences: part.sentences,
                                                  out: values, tokens: part.tokens))
            }
            units.append(row)
        }
        guard let result = CaptionAssembly.complete(units, glossary: pairs("glossary")) else { return nil }
        // No suspension above: mode, rules, bank and candidate cannot change mid-probe.
        let mayPersist = allowsPersistentTranslations && !flag("privateSession", false)
        for hit in hits {
            touchCache(hit.key)
            let speculative = ram.specKeys.remove(hit.key) != nil
            let saved = ram.savedKeys.remove(hit.key) != nil
            ram.speculationWindow.recordConfirmedOutcome(saved: saved && !speculative)
            if speculative {
                diag.noteSpeculativeUnit("reused")
                if let origin = ram.speculativeOrigins.removeValue(forKey: hit.key) { ram.speculationWindow.reuse(origin) }
            }
            diag.recordMemory(speculative ? .speculativeHit : .ramHit,
                durationMs: hit.lookupMs,
                candidate: queuedPacket?.candidateID, frameIndex: queuedPacket?.frames, unitKey: hit.key)
            if mayPersist, TranslationUnitPlanning.mayRemember(hit.text, confirmed: true),
               ram.confirmedKeys.insert(hit.key).inserted, !saved {
                queueMemory(hit.key, hit.value, independentlyConfirmed: speculative)
            }
            if diag.enabled {
                if speculative { diag.s.specHits += 1 }
                else if saved { diag.s.savedHits += 1 }
                else { diag.s.cacheHits += 1 }
            }
        }
        for row in units { for unit in row { if let label = unit.label { diag.learn(label) } } }
        diag.recordSourceLanguage(id, origin: .selected)
        if diag.enabled { diag.s.sentences += hits.count }
        diag.noteRAMCaptionBypass()
        let ready = ExactCaptionResult(translated: result, sentences: hits.count)
        ram.retainCaption(key: identity, result: ready)
        return ready
    }

    private func sharedInFlightUnits(_ blocks: [String]) -> Int {
        guard activeQueueOwner != .scheduling, drainTask?.isCancelled == false,
              sourceCode != "auto", memoryTestMode.allowsReuse, !bypassMemory,
              !modelUnitKeysInFlight.isEmpty else { return 0 }
        let source = Locale.Language(identifier: sourceCode)
        let id = source.minimalIdentifier
        let rules = memoryRuleToken
        let never = list("neverTranslate", lower: false)
        let fixes = pairs("sourceFixes")
        let cleaningEnabled = flag("cleanOCR", true)
        let slangEnabled = flag("slang", true)
        let speakersEnabled = flag("speakerDetect", true)
        let languageCode = source.languageCode?.identifier ?? id
        var keys = Set<String>()
        for raw in blocks {
            let text = cleanedSource(raw, enabled: cleaningEnabled, fixes: fixes)
            for part in preparedSourceUnits(text, language: languageCode,
                    slang: slangEnabled, speakers: speakersEnabled, protected: never) {
                for sentence in part.sentences {
                    keys.insert(SharedTranslationWork.unitKey(source: id, target: targetCode, text: sentence,
                        protectedWords: part.tokens.map { "\($0.0)=\($0.1)" }, rules: rules))
                }
            }
        }
        return ExactModelWorkPolicy.sharedUnits(inFlight: modelUnitKeysInFlight, required: keys,
            workContext: modelContextInFlight, currentContext: contextRevision, reuseAllowed: true)
    }

    private func process(_ blocks: [String], display: Bool = true) async {
        if display { isTranslating = true }
        defer { if display { isTranslating = false } }
        let t0 = Date()
        if display { processingStarted = t0; savedRequests = 0 }
        let workGeneration = generation
        let workContext = contextRevision
        let workMode = memoryTestMode
        let workRAM = ram
        let workCandidate = activeCandidateID
        let rules = memoryRuleToken
        let destination = targetCode
        let speculativeStart = Date()
        let diagnosticEpoch = diag.started
        let speculativeID: UInt64? = display ? nil : ram.speculationWindow.begin()
        if !display && diag.enabled { diag.s.specStarted += 1 }
        defer {
            let discarded = Task.isCancelled || workContext != contextRevision || workCandidate != activeCandidateID
            if let speculativeID { workRAM.speculationWindow.finish(speculativeID, discarded: discarded) }
            if !display && diag.enabled && diag.started == diagnosticEpoch {
                let ms = Date().timeIntervalSince(speculativeStart) * 1000
                diag.s.specProcessingMs += ms
                if Task.isCancelled || workContext != contextRevision || workCandidate != activeCandidateID {
                    diag.s.specDiscarded += 1; diag.s.specDiscardedMs += ms
                } else { diag.s.specCompleted += 1 }
            }
        }
        diag.trace(currentPacket?.candidateID, stage: display ? "processing" : "speculating",
                   detail: "Translation started", frameIndex: currentPacket?.frames)
        let target = Locale.Language(identifier: destination)
        let cleanOn = flag("cleanOCR", true), slangOn = flag("slang", true), speakerOn = flag("speakerDetect", true)
        let fixes = pairs("sourceFixes")
        let never = list("neverTranslate", lower: false)

        var units: [[CaptionTranslationUnit]] = []
        var pending: [String: [(b: Int, u: Int, s: Int, text: String, key: String)]] = [:]
        var srcLangs: [String: Locale.Language] = [:]
        var eligibleMemoryKeys = Set<String>()
        var resolvedLookups: [String: MemoryLookupResult] = [:]
        var translatedAny = false
        var unresolvedSource = false
        var failureReason: String? = nil
        func isCurrent() -> Bool {
            let current = !Task.isCancelled && workContext == contextRevision && workMode == memoryTestMode &&
                (!display || workGeneration == generation) &&
                CandidateValidity.isCurrent(workCandidate, active: activeCandidateID,
                    enabled: flag("steadyCaptions", true))
            if display && !current && diag.detailedCollection && diag.started == diagnosticEpoch {
                diag.trace(workCandidate, stage: "cancelled",
                           detail: "Obsolete translation generation or candidate")
            }
            return current
        }

        /// Remembers a finished sentence. Early (translate-ahead) results are marked so we can show how often they pay off.
        func store(_ key: String, _ out: String) {
            guard isCurrent(), memoryTestMode.allowsReuse else { return }
            guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            ram.values[key] = out
            ram.savedKeys.remove(key)
            if display && eligibleMemoryKeys.contains(key) && !flag("freshTranslationTest", false) {
                ram.confirmedKeys.insert(key)
                queueMemory(key, out, independentlyConfirmed: true)
            }
            memoryDirty = true
            touchCache(key)
            if !display {
                if ram.specKeys.insert(key).inserted { diag.noteSpeculativeUnit("retained") }
                if let speculativeID { ram.speculativeOrigins[key] = speculativeID }
            }
        }

        for (bi, raw) in blocks.enumerated() {
            let text = cleanedSource(raw, enabled: cleanOn, fixes: fixes)
            if display && diag.detailedCollection && text != raw {
                diag.trace(workCandidate, stage: "ocrCorrection",
                           detail: "Recognized text was cleaned or corrected")
            }
            guard let choice = detectSource(text, record: display) else {
                if display && diag.detailedCollection {
                    diag.trace(workCandidate, stage: "language",
                               detail: "No compatible source language selected")
                }
                unresolvedSource = true
                units.append([CaptionTranslationUnit(label: nil, sentences: [text], out: [text], tokens: [])])
                continue
            }
            guard choice.language.languageCode != target.languageCode else {
                units.append([CaptionTranslationUnit(label: nil, sentences: [text], out: [text], tokens: [])])
                continue
            }
            let src = choice.language
            let id = src.minimalIdentifier
            if display && diag.detailedCollection {
                diag.trace(workCandidate, stage: "language",
                           detail: "Source language resolved for current candidate")
            }
            if display {
                if diag.s.sourceUsed != id || diag.s.sourceOrigin != choice.origin.title {
                    diag.event(.language, "Source resolved: \(id) (\(choice.origin.title))")
                }
                diag.recordSourceLanguage(id, origin: choice.origin)
                if choice.origin != .selected, detectedLang != id { detectedLang = id }
            }
            srcLangs[id] = src
            let sourceConfidence = sourceCode == "auto" ? (languageEvidence(text, limit: 5).1.filter {
                SourceLanguageRouter.sameLanguage($0.key.rawValue, id)
            }.values.max() ?? 0) : 0
            let memoryEligible = MemoryRetentionPolicy.mayPersist(privateSession: flag("privateSession", false),
                selectedSource: sourceCode != "auto", confidence: sourceConfidence, confirmed: display) && allowsPersistentTranslations
            let parts = preparedSourceUnits(text, language: src.languageCode?.identifier ?? id,
                slang: slangOn, speakers: speakerOn, protected: never)
            var row: [CaptionTranslationUnit] = []
            for (ui, d) in parts.enumerated() {
                if display, let name = d.label { diag.learn(name) }
                let sentences = d.sentences
                if display && diag.detailedCollection {
                    diag.trace(workCandidate, stage: "segmentation",
                               detail: "Translation units assigned to stable block")
                }
                if display && diag.enabled { diag.s.sentences += sentences.count }
                var outs: [String?] = []
                for (si, s) in sentences.enumerated() {
                    let key = SharedTranslationWork.unitKey(source: id, target: destination, text: s, protectedWords: d.tokens.map { "\($0.0)=\($0.1)" }, rules: rules)
                    if memoryEligible && TranslationUnitPlanning.mayRemember(s, confirmed: display) {
                        eligibleMemoryKeys.insert(key)
                    }
                    let lookupStart = ProcessInfo.processInfo.systemUptime
                    let bypassReuse = bypassMemory || flag("freshTranslationTest", false)
                    if display && bypassReuse {
                        diag.recordMemory(.bypassed, candidate: workCandidate, unitKey: key)
                    }
                    var resolvedHit = bypassReuse ? nil : ram.values[key]
                    var diskHit = false
                    if resolvedHit == nil, !bypassReuse, allowsPersistentTranslations, memoryReady, flag("remember", true), !flag("privateSession", false) {
                        let lookup: MemoryLookupResult
                        if let previous = resolvedLookups[key] { lookup = previous }
                        else {
                            lookup = await memoryStore.lookup(key: key)
                            resolvedLookups[key] = lookup
                        }
                        guard isCurrent() else {
                            if display {
                                // Never attribute an obsolete result to the newer
                                // packet. Count it as cancelled, not as a usable hit.
                                if diag.started == diagnosticEpoch {
                                    diag.recordMemory(.cancelled, durationMs: lookup.durationMs,
                                        candidate: workCandidate, unitKey: key)
                                }
                            }
                            return
                        }
                        resolvedHit = lookup.value
                        diskHit = lookup.value != nil
                        if display {
                            let outcome: MemoryDiagnosticOutcome
                            switch lookup.outcome {
                            case "timeout": outcome = .timeout
                            case "normalized_hit": outcome = .normalizedHit
                            case "incompatible", "conflict": outcome = .compatibilityRejected
                            case "database_error", "unavailable": outcome = .databaseUnavailable
                            default: outcome = diskHit ? (lookup.origin == "legacy" ? .legacyHit : .persistentHit) : .miss
                            }
                            diag.recordMemory(outcome, durationMs: lookup.durationMs,
                                              candidate: currentPacket?.candidateID,
                                              frameIndex: currentPacket?.frames, unitKey: key)
                        }
                        if let value = resolvedHit {
                            ram.values[key] = value; ram.savedKeys.insert(key); touchCache(key)
                        }
                    }
                    if let hit = resolvedHit {
                        touchCache(key)
                        outs.append(hit); translatedAny = true
                        if display {
                            if memoryTestMode == .temporaryMemory { diag.noteTemporaryReuse() }
                            let speculativeHit = ram.specKeys.remove(key) != nil
                            if speculativeHit { diag.noteSpeculativeUnit("reused") }
                            if speculativeHit, let origin = ram.speculativeOrigins.removeValue(forKey: key) {
                                ram.speculationWindow.reuse(origin)
                            }
                            let savedFromRAM = ram.savedKeys.remove(key) != nil
                            let savedHit = diskHit || savedFromRAM
                            ram.speculationWindow.recordConfirmedOutcome(saved: savedHit && !speculativeHit)
                            if !diskHit { diag.recordMemory(speculativeHit ? .speculativeHit : .ramHit,
                                                                  durationMs: (ProcessInfo.processInfo.systemUptime - lookupStart) * 1000,
                                                                  candidate: currentPacket?.candidateID,
                                                                  frameIndex: currentPacket?.frames, unitKey: key) }
                            // A speculative result was produced by the current on-device
                            // model, not by historical memory. Once this exact key is
                            // independently confirmed by stable OCR, it is safe to use
                            // as evidence for lazy legacy reconciliation without another
                            // model call. Ordinary RAM/SQLite hits remain untrusted proof.
                            if memoryEligible && ram.confirmedKeys.insert(key).inserted && !savedHit {
                                queueMemory(key, hit, independentlyConfirmed: speculativeHit)
                            }
                            if diag.enabled {
                                if speculativeHit { diag.s.specHits += 1 }
                                else if savedHit { diag.s.savedHits += 1 }
                                else { diag.s.cacheHits += 1 }
                            }
                            diag.trace(currentPacket?.candidateID, stage: "cache", detail: speculativeHit ? "Speculative hit" : (savedHit ? "Saved-memory hit" : "Session hit"))
                        }
                    } else {
                        outs.append(nil)
                        if display && memoryTestMode == .temporaryMemory {
                            diag.recordMemory(.temporaryMiss, candidate: workCandidate, unitKey: key)
                        }
                        if display {
                            ram.speculationWindow.recordConfirmedOutcome(saved: false)
                            if diag.enabled { diag.s.cacheMisses += 1 }
                        }
                        pending[id, default: []].append((bi, ui, si, s, key))
                    }
                }
                row.append(CaptionTranslationUnit(label: d.label, sentences: sentences, out: outs, tokens: d.tokens))
            }
            units.append(row)
        }

        var failed = false
        for (id, items) in pending {
            guard let src = srcLangs[id] else { continue }
            guard isCurrent() else { return }
            let availability = await pairStatus(src, target)
            guard isCurrent() else { return }
            if availability == .unsupported {
                failureReason = "\(id) → \(targetCode) isn't supported"
                if display { status = failureReason ?? "Unsupported language pair"; diag.event(.language, status) }
                failed = true; continue
            }
            if availability == .supported {
                if !display { continue }
                failureReason = "Download the \(id) → \(targetCode) language packs in Languages"
                status = failureReason ?? "Language pack missing"
                diag.event(.language, status)
            }
            if display && diag.enabled { diag.s.batches += 1 }
            let installed = availability == .installed
            let plan = TranslationBatchPlan(items.map { $0.text }, contexts: items.map { $0.key })
            if display { savedRequests += items.count - plan.unique.count }
            diag.noteExactUnitCoalescing(items.count - plan.unique.count)
            if !display && diag.enabled { diag.s.specModelRequests += plan.unique.count }
            if display && diag.detailedCollection {
                diag.trace(workCandidate, stage: "freshTranslation",
                           detail: "Uncached units submitted to on-device translation")
            }
            let streamPartials = installed && workMode.allowsReuse &&
                (display || flag("incrementalBatchRecovery", false))
            var completedParts: [Int: String] = [:]
            var partialHandler: (@MainActor (Int, String) -> Void)?
            if streamPartials {
                let exactKeys = plan.uniqueContexts
                partialHandler = { [weak self] index, value in
                    guard index >= 0, index < exactKeys.count else { return }
                    completedParts[index] = value
                    self?.retainCompletedModelUnit(key: exactKeys[index], value: value,
                        context: workContext, rules: rules, destination: destination,
                        mode: workMode, bank: workRAM, confirmed: display,
                        speculativeID: speculativeID, epoch: diagnosticEpoch)
                }
            }
            modelUnitKeysInFlight = Set(items.map { $0.key })
            modelContextInFlight = workContext
            let batch = await translateBatch(plan.unique, source: src, target: target, installed: installed,
                                             speculative: !display, partial: partialHandler)
            // 2.2.3 (L2): a detached speculative call must not erase the newer confirmed call's in-flight set.
            if modelUnitKeysInFlight == Set(items.map { $0.key }) {
                modelUnitKeysInFlight.removeAll()
                modelContextInFlight = nil
            }
            if !isCurrent() {
                // Cancellation is cooperative: confirmed or speculative model work
                // can finish after a different caption arrives. Recover only completed exact-key
                // units in the SAME context, never publish this old caption,
                // never retry it and never write unconfirmed output to disk.
                let recovered = SubtitlePerformancePolicy.retainedSpeculativeResults(
                    keys: items.map { $0.key },
                    values: batch.flatMap { plan.expand($0.map(Optional.some)) },
                    workContext: workContext, currentContext: contextRevision,
                    reuseAllowed: workMode == memoryTestMode && !bypassMemory && !flag("freshTranslationTest", false) &&
                        rules == memoryRuleToken && destination == targetCode)
                var retained = 0
                for (key, value) in recovered where ram.values[key] == nil {
                    ram.values[key] = value
                    ram.savedKeys.remove(key)
                    if !display, ram.specKeys.insert(key).inserted { diag.noteSpeculativeUnit("retained") }
                    if let speculativeID { ram.speculativeOrigins[key] = speculativeID }
                    touchCache(key)
                    retained += 1
                }
                trimCache()
                if diag.enabled && diag.started == diagnosticEpoch {
                    if !display { diag.s.specRetainedUnits += retained }
                    else { diag.noteCompletedWorkRecovery(retained) }
                }
                return
            }
            guard isCurrent() else { return }
            if display && diag.detailedCollection {
                diag.trace(workCandidate, stage: "translationResult",
                           detail: (batch?.count == plan.unique.count) ?
                                   "On-device model batch returned expected count" :
                                   "Translation batch was incomplete; retry policy applies")
            }
            var uniqueResults: [String?]
            if let batch, batch.count == plan.unique.count {
                uniqueResults = batch.map(Optional.some)
            } else {
                // Tentative work gets one attempt. Let confirmed processing own
                // retries instead of holding its queue behind speculative retries.
                if !display { return }
                diag.log("Batch failed – retrying unique sentences")
                uniqueResults = []
                for (index, sentence) in plan.unique.enumerated() {
                    guard isCurrent() else { return }
                    if let completed = completedParts[index] {
                        uniqueResults.append(completed)
                        continue
                    }
                    if !display && diag.enabled { diag.s.specModelRequests += 1 }
                    let result = await translateBatch([sentence], source: src, target: target, installed: installed, speculative: !display)
                    uniqueResults.append(result?.count == 1 ? result?.first : nil)
                }
            }
            guard isCurrent(), let results = plan.expand(uniqueResults) else { return }
            for (index, item) in items.enumerated() {
                if let value = results[index] {
                    units[item.b][item.u].out[item.s] = value
                    store(item.key, value)
                    translatedAny = true
                } else {
                    failed = true
                    if display && diag.enabled { diag.s.failures += 1 }
                }
            }
        }
        guard isCurrent(), (!paused || manualMode) else { return }
        trimCache()
        bypassMemory = false

        guard translatedAny else {
            if display {
                if failed, failureReason == nil, !Task.isCancelled, sourceCode == "auto", flag("languageRecovery", true) {
                    languageFailures += 1
                    if languageFailures >= 2 {
                        languageRouter.reset(); languageContext.reset(); lockedLang = nil; languageCache.removeAll(); languageFailures = 0
                        diag.event(.language, "Automatic source recovery after repeated translation failures")
                        rotRev += 1; syncConfig()
                    }
                }
                lastHandled = ""
                status = failed ? (failureReason ?? "Translation failed – check the language packs in Languages")
                    : (unresolvedSource ? "Could not identify the source – choose a source language in Languages" : "Text is already in the target language")
            }
            return
        }
        if !display { return }          // translate-ahead: the result now waits in the active RAM bank
        guard !failed else {
            lastHandled = ""
            status = failureReason ?? "Translation incomplete – keeping the previous result. Tap Retry."
            return
        }
        guard let assembled = CaptionAssembly.complete(units, glossary: pairs("glossary")) else {
            lastHandled = ""
            status = "Translation incomplete – keeping the previous result. Tap Retry."
            return
        }
        languageFailures = 0
        translateMs = Date().timeIntervalSince(t0) * 1000
        diag.trace(currentPacket?.candidateID, stage: "ready", detail: "Translation assembled")
        var sentenceCount = 0
        for row in units { for u in row { sentenceCount += u.sentences.count } }
        if memoryTestMode.allowsReuse,
           let key = ExactCaptionIdentity.key(blocks: blocks, source: sourceCode,
                                              target: targetCode, rules: rules) {
            ram.retainCaption(key: key, result: ExactCaptionResult(
                translated: assembled, sentences: sentenceCount))
        }
        diag.recordTranslate(ms: translateMs, sentences: sentenceCount,
                             from: srcLangs.keys.sorted().joined(separator: "+"), to: targetCode,
                             preview: assembled)
        if diag.enabled { diag.s.translations += 1 }
        if diag.enabled { diag.s.chars += blocks.joined().count }
        status = "\(srcLangs.keys.sorted().joined(separator: "+")) → \(targetCode) ✓"
        let timing = PresentationTiming(packet: currentPacket, firstSeen: currentTs,
            queuedAt: currentQueuedAt, processingAt: processingStarted, processingMs: translateMs,
            savedRequests: savedRequests, readyAt: Date())
        schedulePresentation(blocks.joined(separator: "\n"), assembled,
                             generation: workGeneration, context: workContext, timing: timing)
    }

    /// Translates many sentences in one call.
    private func translateBatch(_ texts: [String], source: Locale.Language, target: Locale.Language,
                                installed: Bool, speculative: Bool = false,
                                partial: (@MainActor (Int, String) -> Void)? = nil) async -> [String]? {
        if #available(iOS 26.0, *), installed {
            let k = "\(source.minimalIdentifier)>\(targetCode)|\((activeTranslationSystem == .lowLatency) ? "low" : "default")"
            guard !Task.isCancelled else { return nil }
            if diag.enabled { diag.s.sessionKind = "Direct session (iOS 26)" }
            if speculative {
                let workContext = contextRevision
                let diagnosticEpoch = diag.started
                let lease = speculativeSessions.begin(key: k) {
                    diag.noteModelState("speculative_session_created")
                    if #available(iOS 26.4, *), (activeTranslationSystem == .lowLatency) {
                        return TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
                    }
                    return TranslationSession(installedSource: source, target: target)
                }
                if speculativeSessions.takeConflict() { diag.noteModelState("speculative_lease_conflict") }
                if activeTranslationSystem == .legacy, modelReadiness.source != source.minimalIdentifier || modelReadiness.target != target.minimalIdentifier {
                    modelReadiness = TranslationReadiness(source: source.minimalIdentifier, target: target.minimalIdentifier)
                }
                let result = await runBatch(lease.session, texts, speculative: true, partial: partial, observeReadiness: true)
                // A cancelled Swift task can still return a complete valid batch.
                // Only explicit session cancellation (tracked by the lease),
                // failure or context change prevents warm-session reuse.
                speculativeSessions.finish(lease, reusable: result != nil && workContext == contextRevision)
                if let requested = lease.cancellationRequestedAt, diag.started == diagnosticEpoch {
                    diag.noteModelState("speculative_stop_released",
                        durationMs: max(0, ProcessInfo.processInfo.systemUptime - requested) * 1000)
                }
                return result
            }
            // v2.0.0 G5: Legacy model calls are serialized. Reuse the idle,
            // warm prediction session for confirmed work so consecutive calls
            // stay on one session; fall back to the direct session on failure.
            if activeTranslationSystem == .legacy, flag("legacySharedSession", true),
               let shared = speculativeSessions.lendIdle(key: k) {
                if modelReadiness.source != source.minimalIdentifier || modelReadiness.target != target.minimalIdentifier {
                    modelReadiness = TranslationReadiness(source: source.minimalIdentifier, target: target.minimalIdentifier)
                }
                diag.noteModelState("legacy_shared_session_used")
                let shared_result = await runBatch(shared, texts, speculative: false, partial: partial, observeReadiness: true)
                speculativeSessions.returnLent(usable: shared_result != nil)
                if shared_result != nil { warmupStatus = "Ready"; return shared_result }
                if Task.isCancelled { return nil }
            }
            if directSession == nil || directKey != k {
                diag.noteModelState("model_session_created")
                if #available(iOS 26.4, *), (activeTranslationSystem == .lowLatency) {
                    directSession = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
                } else {
                    directSession = TranslationSession(installedSource: source, target: target)
                }
                directKey = k
            }
            if diag.enabled { diag.s.sessionKind = "Direct session (iOS 26)" }
            guard let session = directSession else { return nil }
            if activeTranslationSystem == .legacy, modelReadiness.source != source.minimalIdentifier || modelReadiness.target != target.minimalIdentifier {
                modelReadiness = TranslationReadiness(source: source.minimalIdentifier, target: target.minimalIdentifier)
            }
            let r = await runBatch(session, texts, speculative: speculative, partial: partial)
            if r == nil {
                if directSession === session { directSession = nil }
            } else { warmupStatus = "Ready" }
            return r
        }
        if diag.enabled { diag.s.sessionKind = "Hosted view (iOS 18)" }
        return await translateLegacy(texts, source: source, target: target, speculative: speculative)
    }

    func runBatch(_ session: TranslationSession, _ texts: [String],
                          warmup: Bool = false, speculative: Bool = false,
                          partial: (@MainActor (Int, String) -> Void)? = nil,
                          observeReadiness: Bool = false) async -> [String]? {
        let diagnosticEpoch = diag.started
        let readinessContext = contextRevision
        let readinessSource = modelReadiness.source, readinessTarget = modelReadiness.target
        let observesReadiness = activeTranslationSystem == .legacy && (observeReadiness || session === directSession || session === warmupSession)
        func record(_ reason: String, durationMs: Double? = nil, candidate: String? = nil) {
            if observesReadiness, readinessContext == contextRevision, activeTranslationSystem == .legacy,
               modelReadiness.source == readinessSource, modelReadiness.target == readinessTarget {
                if reason == "warmup_model_submitted" || reason == "confirmed_model_submitted" || reason == "speculative_model_submitted" {
                    modelReadiness.beginExecution(label: warmup ? "Running Legacy warm-up" : "Running translation request")
                } else if reason == "model_batch_completed" {
                    modelReadiness.finishExecution(success: true, milliseconds: durationMs)
                } else if reason == "model_batch_failed" {
                    modelReadiness.finishExecution(success: false, milliseconds: durationMs)
                } else if reason == "model_batch_cancelled" {
                    modelReadiness.execution = .pending; modelReadiness.sessions = .pending; modelReadiness.activeSince = nil
                    modelReadiness.explanation = "Model work was interrupted; live translation has priority."
                }
            }
            guard diagnosticEpoch == diag.started else { return }
            diag.noteModelState(reason, durationMs: durationMs, candidate: candidate)
        }
        let marker = modelPerf.beginInterval("TranslationBatch")
        defer { modelPerf.endInterval("TranslationBatch", marker) }
        let began = ProcessInfo.processInfo.systemUptime
        let sessionID = ObjectIdentifier(session)
        let measuresSwitch = !warmup && activeTranslationSystem == .legacy
        let otherSessionNearby = measuresSwitch &&
            (legacyModelInFlight.contains { $0.key != sessionID && $0.value > 0 } ||
             (legacyLastModelReturn.map { $0.session != sessionID && began - $0.at < 1.5 } ?? false))
        if measuresSwitch { legacyModelInFlight[sessionID, default: 0] += 1 }
        defer {
            if measuresSwitch {
                let remaining = (legacyModelInFlight[sessionID] ?? 1) - 1
                legacyModelInFlight[sessionID] = remaining > 0 ? remaining : nil
                legacyLastModelReturn = (sessionID, ProcessInfo.processInfo.systemUptime)
            }
        }
        let modelCandidate = warmup ? nil : currentPacket?.candidateID
        let first30s = !warmup && sessionStarted.map {
            let age = Date().timeIntervalSince($0)
            return age >= 0 && age <= 30
        } == true
        record(warmup ? "warmup_model_submitted" :
            (speculative ? "speculative_model_submitted" : "confirmed_model_submitted"), candidate: modelCandidate)
        let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        do {
            let result: [String]?
            if partial != nil && texts.count > 1 {
                // Never present partial subtitles. Store only completed units
                // in exact-context volatile memory. A failed batch stays failed.
                var collected: [Int: String] = [:]
                for try await response in session.translate(batch: reqs) {
                    guard let id = response.clientIdentifier,
                          let index = Int(id), index >= 0, index < texts.count,
                          collected[index] == nil else { continue }
                    let value = response.targetText
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    collected[index] = value
                    partial?(index, value)
                }
                result = collected.count == texts.count ?
                    (0..<texts.count).compactMap { collected[$0] } : nil
            } else {
                let res = try await session.translations(from: reqs)
                result = PipelineSafety.orderedTranslations(
                    res.map { ($0.clientIdentifier, $0.targetText) }, count: texts.count)
            }
            record(result == nil ? "model_batch_failed" : "model_batch_completed",
                durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
            if result != nil {
                record(warmup ? "warmup_model_completed" :
                    (speculative ? "speculative_model_completed" : "confirmed_model_completed"),
                    durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000,
                    candidate: modelCandidate)
                if measuresSwitch && !speculative {
                    record(otherSessionNearby ? "legacy_confirmed_after_switch" : "legacy_confirmed_no_switch",
                        durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
                }
            }
            if first30s {
                record("model_batch_first_30s",
                    durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
            }
            return result
        } catch {
            if Task.isCancelled || (warmup && warmupSuperseded) {
                record("model_batch_cancelled",
                    durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
                return nil
            }
            record("model_batch_failed",
                durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
            diag.event(.error, "Translation engine failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func schedulePresentation(_ text: String, _ result: String, generation: Int, context: Int, timing: PresentationTiming) {
        guard PresentationSchedule.isCurrent(generation: generation, context: context,
            currentGeneration: self.generation, currentContext: self.contextRevision,
            frozen: frozen, paused: paused, manual: manualMode) else { return }
        cancelPresentation()
        let delay = PresentationSchedule.remaining(policy: ud.string(forKey: "displayPolicy") ?? "immediate",
            minimum: num("minDisplay", 0), lastShown: lastShowDate.timeIntervalSince1970, now: Date().timeIntervalSince1970)
        guard delay > 0 else { show(text, result, timing: timing); return }
        waitingToDisplay = true
        let ticket = presentationID
        presentationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, ticket == self.presentationID else { return }
            self.waitingToDisplay = false
            guard PresentationSchedule.isCurrent(generation: generation, context: context,
                currentGeneration: self.generation, currentContext: self.contextRevision,
                frozen: self.frozen, paused: self.paused, manual: self.manualMode) else { return }
            self.show(text, result, timing: timing)
        }
    }

    @discardableResult
    private func show(_ text: String, _ result: String, timing: PresentationTiming) -> Bool {
        lastShowReusedFrame = false
        clearTask?.cancel()
        clearTask = nil
        guard !frozen, (!paused || manualMode),
              CandidateValidity.isCurrent(timing.packet?.candidateID, active: activeCandidateID, enabled: flag("steadyCaptions", true), allowLegacy: true) else { return false }
        if activeTranslationSystem == .legacy, PipelineSafety.isRecentFragment(text, of: original, age: Date().timeIntervalSince(lastShowDate)) { return false }
        let proposedStyle = pipStyle
        if activeTranslationSystem != .legacy, showing,
           pip.isShowingIdenticalFrame(original: text, translated: result,
                                      showOriginal: showOriginal, size: windowSize.size,
                                      style: proposedStyle) {
            lastShowReusedFrame = true
            if diag.enabled { diag.s.identicalFrameHolds += 1 } // 2.2.1 (E9)
            lastTextDate = Date()
            if timing.packet?.candidateID == activeCandidateID { activeCandidatePresented = true }
            replayDeferredConfirmedIfPossible()
            return true
        }
        let renderStart = Date()
        pip.style = proposedStyle
        guard pip.render(original: text, translated: result, showOriginal: showOriginal,
                         size: windowSize.size) else {
            lastHandled = ""
            status = "Frame preparation failed – keeping the previous subtitle. Tap Retry."
            diag.notePipelineDecision(candidate: timing.packet?.candidateID,
                frameIndex: timing.packet?.frames, stage: "pip_enqueue", reason: "enqueue_failed")
            return false
        }
        original = text
        translated = result
        showing = true
        lastTextDate = Date()
        lastShowDate = Date()
        let presented = Date()
        let packet = timing.packet
        let sent = packet?.ts ?? timing.queuedAt.timeIntervalSince1970
        let first = packet?.firstSeenAt ?? timing.firstSeen
        let read = packet?.readStartedAt ?? sent
        let total = timing.firstSeen > 0 ? max(0, presented.timeIntervalSince1970 - timing.firstSeen) * 1000 : 0
        latency.last = LatencyBreakdown(
            recognition: packet?.ocrMs ?? 0,
            confirmation: max(0, read - first) * 1000,
            delivery: max(0, timing.queuedAt.timeIntervalSince1970 - read - (packet?.ocrMs ?? 0) / 1000) * 1000,
            queue: max(0, timing.processingAt.timeIntervalSince(timing.queuedAt)) * 1000,
            translation: timing.processingMs,
            displayHold: max(0, renderStart.timeIntervalSince(timing.readyAt)) * 1000,
            rendering: presented.timeIntervalSince(renderStart) * 1000,
            total: total, requestsSaved: timing.savedRequests)
        diag.trace(packet?.candidateID, stage: "enqueued", detail: "PiP frame prepared in \(Int(latency.last.rendering)) ms; physical presentation unmeasured")
        if packet?.candidateID == activeCandidateID {
            activeCandidatePresented = true
        }
        // 2.2.1 (E8): compose text, photo/file text and "Test the language pair" are not capture work. They are
        // counted on their own and never enter the latency, pipeline or enqueue totals of a Test Run.
        let isManualEntry = packet == nil || (packet?.candidateID?.hasPrefix("manual-") ?? false)
        if isManualEntry {
            if diag.enabled { diag.s.manualTranslations += 1 }
        } else if diag.enabled { diag.s.enqueuedCandidateFrames += 1 }
        if !isManualEntry, total >= 1200 {
            if diag.enabled { diag.s.slowTailEnqueues += 1 }
            diag.notePipelineDecision(candidate: packet?.candidateID,
                frameIndex: packet?.frames, stage: "pip_enqueue",
                reason: "slow_tail", durationMs: total)
        }
        if activeTranslationSystem == .legacy, let candidate = packet?.candidateID {
            diag.legacyModeEnqueued(candidate, duration: total, source: sourceCode == "auto" ? detectedLang : sourceCode)
        }
        if !isManualEntry {
            diag.recordPipeline(latency.last)
            if total > 0 { diag.recordLatency(ms: total) }
        }
        if history.first?.original != text {
            sessionTranslations += 1; sessionCharacters += text.count
            if memoryTestMode.allowsHistoryInsertion && !flag("privateSession", false) {
                // 2.2.1 (E1, E15): one mutation (one scheduled write), and starred items are never trimmed.
                var next = history
                next.insert(HistoryItem(original: text, translated: result,
                                        sourceLanguage: sourceCode == "auto" ? detectedLang : sourceCode,
                                        targetLanguage: targetCode), at: 0)
                history = HistoryPolicy.trimmed(next, capacity: historyCapacity)
            }
            if flag("speak", false) { speak(result) }
            if flag("haptics", false) {
                let strength = ud.string(forKey: "hapticStrength") ?? "light"
                UIImpactFeedbackGenerator(style: strength == "strong" ? .heavy : (strength == "medium" ? .medium : .light)).impactOccurred()
            }
            if flag("autoCopy", false) {
                let format = ud.string(forKey: "autoCopyFormat") ?? "translation"
                UIPasteboard.general.string = format == "original" ? text : (format == "bilingual" ? text + "\n" + result : result)
            }
        }
        renderedGrams = TextSim.grams(result).union(placeholderGrams)
        sourceGrams = TextSim.grams(text)
        // Only a successfully displayed, independently resolved source should
        // influence a future predictive model warm-up; never change Auto OCR.
        let sourceToRemember = sourceCode == "auto" ? detectedLang : sourceCode
        if sourceToRemember != "–", !sourceToRemember.isEmpty {
            // Two UserDefaults writes per subtitle were unnecessary: the source
            // is written when it changes, the timestamp at most every 30 s
            // (readers only use a 24 h freshness window).
            let nowSeconds = Date().timeIntervalSince1970
            if ud.string(forKey: "lastEffectiveSource") != sourceToRemember {
                ud.set(sourceToRemember, forKey: "lastEffectiveSource")
                ud.set(nowSeconds, forKey: "lastEffectiveSourceAt")
            } else if nowSeconds - ud.double(forKey: "lastEffectiveSourceAt") >= 30 {
                ud.set(nowSeconds, forKey: "lastEffectiveSourceAt")
            }
        }
        replayDeferredConfirmedIfPossible()
        return true
    }

    func clearRAMCache() {
        invalidatePending()
        processMemory.normal.clear()
        segmentationCache.clear()
        // Temporary test entries are process-owned and are not reset by normal
        // memory maintenance, diagnostics reset, mode toggles or app switches.
    }

    /// v2.0.0 test helper: empties only process-owned Temporary Memory so the
    /// next mode run cannot reuse the previous run's translations. Never
    /// touches saved memory or normal RAM. Refused while capture is live.
    @discardableResult
    func clearTemporaryTestMemory() -> Bool {
        guard !captureAlive else { return false }
        invalidatePending()
        processMemory.temporary.clear()
        temporaryMemoryEntries = 0
        return true
    }

    func deleteUnvalidatedLegacy() async throws -> Int {
        guard memoryReady, !captureAlive, !pipActive, !busy, !warming,
              !legacyValidationBusy, idleValidationTask == nil, !memorySaving,
              !memoryMutationInProgress, pendingMemory.isEmpty else { throw MemoryStoreError.unavailable }
        memoryMutationInProgress = true
        defer { memoryMutationInProgress = false; saveMemory(force: true) }
        invalidatePending()
        memoryRevision += 1
        let count = try await memoryStore.deleteUnvalidatedLegacy(revision: memoryRevision)
        // Pending legacy records are never RAM hits, so valid cached results
        // can stay intact. Reset only scan snapshots/cursors after COMMIT.
        legacyScanFingerprint = ""
        refreshLegacyScanContext()
        await refreshMemoryHealth()
        return count
    }

    /// After *every* suspension, capture and changed processing rules win over
    /// idle work. Never commit translations created under outdated settings.
    private func idleValidationStillSafe(revision: Int, target: String,
                                         rules: String) -> Bool {
        !Task.isCancelled && !captureAlive && !pipActive && !busy &&
        UIApplication.shared.applicationState == .active &&
        allowsPersistentTranslations && !flag("privateSession", false) && !flag("freshTranslationTest", false) &&
        !ProcessInfo.processInfo.isLowPowerModeEnabled &&
        ProcessInfo.processInfo.thermalState != .serious &&
        ProcessInfo.processInfo.thermalState != .critical &&
        contextRevision == revision && targetCode == target &&
        memoryRuleToken == rules && !memorySaving &&
        !memoryMutationInProgress && pendingMemory.isEmpty && memoryReady
    }

    /// Automatic batches of 24 or manual batches up to 48. Two concurrent
    /// sessions in Nominal thermal state, one in Fair. Every result is checked
    /// again before an all-or-nothing SQLite commit.
    func validateIdleLegacy(maxEntries: Int = IdleLegacyBatchPolicy.automaticEntries) async {
        guard mayRunIdleValidation else {
            legacyIdleValidationStatus = "Unavailable during capture or under device pressure"
            return
        }
        guard #available(iOS 26.0, *) else {
            legacyIdleValidationStatus = "Requires iOS 26 or newer"
            return
        }
        guard pairs("sourceFixes").isEmpty &&
              list("neverTranslate", lower: false).isEmpty else {
            legacyIdleValidationStatus = "Source substitutions or protected words prevent safe idle validation"
            return
        }
        lastIdleValidationAttempt = Date()
        legacyValidationBusy = true
        legacyBatchActive = true
        legacyBatchCompleted = 0
        legacyBatchProcessed = 0
        legacyBatchSkipped = 0
        legacyScanReasons = [:]
        legacyEstimatedRemainingMinutes = nil
        legacyBatchStartedAt = Date()
        legacyBatchTotal = 0
        let scanSource = sourceCode
        let scanTarget = targetCode
        let maxCount = max(1, min(IdleLegacyBatchPolicy.maximumEntries, maxEntries))
        let fair = ThermalPerformancePolicy.automaticPressure(for: ProcessInfo.processInfo.thermalState)
        let workers = IdleLegacyBatchPolicy.concurrency(thermalFair: fair)
        legacyBatchWorkers = workers
        legacyIdleValidationStatus = "Scanning up to \(maxCount) older entries…"
        diag.noteModelState("legacy_idle_started")
        defer {
            legacyValidationBusy = false
            legacyBatchActive = false
            legacyValidationElapsedSeconds = max(0, Date().timeIntervalSince(legacyBatchStartedAt))
            diag.recordLegacyValidationSnapshot(inventory: legacyValidationInventory,
                reasons: legacyScanReasons, source: scanSource, target: scanTarget)
            lastIdleValidationAttempt = Date()
        }

        let originalRevision = contextRevision
        let target = targetCode
        let rules = memoryRuleToken
        let sourceFilter: String? = sourceCode == "auto" ? nil : sourceCode
        var selected: [TranslationMemoryStore.LegacyIdleCandidate] = []
        var scanned = 0
        var exhausted = false
        do {
            legacyValidationInventory = try await memoryStore.legacyValidationInventory(
                target: target, selectedSource: sourceFilter)
            while selected.count < maxCount && scanned < 384 {
                guard idleValidationStillSafe(revision: originalRevision, target: target, rules: rules)
                else { return }
                // Request no more rows than we can consume. Otherwise an
                // early break can advance the cursor past unscheduled entries.
                let rows = try await memoryStore.nextLegacyIdleCandidates(
                    target: target, selectedSource: sourceFilter,
                    after: legacyValidationCursor, limit: min(64, maxCount - selected.count))
                if rows.isEmpty { exhausted = true; break }
                for entry in rows {
                    legacyValidationCursor = entry.id
                    scanned += 1
                    let reason: String?
                    if entry.source.isEmpty || entry.text.isEmpty {
                        reason = "Unreadable key or protected context"
                    } else if (flag("cleanOCR", true) && TextIntel.cleanOCR(entry.text) != entry.text) ||
                                (flag("slang", true) && TextIntel.expandSlang(entry.text, lang: entry.source) != entry.text) {
                        reason = "Needs cleanup or slang review"
                    } else {
                        let sentences = splitSentences(entry.text)
                        reason = sentences.count == 1 && sentences[0] == entry.text ? nil : "Needs sentence-unit review"
                    }
                    if let reason {
                        legacyBatchSkipped += 1
                        legacyScanReasons[reason, default: 0] += 1
                        continue
                    }
                    selected.append(entry)
                    if selected.count >= maxCount { break }
                }
            }
        } catch {
            legacyIdleValidationStatus = "Memory scan deferred; originals preserved"
            diag.noteModelState("legacy_idle_deferred")
            return
        }
        guard idleValidationStillSafe(revision: originalRevision, target: target, rules: rules)
        else { return }
        if exhausted { legacyValidationExhausted = true }
        if selected.isEmpty {
            legacyIdleValidationStatus = exhausted ?
                "No safe candidates for this language pair; see inventory and scan reasons below" :
                "Skipped \(legacyBatchSkipped) incompatible older entries"
            return
        }

        // Model availability varies by source when the user selects Automatic.
        var installed = Set<String>()
        for source in Set(selected.map(\.source)).sorted() {
            guard idleValidationStillSafe(revision: originalRevision, target: target, rules: rules)
            else { return }
            let from = Locale.Language(identifier: source)
            let to = Locale.Language(identifier: target)
            if from.languageCode != to.languageCode,
               await pairStatus(from, to) == .installed { installed.insert(source) }
        }
        guard idleValidationStillSafe(revision: originalRevision, target: target, rules: rules)
        else { return }
        let eligible = selected.filter { installed.contains($0.source) }
        legacyBatchSkipped += selected.count - eligible.count
        legacyScanReasons["Language model unavailable", default: 0] += selected.count - eligible.count
        let items = eligible.map { IdleLegacyWorkItem(id: $0.id, source: $0.source, text: $0.text) }
        let chunks = IdleLegacyBatchPolicy.chunks(items, limit: maxCount)
        legacyBatchTotal = items.count
        guard !chunks.isEmpty else {
            legacyIdleValidationStatus = "No installed models for these older entries"
            return
        }
        legacyIdleValidationStatus = "Translating \(items.count) entries with \(workers) workers…"

        // Task-group concurrency is bounded. Results contain only strings; the
        // SQLite actor alone owns durable writes after all sessions finish.
        let results: [(Int, [String]?)] = await withTaskGroup(
            of: (Int, [String]?).self, returning: [(Int, [String]?)].self
        ) { group in
            var next = 0
            func enqueue() {
                guard next < chunks.count else { return }
                let i = next
                next += 1
                let chunk = chunks[i]
                group.addTask {
                    let values = await Self.translateIdleChunk(
                        source: chunk.source, target: target, texts: chunk.items.map(\.text))
                    return (i, values)
                }
            }
            for _ in 0..<min(workers, chunks.count) { enqueue() }
            var output: [(Int, [String]?)] = []
            while let value = await group.next() {
                output.append(value)
                let completedChunk = chunks[value.0]
                legacyBatchProcessed += completedChunk.items.count
                legacyValidationElapsedSeconds = max(0, Date().timeIntervalSince(legacyBatchStartedAt))
                legacyIdleValidationStatus = "Translated \(legacyBatchProcessed)/\(items.count) • saving after batch"
                if idleValidationStillSafe(revision: originalRevision, target: target, rules: rules) {
                    enqueue()
                } else { group.cancelAll() }
            }
            return output
        }
        guard idleValidationStillSafe(revision: originalRevision, target: target, rules: rules)
        else {
            legacyIdleValidationStatus = "Stopped for live translation; old memory unchanged"
            diag.noteModelState("legacy_idle_deferred")
            return
        }
        var commits: [TranslationMemoryStore.LegacyIdleConfirmation] = []
        for (index, values) in results {
            let chunk = chunks[index]
            guard let values, values.count == chunk.items.count else {
                legacyBatchSkipped += chunk.items.count
                continue
            }
            for (item, translated) in zip(chunk.items, values) {
                guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    legacyBatchSkipped += 1
                    continue
                }
                commits.append(.init(id: item.id,
                    currentKey: PipelineSafety.cacheKey(
                        source: item.source, target: target, text: item.text,
                        protectedWords: [], rules: rules),
                    freshOutput: translated))
            }
        }
        guard !commits.isEmpty else {
            legacyIdleValidationStatus = "Models returned no valid translations; originals preserved"
            diag.noteModelState("legacy_idle_deferred")
            return
        }
        guard idleValidationStillSafe(revision: originalRevision, target: target, rules: rules)
        else { return }
        do {
            memoryRevision += 1
            let health = try await memoryStore.confirmIdleLegacyBatch(
                commits, revision: memoryRevision)
            legacyValidatedThisSession += commits.count
            legacyBatchCompleted = commits.count
            diag.noteLegacyBatch(selected: items.count, committed: commits.count,
                skipped: legacyBatchSkipped, workers: workers,
                durationMs: max(0, Date().timeIntervalSince(legacyBatchStartedAt) * 1000))
            applyMemoryHealth(health)
            let elapsed = max(0.1, Date().timeIntervalSince(legacyBatchStartedAt))
            let rate = Double(commits.count) * 60.0 / elapsed
            legacyAverageRate = legacyAverageRate == 0 ? rate : (0.6 * legacyAverageRate + 0.4 * rate)
            legacyEntriesPerMinute = legacyAverageRate
            if let health = memoryHealth, legacyAverageRate > 0 {
                legacyEstimatedRemainingMinutes = Double(health.legacyUnverified) / legacyAverageRate
            }
            legacyValidationElapsedSeconds = elapsed
            legacyIdleValidationStatus = "Validated \(commits.count)/\(items.count), skipped \(legacyBatchSkipped)"
            diag.noteModelState("legacy_idle_completed")
        } catch {
            legacyIdleValidationStatus = "Batch deferred; original memory preserved"
            diag.noteModelState("legacy_idle_deferred")
        }
    }

    // MARK: Keep the translator warm
    private static let warmWords = ["en": "Hello.", "pt": "Olá.", "es": "Hola.", "fr": "Bonjour.", "de": "Hallo.",
                                    "it": "Ciao.", "ja": "こんにちは。", "ko": "안녕하세요.", "zh": "你好。", "ru": "Привет."]
    private static let warmSentences = [
        "en": "We need to find out what happened here.",
        "pt": "Precisamos descobrir o que aconteceu aqui.",
        "es": "Tenemos que descubrir qué pasó aquí.",
        "fr": "Nous devons découvrir ce qui s’est passé ici.",
        "de": "Wir müssen herausfinden, was hier passiert ist.",
        "it": "Dobbiamo scoprire cosa è successo qui.",
        "ja": "ここで何が起きたのか調べなければなりません。",
        "ko": "여기서 무슨 일이 있었는지 알아봐야 합니다.",
        "zh": "我们需要弄清楚这里发生了什么。",
        "ru": "Нам нужно выяснить, что здесь произошло."]

    /// Loads the translation models before they're needed so the first real sentence isn't slow.
    func prewarm() async {
        if activeTranslationSystem != .legacy {
            guard #available(iOS 26.4, *) else {
                modelReadiness.prepare(.unavailable)
                modeAvailability = activeTranslationSystem == .lowLatency ? "Explicit low latency requires iOS 26.4 or later" : "Fast recovery needs iOS 26.4; Apple default fallback remains available"
                return
            }
            guard !captureAlive, initialWarmupTask == nil, !Task.isCancelled else { return }
            let code = sourceCode != "auto" ? sourceCode : SubtitlePerformancePolicy.predictiveSource(
                selected: sourceCode, detected: detectedLang == "–" ? nil : detectedLang,
                lastResolved: ud.string(forKey: "lastEffectiveSource"),
                ageSeconds: Date().timeIntervalSince1970 - ud.double(forKey: "lastEffectiveSourceAt"), enabled: flag("predictiveWarmup", true))
            guard let code, code != targetCode else {
                initialWarmupProgress = "Waiting for a known source language before initial warm-up"
                return
            }
            let destination = targetCode, system = activeTranslationSystem, context = modeSessionID
            let id = UUID(); initialWarmupID = id
            let task = Task { [weak self] in
                guard let self else { return }
                await self.refreshModePreparation(source: code, target: destination, system: system)
                guard !Task.isCancelled, context == self.modeSessionID, !self.captureAlive,
                      self.flag("keepWarm", true), self.runtimePolicy.allowsPrewarming, !self.paused,
                      !ProcessInfo.processInfo.isLowPowerModeEnabled,
                      ProcessInfo.processInfo.thermalState == .nominal || ProcessInfo.processInfo.thermalState == .fair,
                      self.modelReadiness.languages == .complete else { return }
                guard let samples = InitialWarmupSamples.units(source: code) else {
                    self.initialWarmupProgress = "No initial sample for this language; live translation remains available"
                    return
                }
                let deadline = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard !Task.isCancelled, let self, self.initialWarmupID == id else { return }
                    self.initialWarmupTask?.cancel(); self.modeService.cancelWarmup()
                    self.initialWarmupProgress = "Initial warm-up budget reached; waiting for outstanding work to return"
                }
                self.initialWarmupProgress = "Initial warm-up · once per language pair and strategy"
                let completed = await self.modeService.warmInitially(source: code, target: destination, system: system,
                    testMode: self.memoryTestMode.rawValue, samples: samples)
                deadline.cancel()
                if !Task.isCancelled, context == self.modeSessionID, !self.captureAlive {
                    if let completed {
                        self.initialWarmupProgress = completed == 0 ? self.modeService.warmupSkipDescription : "Initial warm-up finished · \(completed) strategy/strategies exercised"
                    } else { self.initialWarmupProgress = "Warm-up incomplete or deferred; live translations can retry normally" }
                }
            }
            initialWarmupTask = task
            await task.value
            if initialWarmupID == id { initialWarmupTask = nil }
            return
        }
        guard !Task.isCancelled, runtimePolicy.allowsPrewarming, flag("keepWarm", true), !paused,
              !legacyValidationBusy, !busy, !warming,
              queued == nil, !waitingToDisplay,
              Date().timeIntervalSince(lastWarm) > 25 else { return }
        warming = true
        defer { warming = false }
        let code: String
        var predicted = false
        if sourceCode != "auto" { code = sourceCode }
        else if let l = lockedLang { code = l }
        else if detectedLang != "–" { code = detectedLang }
        else if let previous = SubtitlePerformancePolicy.predictiveSource(
            selected: sourceCode, detected: nil,
            lastResolved: ud.string(forKey: "lastEffectiveSource"),
            ageSeconds: Date().timeIntervalSince1970 -
                ud.double(forKey: "lastEffectiveSourceAt"),
            enabled: flag("predictiveWarmup", true)) {
            code = previous
            predicted = true
        } else {
            warmupStatus = "Waiting for source language"
            if Date().timeIntervalSince(lastUnresolvedWarmupNotice) > 25 {
                lastUnresolvedWarmupNotice = Date()
                diag.noteModelState("warmup_source_unresolved")
            }
            return
        }
        let workContext = contextRevision
        let destination = targetCode
        let src = Locale.Language(identifier: code)
        let target = Locale.Language(identifier: destination)
        if modelReadiness.source != code || modelReadiness.target != destination {
            modelReadiness = TranslationReadiness(source: code, target: destination)
            restoreModelRun(source: code, target: destination, system: .legacy)
        }
        guard src.languageCode != target.languageCode,
              let word = Self.warmWords[src.languageCode?.identifier ?? code] else { return }
        // Avoid reloading the same model while a usable warm session exists.
        let warmKey = "\(src.minimalIdentifier)>\(destination)|\((activeTranslationSystem == .lowLatency) ? "low" : "default")"
        guard directSession == nil || directKey != warmKey else {
            warmupStatus = "Ready"
            // Retaining a handle alone is not evidence that the model ran.
            if modelReadiness.sessions != .complete { modelReadiness.explanation = "A Legacy session is retained; waiting for an observed model request." }
            return
        }
        modelReadiness.prepare(.checkingLanguages)
        let installed = await pairStatus(src, target) == .installed
        guard !Task.isCancelled,
              workContext == contextRevision, !busy, queued == nil,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else {
            if workContext == contextRevision {
                modelReadiness.languages = .pending; modelReadiness.activeSince = nil
                modelReadiness.explanation = "Preparation deferred for live work or current power and temperature conditions."
            }
            return
        }
        guard installed else { modelReadiness.prepare(.languagesUnavailable); return }
        modelReadiness.prepare(.languagesInstalled)
        // 2.2.1 (E18): with "liveWarmupLegacy" off, Legacy does not start a synthetic model call during live capture.
        if captureAlive, !flag("liveWarmupLegacy", true) {
            warmupStatus = "Ready"
            return
        }
        // Direct sessions can warm independently; the iOS 18 hosted path has one continuation.
        guard #available(iOS 26.0, *) else { return }
        lastWarm = Date()
        let t0 = Date()
        warmupStatus = predicted ? "Predictive warm-up…" : "Warming up…"
        modelReadiness.prepare(.creatingSessions)
        if captureAlive, diag.enabled { diag.s.warmupsDuringCapture += 1 } // 2.2.1 (E18): evidence for the report
        diag.noteModelState("warmup_started")
        if predicted { diag.noteModelState("warmup_predicted_source") }
        let session: TranslationSession
        if #available(iOS 26.4, *), (activeTranslationSystem == .lowLatency) {
            session = TranslationSession(installedSource: src, target: target, preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: src, target: target)
        }
        warmupSuperseded = false
        warmupSession = session
        defer { warmupSession = nil }
        // Exercise both a short word and a subtitle-length sentence on the same
        // retained session. Synthetic output never enters memory/history/PiP.
        let sample = Self.warmSentences[src.languageCode?.identifier ?? code]
        let warmed = await runBatch(session, [word] + (sample.map { [$0] } ?? []), warmup: true)
        guard !Task.isCancelled, !warmupSuperseded, workContext == contextRevision else {
            if workContext == contextRevision {
                modelReadiness.execution = .pending; modelReadiness.sessions = .pending
                modelReadiness.activeSince = nil; modelReadiness.explanation = "Warm-up yielded to live translation; it did not establish readiness."
            }
            warmupStatus = "Deferred for live translation"
            diag.noteModelState("warmup_preempted")
            return
        }
        warmupLastDurationMs = Date().timeIntervalSince(t0) * 1000
        warmupStatus = warmed == nil ? "Warm-up failed" :
            (predicted ? "Predicted source prepared" : "Ready")
        diag.noteModelState(warmed == nil ? "warmup_failed" : "warmup_succeeded",
            durationMs: Date().timeIntervalSince(t0) * 1000)
        if warmed != nil, !busy, workContext == contextRevision,
           (directSession == nil || directKey != warmKey) {
            directSession = session
            directKey = warmKey
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        if ms > 300 { diag.event(.translation, "Warmed up the translator in \(Int(ms)) ms") }
    }

    /// Translate the current text again from scratch (ignores the cache).
    func retranslate() {
        guard !original.isEmpty else { return }
        invalidatePending()
        if memoryTestMode != .temporaryMemory { ram.clear() }
        bypassMemory = true
        lastHandled = ""
        let blocks = original.components(separatedBy: "\n")
        diag.log("Retranslating current text")
        queuedPacket = nil
        queuedTs = Date().timeIntervalSince1970
        enqueue(blocks)
    }

    func download(_ code: String) {
        guard code != targetCode else {
            downloadMessage = "Select different source and target languages."
            return
        }
        let coverage = languageCoverage(for: code)
        if coverage.overall(for: pendingTranslationSystem) == .unchecked {
            let destination = targetCode, system = pendingTranslationSystem
            downloadMessage = "Checking installed packs before requesting a download"
            Task { [weak self] in
                guard let self else { return }
                await self.refreshStatus()
                guard destination == self.targetCode, system == self.pendingTranslationSystem else { return }
                if self.languageCoverage(for: code).overall(for: system) == .unchecked {
                    self.downloadMessage = "Could not verify language availability. Try Refresh Languages."
                } else {
                    self.download(code)
                }
            }
            return
        }
        guard let strategy = coverage.nextDownload(for: pendingTranslationSystem) else {
            downloadMessage = coverage.explanation(for: pendingTranslationSystem)
            toast(downloadMessage)
            return
        }
        let source = Locale.Language(identifier: code)
        let target = Locale.Language(identifier: targetCode)
        let requested: TranslationSession.Configuration
        if strategy == .lowLatency {
            guard #available(iOS 26.4, *) else {
                downloadMessage = "Explicit Low Latency requires iOS 26.4 or newer."
                return
            }
            requested = .init(source: source, target: target, preferredStrategy: .lowLatency)
        } else {
            // A new configuration allows the hosted view to request permission
            // for the Apple Default pack without touching any saved translations.
            requested = .init(source: source, target: target)
        }
        lastDownloadCode = code
        downloadInFlight = code
        if downloadConfig == requested {
            // The same request again (for example "Try again" after a failure): an unchanged value would not run
            // the hosted translation task a second time, and the spinner would never stop.
            downloadConfig?.invalidate()
        } else {
            downloadConfig = requested
        }
    }
    func runDownload(_ session: TranslationSession) async {
        defer { downloadInFlight = nil }       // success, failure or cancellation: the spinner always stops (U4)
        let workContext = contextRevision
        var prepared = false
        do {
            try await session.prepareTranslation()
            prepared = true
            downloadMessage = "Language pack ready"
            toast(downloadMessage)
        } catch {
            downloadMessage = "Download failed: " + error.localizedDescription
            toast("Download failed. Check Languages for details.")
        }
        await refreshStatus()
        if prepared, workContext == contextRevision, !paused, !manualMode {
            invalidatePending(); rotRev += 1; syncConfig()
            if !captureAlive { Task { [weak self] in await self?.prewarm() } }
        }
    }

    /// Re-reads everything after settings were changed in bulk.
    func reloadSettings() {
        translationSystemChanged()
        testModeSettingsChanged()
        suppressRecent = true
        sourceCode = ud.string(forKey: "source") ?? "auto"
        targetCode = ud.string(forKey: "target") ?? "en"
        suppressRecent = false
        invalidatePending()
        if lastConfiguredRotation != frameRotMode { rotationSettingChanged() }
        else { rotRev += 1; syncConfig() }
        applyStyle()
        applyWindowSize()
        applyHistoryRetention()
        objectWillChange.send()
    }
    // MARK: Test
    func runTest() {
        // 2.2.1 (E8): a language-pair test is manual work and must not land inside a live Test Run.
        if captureAlive {
            status = "Stop the broadcast first, then test the language pair."
            return
        }
        let samples = ["en": "Hello, how are you today?", "pt": "Olá, como você está hoje?",
                       "es": "Hola, ¿cómo estás hoy?", "fr": "Bonjour, comment allez-vous aujourd'hui ?",
                       "de": "Hallo, wie geht es dir heute?", "it": "Ciao, come stai oggi?",
                       "ja": "こんにちは、今日はお元気ですか？", "ko": "안녕하세요, 오늘 어떠세요?",
                       "zh": "你好，你今天好吗？", "ru": "Привет, как дела сегодня?"]
        var key = Locale.Language(identifier: sourceCode == "auto" ? "en" : sourceCode).languageCode?.identifier ?? "en"
        if key == (Locale.Language(identifier: targetCode).languageCode?.identifier ?? "") { key = "es" }
        lastHandled = ""
        status = "Testing…"
        queuedTs = Date().timeIntervalSince1970
        queuedPacket = nil
        enqueue([samples[key] ?? samples["en"]!])
    }

    static let fallbackLanguages: [LangItem] = [
        ("en","English"),("es","Spanish"),("fr","French"),("de","German"),("it","Italian"),
        ("pt","Portuguese"),("ru","Russian"),("ja","Japanese"),("ko","Korean"),
        ("zh-Hans","Chinese (Simplified)"),("zh-Hant","Chinese (Traditional)"),("ar","Arabic"),
        ("tr","Turkish"),("hi","Hindi"),("id","Indonesian"),("nl","Dutch"),("pl","Polish"),
        ("th","Thai"),("vi","Vietnamese"),("uk","Ukrainian")
    ].map { LangItem(code: $0.0, name: $0.1) }
}
