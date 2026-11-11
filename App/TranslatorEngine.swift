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

    @Published var lockedLang: String? = nil { didSet { if diag.enabled { diag.s.lockedLang = lockedLang ?? "–" } } }
    // Output + diagnostics
    @Published var original = ""
    @Published var translated = ""
    @Published var status = "Idle"
    @Published var warmupStatus = "Waiting for source language"
    @Published var legacyIdleValidationStatus = "Disabled"
    @Published var legacyValidatedThisSession = 0
    @Published var legacyBatchTotal = 0
    @Published var legacyBatchCompleted = 0
    @Published var legacyBatchSkipped = 0
    @Published var legacyBatchWorkers = 0
    @Published var legacyBatchActive = false
    @Published var legacyBatchProcessed = 0
    @Published var legacyEntriesPerMinute = 0.0
    @Published var legacyEstimatedRemainingMinutes: Double?
    @Published var legacyValidationElapsedSeconds = 0.0
    @Published var warmupLastDurationMs: Double?
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
    lazy var historyWriter: DebouncedAction = DebouncedAction(delay: .seconds(1)) { [weak self] in self?.saveHistory() }
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
    @Published var modeAvailability = ""
    @Published var modeWorkActivity: TranslationActivity?
    var modeActivityCaption: ModeCaption?
    var modeActivitySelected = false
    var preparationTicket = UUID()
    var lastModePreparationPair = ""
    var lastModePreparationAt = Date.distantPast

    @Published var modelReadiness = TranslationReadiness()
    @Published var backendActivity = TranslationBackendActivity()
    @Published var currentRuntimeConditions = ""
    @Published var initialWarmupProgress = ""
    var initialWarmupTask: Task<Void, Never>?
    var initialWarmupID = UUID()
    var observedModelRuns: [String: (at: Date, milliseconds: Double?)] = [:]
    /// v2.0.0 L2 (diagnostics only): Legacy model calls in flight per
    /// TranslationSession and the last return, to split confirmed model time
    /// by whether another session's call was running or ended < 1.5 s earlier.
    var legacyModelInFlight: [ObjectIdentifier: Int] = [:]
    var legacyLastModelReturn: (session: ObjectIdentifier, at: Double)?
    /// 2.4.0 (diagnostics only): when each Legacy call in flight started, and the span of the last one that
    /// returned, to measure how long a confirmed call ran at the same time as a call on another session.
    var legacyModelStart: [ObjectIdentifier: Double] = [:]
    var legacyLastModelSpan: (session: ObjectIdentifier, start: Double, end: Double)?

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

    func refreshModePreparation(source: String, target: String, system: TranslationSystem) async {
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
    var captureIdentity = CaptureSessionIdentityGate()
    var modeSessionID = UUID()
    var modeDiagnosticEpochs: [UUID: Date] = [:]
    private var modeRevision = 0
    var modeLastIdentity = ""
    var modeMemoryOrigins: [String: String] = [:]
    /// v2.0.0 G6: the SQLite outcome of the first-sighting probe, reused by the
    /// confirmation probe of the same key moments later (RAM is still checked
    /// live first). Timeouts are never reused.
    private var recentSQLiteProbes: [String: (hit: MemoryLookupResult, at: Double, context: Int, session: UUID)] = [:]
    var modePlans: [String: ([[CaptionTranslationUnit]], Packet, ModeCaption)] = [:]
    var modePreparedPlans = ExactPlanReuseCache<ModePlanIdentity, ModePreparedPlan>(capacity: 4)

    var modeModelTimings: [String: ModeModelTiming] = [:]
    private var modeConfirmationUptime: [String: Double] = [:]
    private var modeResultReadyUptime: [String: Double] = [:]
    // Hash only once per full capture-session/caption revision. The trace
    // never exports OCR text or an unhashed fingerprint. This removes repeated
    // SHA-256 and hex formatting from the high-frequency LL/Hybrid event path.
    var modeFingerprintDigests: [String: String] = [:]
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

    func handleModeCaption(_ blocks: [String], packet: Packet) {
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
        modeCoordinator.allowsReuse = memoryTestMode.allowsReuse && !bypassMemory
        let fastPack = languageCoverage(for: source).lowLatency
        let fastPackKnownMissing = fastPack == .supported || fastPack == .unsupported
        modeCoordinator.fastRecoveryInstalled = !fastPackKnownMissing
        modeCoordinator.adaptiveHybrid = flag("adaptiveSpeculation", true) && !fastPackKnownMissing
        modeCoordinator.hybridSwitchGuard = flag("hybridSwitchGuard", true)
        modeCoordinator.hybridPinnedBackend = TranslationHotPathAB.hybridPinnedBackend
        // 2.4.0: a first sighting whose pixel check is armed is confirmed one frame later. An Apple Default call
        // started for it now would only be in the way when the text is not the final one, so it is not started.
        // Low Latency calls are short and stay as they were.
        let deferredArmed = !confirmed && packet.pixelArmed == true && TranslationHotPathAB.deferArmedSpeculation &&
            modeCoordinator.nextSpeculativeStrategy == .appleDefault
        if deferredArmed { noteModeEvent(caption, reason: "speculation_deferred_armed", duration: nil) }
        let admitted = !deferredArmed && speculationAllowed && !ProcessInfo.processInfo.isLowPowerModeEnabled &&
            memoryTestMode.allowsSpeculation && flag("translateAhead", true) &&
            thermal != .serious && thermal != .critical &&
            SpeculationPolicy.credible(lines: packet.lines, threshold: num("speculationConfidence", 0.85))
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

    var contextRevision = 0
    var generation = 0
    var legacyRequestID = UUID()
    var legacySpeculative = false
    var latestBlocks: [String] = []
    var lastHandled = ""
    var queued: [String]?
    var queuedTs: Double = 0
    var currentTs: Double = 0
    var queuedPacket: Packet?
    var currentPacket: Packet?
    var queuedAt = Date()
    var currentQueuedAt = Date()
    var processingStarted = Date()
    var savedRequests = 0
    var warming = false
    var legacyValidationBusy = false
    var idleValidationTask: Task<Void, Never>?
    var legacyValidationCursor: Int64 = 0
    var legacyValidationExhausted = false
    var legacyScanFingerprint = ""
    @Published var legacyValidationInventory: [String: Int] = [:]
    @Published var legacyScanReasons: [String: Int] = [:]

    var lastIdleValidationAttempt = Date.distantPast
    var legacyBatchStartedAt = Date.distantPast
    var legacyAverageRate = 0.0
    var languageCache: [String: (NLLanguage?, [NLLanguage: Double])] = [:]
    var drainTask: Task<Void, Never>?
    var activeCandidateText = ""
    var activeCandidateID: String?
    var activeCandidateConfirmed = false
    var activeCandidatePresented = false
    var activeCandidateConfirmedAt = Date.distantPast
    var deferredConfirmedPacket: Packet?
    var confirmedHandoffDeadlineTask: Task<Void, Never>?
    var deferredConfirmedReceivedAt = Date.distantPast
    var specPacket: Packet?
    var currentSpeculativeText: String?
    var subtitleRegions = SubtitleRegions()
    var movieTextFocus = MovieTextFocus()
    var languageFailures = 0
    var rulesSnapshot = "", rulesDigest = ""
    var busy = false
    var activeQueueOwner = ModelQueueOwner.scheduling
    var queuedWaitOwner = ModelQueueOwner.scheduling
    var modelUnitKeysInFlight = Set<String>()
    var modelContextInFlight: Int?
    var showing = false
    private var lastShowReusedFrame = false
    var pendingTexts: [String] = []
    var legacyContinuation: CheckedContinuation<[String]?, Never>?
    var lastPacketDate = Date.distantPast
    var lastTextDate = Date()
    /// Where the session-limit countdown starts: the session start, or the last resume (E2).
    var limitBase: Date?
    var lastShowDate = Date.distantPast
    let modelPerf = OSSignposter(subsystem: "com.diam0ndnex.screenlingo", category: "model")
    var directSession: TranslationSession?
    let speculativeSessions = SpeculativeSessionOwner<TranslationSession> { session in
        if #available(iOS 26.0, *) { session.cancel() }
    }
    var directKey = ""
    var clearTask: Task<Void, Never>?
    var tickCount = 0
    var lastThermalSyncState: ProcessInfo.ThermalState?
    var toastToken = 0
    // Translation speed system
    var specQueued: [String]?
    var lastSpecText = ""
    var lastWarm = Date.distantPast
    var lastUnresolvedWarmupNotice = Date.distantPast
    var startupWarmupTask: Task<Void, Never>?
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
    var appInterfaceVisible = true
    var memoryMutationInProgress = false
    var memoryRetryAttempts = 0
    var storageFullRetryNotBefore = Date.distantPast
    var memoryPressureCapacity: Int?
    let processMemory = ProcessTranslationMemory()
    @Published var memoryTestMode = TranslationTestMode.normal
    @Published var temporaryMemoryEntries = 0
    var memoryReady = false
    var segmentationCache = SegmentationCache(capacity: 512)
    var bypassMemory = false
    var memoryRevision = 0
    var memoryDirty = false
    private var lastMemorySave = Date.distantPast
    var availCache: [String: (Date, LanguageAvailability.Status)] = [:]
    var suppressRecent = false
    let speech = AVSpeechSynthesizer()
    // Reading-order calibration
    var orderVote = 0.0
    var votesSinceChange = 0
    var trial = 0
    var autoRot = 0
    var rotRev = 0
    var calibrated = false
    // Language lock
    var languageRouter = SourceLanguageRouter()
    var languageContext = LanguageContext()
    var rotationBudget = RotationBudget()
    var lastConfiguredRotation = "auto"
    var lastCaptureOrientation: Int?

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
                !self.modeCoordinator.pinnedToLowLatency &&
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

    // MARK: PiP
    /// Starts the PiP window (retrying while iOS gets ready), then calls `done`.
    /// Set when "Open the floating window when capture starts" could not run because the app was not active (E17).
    var autoOpenSkipped = false

    func eraseHistory() {
        undoHistory = nil
        history = []
        historyWriter.cancel()      // the empty list must not be written again after the keys are removed
        ud.removeObject(forKey: "historyData")
        ud.removeObject(forKey: "screenlingo.history.v1")
    }

    func applyHistoryRetention() {
        let days = int("historyRetentionDays", 0)
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let kept = history.filter { $0.starred || $0.date >= cutoff }
        if kept.count != history.count { history = kept }     // no write when nothing expired (E15)
    }

    /// Turns raw OCR lines into the text blocks worth translating (area, rules, own window, blocks, noise…).
    /// `count` is false for early sightings so the statistics are not counted twice.
    /// 2.2.1 (E13): a one-character CJK line is translated only when it came from a confirmed packet (not the early
    /// sighting) and the Advanced setting is on.
    var extractingConfirmedPacket = false
    /// 2.2.3 (L2). With the switch on (iOS 26 direct sessions only) the confirmed caption starts now instead of
    /// after the cancelled speculative call returns. The confirmed call uses the direct session; the speculative call
    /// owns its own disposable session, so the two never share a session. The old drain exits on resume.
    func detachCancelledSpeculationIfEnabled() {
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
    func presentQueuedFromRAMIfComplete() -> Bool {
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

    func handleClear() {
        guard !frozen, flag("autoClear", true), showing, clearTask == nil else { return }
        let hold = num("clearHold", 1.0)
        if hold <= 0 { performClear(); return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled else { return }
            self?.performClear()
        }
    }

    /// 2.2.3 (L2): bumped when a cancelled speculative drain is detached so a confirmed drain can start at once.
    /// A drain that finds its epoch changed must not touch shared drain state. Never changes with the switch off.
    var drainEpoch = 0
    var detachedSpeculationAt: Date?

    var preparedUnits = ExactPlanReuseCache<PreparedUnitIdentity, [PreparedSourceUnit]>(capacity: 12)

    @discardableResult
    func show(_ text: String, _ result: String, timing: PresentationTiming) -> Bool {
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

    // MARK: Keep the translator warm
    static let warmWords = ["en": "Hello.", "pt": "Olá.", "es": "Hola.", "fr": "Bonjour.", "de": "Hallo.",
                                    "it": "Ciao.", "ja": "こんにちは。", "ko": "안녕하세요.", "zh": "你好。", "ru": "Привет."]
    static let warmSentences = [
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
