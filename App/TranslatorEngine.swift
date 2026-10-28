// Screen Translator – App – v0.11.0
import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import Network
import os

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
    func range(mode: TranslateMode) -> ClosedRange<Double> {   // y: 0 = bottom, 1 = top
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

/// One speaker's line inside a block (label stays untranslated).
private struct TUnit {
    var label: String?
    var sentences: [String]
    var out: [String?]
    var tokens: [(String, String)]
}

@MainActor
final class TranslatorEngine: ObservableObject {
    /// Everything a preset remembers.
    static let presetKeys = [
        "source", "target", "mode", "area", "customY0", "customY1", "speed", "stability", "minTextH", "ignoreList",
        "frameRot", "dropNoise", "boost", "skipUnchanged", "cleanOCR", "slang", "speakerDetect", "highlightNames",
        "langLock", "neverTranslate", "sourceFixes", "glossary", "winSize", "theme", "textSize", "pipFont",
        "showOriginal", "autoClear", "clearHold", "minDisplay", "autoOpenPiP", "haptics", "speak", "speechRate",
        "autoCopy", "adaptive", "idleMinutes", "translateAhead", "keepWarm", "remember", "adaptiveSpeculation", "protectConfirmedPresentation", "predictiveWarmup",
        "displayPolicy", "pipWeight", "pipAlignment", "pipLineSpacing", "pipPadding", "originalFraction", "pipScale", "speakerAccent", "heartbeatInterval", "hapticStrength", "autoCopyFormat", "interruptSpeech", "ocrConfidence", "ocrCorrection", "idleBackoff", "coolMode", "adaptiveOCR", "adaptiveConfirmation", "subtitleTracking", "selectiveSpeculation", "speculationConfidence", "confirmationDeadline", "smartCool", "steadyCaptions", "languageRecovery", "deduplicateCopies", "continuousRotation", "contextualLanguage"
    ]
    /// App look & behaviour that presets do not touch.
    static let interfaceKeys = ["legacyIdleValidationEnabled", "accent", "keepAwake", "saveHistory", "historyRetentionDays", "uiHaptics", "homePresets", "homeTools", "homeQuick", "homeStatus", "homeRecent", "privateSession", "diagIncludeText", "readerFont", "readerSpacing", "readerWidth", "historyCapacity", "diagSamples", "diagnosticsEnabled", "detailedCollection", "freshTranslationTest", "showSessionSpeakers", "homeMetrics", "homeQuickExpanded", "homeDetailsExpanded", "photoOCREdge", "photoAutoTranslate", "sessionLimit", "readerSize", "readerOriginal", "readerAlignment"]
    static var settingKeys: [String] { presetKeys + interfaceKeys }
    static let defaults: [String: Any] = [
        "source": "auto", "target": "en", "mode": "movie", "area": "smart", "customY0": 0.0, "customY1": 0.5,
        "speed": "balanced", "stability": 2, "minTextH": 0.0, "ignoreList": "", "frameRot": "auto",
        "dropNoise": true, "boost": 1, "skipUnchanged": true, "cleanOCR": true, "slang": true,
        "speakerDetect": true, "highlightNames": true, "langLock": true, "neverTranslate": "", "sourceFixes": "",
        "glossary": "", "winSize": "normal", "theme": "dark", "textSize": "auto", "pipFont": "standard",
        "showOriginal": false, "autoClear": true, "clearHold": 1.0, "minDisplay": 0.0, "autoOpenPiP": true,
        "haptics": false, "speak": false, "speechRate": 0.5, "autoCopy": false, "adaptive": true, "idleMinutes": 0,
        "translateAhead": true, "keepWarm": true, "remember": true,
        "adaptiveSpeculation": true, "protectConfirmedPresentation": true, "predictiveWarmup": true,
        "displayPolicy": "immediate", "pipWeight": "bold", "pipAlignment": "left", "pipLineSpacing": 0.0,
        "pipPadding": 24.0, "originalFraction": 0.27, "pipScale": 1.0, "speakerAccent": "blue", "heartbeatInterval": 1.0,
        "readerFont": "rounded", "readerSpacing": 8.0, "readerWidth": "full", "historyCapacity": 500,
        "diagSamples": 600, "homeMetrics": true, "homeQuickExpanded": false,
        "homeDetailsExpanded": false, "hapticStrength": "light", "autoCopyFormat": "translation", "interruptSpeech": true,
        "photoOCREdge": 2400, "photoAutoTranslate": false,
        "adaptiveOCR": true, "adaptiveConfirmation": false, "subtitleTracking": true, "selectiveSpeculation": true,
        "speculationConfidence": 0.85, "confirmationDeadline": 0.6, "smartCool": true, "steadyCaptions": true,
        "languageRecovery": true, "deduplicateCopies": true, "continuousRotation": false, "contextualLanguage": true,
        "coolMode": false, "diagnosticsEnabled": true, "detailedCollection": false, "freshTranslationTest": false, "showSessionSpeakers": true,
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
    @Published var paused = false { didSet { invalidatePending(); syncConfig(); if !paused { enqueue(latestBlocks) } } }
    @Published var frozen = false
    @Published private(set) var manualMode = false
    @Published private(set) var sessionStarted: Date?
    @Published private(set) var sessionTranslations = 0
    @Published private(set) var sessionCharacters = 0
    @Published private(set) var downloadMessage = ""
    @Published var isTranslating = false
    @Published private(set) var waitingToDisplay = false
    private var presentationTask: Task<Void, Never>?
    private var presentationID = UUID()
    private var undoHistory: [HistoryItem]?
    @Published var toastText: String?
    @Published var detectedLang = "–"
    @Published var recentPairs: [String] = []
    @Published var memoryCount = 0
    // Languages
    @Published var languages: [LangItem] = TranslatorEngine.fallbackLanguages
    @Published var langStatus: [String: LanguageAvailability.Status] = [:]
    @Published var lockedLang: String? = nil { didSet { if diag.enabled { diag.s.lockedLang = lockedLang ?? "–" } } }
    // Output + diagnostics
    @Published var original = ""
    @Published var translated = ""
    @Published var status = "Idle"
    @Published private(set) var warmupStatus = "Waiting for source language"
    @Published private(set) var legacyIdleValidationStatus = "Disabled"
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
    @Published var captureAlive = false
    @Published var frames = 0
    @Published var ocrCount = 0
    @Published var extensionVersion = "–"
    @Published var pipActive = false
    @Published var lastRaw = ""
    @Published var ocrMs: Double = 0
    @Published var translateMs: Double = 0
    @Published var extFreeMB: Double = 0
    @Published var history: [HistoryItem] = [] { didSet { saveHistory() } }
    // Translation session plumbing
    @Published var legacyConfig: TranslationSession.Configuration?
    @Published var downloadConfig: TranslationSession.Configuration?

    let pip = PiPRenderer()
    let server = LoopbackServer()
    let diag = Diagnostics()
    let presets = PresetStore()
    let latency = LatencyMonitor()

    private var contextRevision = 0
    private var generation = 0
    private var legacyRequestID = UUID()
    private var legacySpeculative = false
    private var latestBlocks: [String] = []
    private var lastHandled = ""
    private var queued: [String]?
    private var queuedTs: Double = 0
    private var currentTs: Double = 0
    private var queuedPacket: Packet?
    private var currentPacket: Packet?
    private var queuedAt = Date()
    private var currentQueuedAt = Date()
    private var processingStarted = Date()
    private var savedRequests = 0
    private var warming = false
    private var legacyValidationBusy = false
    private var idleValidationTask: Task<Void, Never>?
    private var legacyValidationCursor: Int64 = 0
    private var legacyValidationExhausted = false
    private var legacyScanFingerprint = ""
    @Published private(set) var legacyValidationInventory: [String: Int] = [:]
    @Published private(set) var legacyScanReasons: [String: Int] = [:]

    private func refreshLegacyScanContext() {
        guard !legacyValidationBusy else { return }
        let installed = langStatus.filter { $0.value == .installed }.keys.sorted().joined(separator: ",")
        let fingerprint = "\(sourceCode)|\(targetCode)|\(memoryRuleToken)|\(memoryHealth?.totalEntries ?? 0)|\(memoryHealth?.legacyUnverified ?? 0)|\(installed)"
        if fingerprint != legacyScanFingerprint {
            legacyScanFingerprint = fingerprint
            legacyValidationCursor = 0
            legacyValidationExhausted = false
            legacyValidationInventory = [:]
            legacyScanReasons = [:]
        }
    }

    func rescanLegacyValidation() {
        guard idleValidationTask == nil else { return }
        legacyValidationCursor = 0
        legacyValidationExhausted = false
        startLegacyValidation()
    }

    private var lastIdleValidationAttempt = Date.distantPast
    private var legacyBatchStartedAt = Date.distantPast
    private var legacyAverageRate = 0.0
    private var languageCache: [String: (NLLanguage?, [NLLanguage: Double])] = [:]
    private var drainTask: Task<Void, Never>?
    private var activeCandidateText = ""
    private var activeCandidateID: String?
    private var activeCandidateConfirmed = false
    private var activeCandidatePresented = false
    private var activeCandidateConfirmedAt = Date.distantPast
    private var deferredConfirmedPacket: Packet?
    private var confirmedHandoffDeadlineTask: Task<Void, Never>?
    private var deferredConfirmedReceivedAt = Date.distantPast
    private var speculationWindow = SpeculativeWorkWindow()
    private var speculativeOrigins: [String: UInt64] = [:]
    private var specPacket: Packet?
    private var currentSpeculativeText: String?
    private var savedKeys = Set<String>()
    private var confirmedKeys = Set<String>()
    private var subtitleRegions = SubtitleRegions()
    private var movieTextFocus = MovieTextFocus()
    private var languageFailures = 0
    private var rulesSnapshot = "", rulesDigest = ""
    private var busy = false
    private var showing = false
    private var pendingTexts: [String] = []
    private var legacyContinuation: CheckedContinuation<[String]?, Never>?
    private var lastPacketDate = Date.distantPast
    private var lastTextDate = Date()
    private var lastShowDate = Date.distantPast
    private var cache: [String: String] = [:]
    private var directSession: TranslationSession?
    private var directKey = ""
    private var clearTask: Task<Void, Never>?
    private var tickCount = 0
    private var toastToken = 0
    // Translation speed system
    private var specQueued: [String]?
    private var specKeys = Set<String>()
    private var lastSpecText = ""
    private var lastWarm = Date.distantPast
    private var lastUnresolvedWarmupNotice = Date.distantPast
    private var startupWarmupTask: Task<Void, Never>?
    let memoryStore = TranslationMemoryStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScreenLingo/TranslationMemory", isDirectory: true))
    @Published var memoryHealth: MemoryStoreHealth?
    @Published var memoryPendingWrites = 0
    @Published var memoryFailure: String?
    private var pendingMemory: [String: String] = [:]
    // A proof is recorded only when the current model generated the result for a
    // confirmed subtitle; speculative/ RAM/ SQLite reuse never counts as proof.
    private var pendingLegacyProof: [String: String] = [:]
    private var memorySaving = false
    private var memoryMutationInProgress = false
    private var memoryRetryAttempts = 0
    private var storageFullRetryNotBefore = Date.distantPast
    private var memoryPressureCapacity: Int?
    private var memoryReady = false
    private var cacheUse: [String: UInt64] = [:]
    private var cacheClock: UInt64 = 0
    private var segmentationCache = SegmentationCache(capacity: 512)
    private var bypassMemory = false
    private var memoryRevision = 0
    private var memoryDirty = false
    private var lastMemorySave = Date.distantPast
    private var availCache: [String: (Date, LanguageAvailability.Status)] = [:]
    private var suppressRecent = false
    private let speech = AVSpeechSynthesizer()
    // Reading-order calibration
    private var orderVote = 0.0
    private var votesSinceChange = 0
    private var trial = 0
    private var autoRot = 0
    private var rotRev = 0
    private var calibrated = false
    // Language lock
    private var languageRouter = SourceLanguageRouter()
    private var languageContext = LanguageContext()
    private var rotationBudget = RotationBudget()
    private var lastConfiguredRotation = "auto"
    private var lastCaptureOrientation: Int?

    // Self-reading protection: what the PiP window currently shows, and where it is on screen
    private let placeholderGrams = TextSim.grams("Waiting for screen text… Listening…")
    private var renderedGrams = TextSim.grams("Waiting for screen text… Listening…")
    private var sourceGrams: Set<String> = []
    private var pipRegion: CGRect?
    private var pipRegionStamp = Date.distantPast

    // MARK: Settings readers
    private var ud: UserDefaults { .standard }
    private func flag(_ k: String, _ d: Bool) -> Bool { (ud.object(forKey: k) as? Bool) ?? d }
    private func num(_ k: String, _ d: Double) -> Double { (ud.object(forKey: k) as? Double) ?? d }
    private func int(_ k: String, _ d: Int) -> Int { (ud.object(forKey: k) as? Int) ?? d }
    private func list(_ k: String, lower: Bool) -> [String] {
        (ud.string(forKey: k) ?? "")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { lower ? $0.trimmingCharacters(in: .whitespaces).lowercased() : $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    private func pairs(_ k: String) -> [(String, String)] {
        (ud.string(forKey: k) ?? "").split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let from = parts[0].trimmingCharacters(in: .whitespaces)
            let to = parts[1].trimmingCharacters(in: .whitespaces)
            return from.isEmpty ? nil : (from, to)
        }
    }
    private var mode: TranslateMode { TranslateMode(rawValue: ud.string(forKey: "mode") ?? "") ?? .movie }
    private var area: OCRArea { OCRArea(rawValue: ud.string(forKey: "area") ?? "") ?? .smart }
    private var windowSize: WindowSize { WindowSize(rawValue: ud.string(forKey: "winSize") ?? "") ?? .normal }
    private var speed: SpeedPreset { SpeedPreset(rawValue: ud.string(forKey: "speed") ?? "") ?? .balanced }
    private var frameRotMode: String { ud.string(forKey: "frameRot") ?? "auto" }
    private var showOriginal: Bool { flag("showOriginal", false) }
    private var pipStyle: PiPStyle {
        var st = PiPStyle.make(theme: PiPTheme(rawValue: ud.string(forKey: "theme") ?? "") ?? .dark,
                               size: PiPTextSize(rawValue: ud.string(forKey: "textSize") ?? "") ?? .auto,
                               font: PiPFont(rawValue: ud.string(forKey: "pipFont") ?? "") ?? .standard)
        st.highlightNames = flag("highlightNames", true)
        return st
    }

    init() {
        sourceCode = UserDefaults.standard.string(forKey: "source") ?? "auto"
        targetCode = UserDefaults.standard.string(forKey: "target") ?? "en"
        server.onPacket = { [weak self] packet in self?.handle(packet) }
        server.start()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        pip.setSize(windowSize.size)
        pip.onStatus = { [weak self] s in Task { @MainActor in self?.status = s } }
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

    private func tick() {
        tickCount += 1
        let alive = Date().timeIntervalSince(lastPacketDate) < 5
        if captureAlive && !alive {
            status = "Capture stopped – iOS may have closed the capture extension. Tap the broadcast icon again (try Speed: Fast)."
            diag.log("Capture stopped")
            diag.noteRuntimeState("heartbeat_timeout")
        }
        if captureAlive != alive { captureAlive = alive }
        if alive, let started = sessionStarted, int("sessionLimit", 0) > 0,
           Date().timeIntervalSince(started) >= Double(int("sessionLimit", 0)) * 60, !paused {
            paused = true
            toast("Session timer reached – translation paused")
            diag.noteRuntimeState("session_time_limit")
        }
        diag.noteThermalState()
        diag.tick(alive: alive, paused: paused, frozen: frozen)
        if tickCount % 5 == 0 { saveMemory() }
        if tickCount % 60 == 0 { applyHistoryRetention() }
        if tickCount % 5 == 0 { refreshLegacyScanContext() }
        if tickCount % 5 == 0, flag("legacyIdleValidationEnabled", false),
           !legacyValidationExhausted, mayRunIdleValidation {
            let fair = ProcessInfo.processInfo.thermalState == .fair
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
            status = "Paused after \(idle) min without text. Turn Pause off to resume."
            diag.log("Auto-paused (idle)")
            diag.noteRuntimeState("idle_auto_pause")
        }
    }

    // MARK: Settings → capture extension
    private var effectiveRot: Int {
        if frameRotMode == "auto" { return autoRot }
        return ((Int(frameRotMode) ?? 0) / 90) & 3
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
    }

    var unconsumedSpeculation: Int { specKeys.count }
    private var speculationAllowed: Bool {
        if flag("freshTranslationTest", false) { return false }
        if !flag("coolMode", false) { return true }
        return flag("smartCool", true) && ocrMs < 100 && queued == nil
            && !ProcessInfo.processInfo.isLowPowerModeEnabled && ProcessInfo.processInfo.thermalState == .nominal
    }

    private var runtimePolicy: RuntimePolicy {
        RuntimePolicy(coolMode: flag("coolMode", false), diagnosticsEnabled: flag("diagnosticsEnabled", true),
                      detailedRequested: flag("detailedCollection", false))
    }

    func diagnosticsSettingsChanged() {
        diag.collectionChanged()
        if diag.enabled {
            diag.s.lockedLang = lockedLang ?? "–"
            diag.s.rotation = effectiveRot
            diag.s.orderVote = orderVote
            diag.s.calibrated = calibrated && !rotationBudget.exhausted
        }
    }

    func pipelineSettingsChanged() {
        diag.noteRuntimeState("capture_config_changed")
        invalidatePending()
        rotRev += 1
        syncConfig()
    }

    func powerPolicyChanged() {
        if !speculationAllowed { specQueued = nil }
        syncConfig()
    }

    /// Sends OCR area, source-language hint, speed and rotation to the extension.
    func syncConfig() {
        let r = area.range(mode: mode)
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
        if diag.enabled { diag.s.rotation = effectiveRot }
        server.send(Config(lang: SourceLanguageRouter.captureLanguage(selected: sourceCode, locked: lockedLang), y0: r.lowerBound, y1: r.upperBound,
                           maxEdge: maxEdge, interval: interval, paused: paused || manualMode,
                           stability: int("stability", 2), rot: effectiveRot, rev: rotRev,
                           boost: int("boost", 1), skipUnchanged: flag("skipUnchanged", true),
                           speculate: speculationAllowed && flag("translateAhead", true), confidence: num("ocrConfidence", 0.3),
                           correction: flag("ocrCorrection", true), idleBackoff: flag("idleBackoff", true),
                           movieMode: mode == .movie,
                           captureDiagnostics: diag.enabled,
                           adaptiveOCR: speed == .automatic || (speed == .balanced && flag("adaptiveOCR", true)),
                           adaptiveConfirmation: flag("adaptiveConfirmation", false), subtitleTracking: flag("subtitleTracking", true),
                           confirmationDeadline: num("confirmationDeadline", 0.6), smartCool: intelligentCool,
                           pressure: flag("adaptive", true) && (intelligentCool || speed == .automatic || (speed == .balanced && flag("adaptiveOCR", true))) && (ProcessInfo.processInfo.thermalState != .nominal || (busy && queued != nil)),
                           selectiveSpeculation: flag("selectiveSpeculation", true), speculationConfidence: num("speculationConfidence", 0.85),
                           detailCeiling: (ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical || (extFreeMB > 0 && extFreeMB < 12)) ? maxEdge : 2400,
                           confirmationBurst: !flag("coolMode", false)))
    }

    // MARK: PiP
    /// Starts the PiP window (retrying while iOS gets ready), then calls `done`.
    func startPiP(then done: @escaping () -> Void = {}) {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? s.setActive(true)
        pip.setSize(windowSize.size)
        attemptPiP(0, done)
    }
    private func attemptPiP(_ n: Int, _ done: @escaping () -> Void) {
        if pip.isActive { done(); return }
        if pip.start() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { done() }
            return
        }
        if n >= 8 {
            status = "PiP couldn't start – stay on the Home tab and tap Start again"
            done(); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.attemptPiP(n + 1, done) }
    }
    func swapLanguages() {
        guard sourceCode != "auto" else { status = "Pick a source language to swap"; return }
        let s = sourceCode
        suppressRecent = true
        sourceCode = targetCode
        targetCode = s
        suppressRecent = false
        noteRecentPair()
    }
    func applyWindowSize() { pip.setSize(windowSize.size) }
    func applyStyle() { pip.style = pipStyle; pip.rerender(showOriginal: showOriginal); pip.configureHeartbeat() }

    /// A shareable picture of one history entry.
    func image(for h: HistoryItem) -> UIImage {
        PiPRenderer.image(original: h.original, translated: h.translated, showOriginal: true,
                          size: CGSize(width: 720, height: 420), style: pipStyle)
    }

    /// Invalidate suspended work before changing language, capture state, or settings.
    private func invalidatePending() {
        contextRevision += 1
        generation += 1
        drainTask?.cancel()
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

    func resetSession() {
        sessionStarted = Date(); sessionTranslations = 0; sessionCharacters = 0
        toast("Session restarted")
    }

    func clearOutput() {
        invalidatePending()
        showing = false; original = ""; translated = ""
        renderedGrams = placeholderGrams; sourceGrams = []
        pip.render(original: "", translated: "Listening…", showOriginal: false)
    }

    func deleteHistory(ids: Set<UUID>) {
        undoHistory = history.filter { ids.contains($0.id) }
        history.removeAll { ids.contains($0.id) }
        toast("Deleted. Undo is available in History.")
    }

    func eraseHistory() {
        undoHistory = nil
        history = []
        ud.removeObject(forKey: "historyData")
        ud.removeObject(forKey: "screenlingo.history.v1")
    }

    func undoHistoryDeletion() {
        guard let saved = undoHistory else { toast("Nothing to undo"); return }
        let existing = Set(history.map(\.id))
        history += saved.filter { !existing.contains($0.id) }
        history.sort { $0.date > $1.date }
        undoHistory = nil
        toast("History restored")
    }

    func historyCSV(_ entries: [HistoryItem]) -> String {
        ExportFormat.csv([["date", "source", "target", "original", "translation", "starred", "note"]]
            + entries.map { [$0.date.ISO8601Format(), $0.sourceLanguage ?? "", $0.targetLanguage ?? "",
                             $0.original, $0.translated, $0.starred ? "true" : "false", $0.note ?? ""] })
    }

    func historyJSON(_ entries: [HistoryItem]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    func importHistory(_ data: Data) -> Bool {
        guard data.count < 5_000_000, let entries = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return false }
        var ids = Set(history.map(\.id))
        history += entries.filter { ids.insert($0.id).inserted }
        history = Array(history.sorted { $0.date > $1.date }.prefix(historyCapacity))
        applyHistoryRetention()
        return true
    }

    func timingSettingsChanged() {
        invalidatePending()
        pip.configureHeartbeat()
        syncConfig()
        if !paused, !manualMode { enqueue(latestBlocks) }
    }

    func applyStorageSettings() {
        if history.count > historyCapacity { history = Array(history.prefix(historyCapacity)) }
        if cache.count > max(500, min(6000, int("memoryRAMCapacity", 3000))) { trimCache(); memoryDirty = true }
        saveMemory()
    }

    // MARK: Small helpers
    /// Short message that slides in at the top of the screen.
    func toast(_ text: String) {
        toastToken += 1
        let token = toastToken
        toastText = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            if self?.toastToken == token { self?.toastText = nil }
        }
    }

    /// Light tick under the finger (can be turned off in Settings → Interface).
    func tap() { if flag("uiHaptics", true) { UISelectionFeedbackGenerator().selectionChanged() } }

    private func noteRecentPair() {
        guard !suppressRecent else { return }
        let pair = "\(sourceCode)>\(targetCode)"
        var r = recentPairs.filter { $0 != pair }
        r.insert(pair, at: 0)
        recentPairs = Array(r.prefix(5))
        ud.set(recentPairs, forKey: "recentPairs")
    }

    func applyPair(_ pair: String) {
        let p = pair.split(separator: ">", maxSplits: 1).map(String.init)
        guard p.count == 2 else { return }
        suppressRecent = true
        sourceCode = p[0]
        targetCode = p[1]
        suppressRecent = false
        noteRecentPair()
        tap()
    }

    private var historyCapacity: Int { max(100, min(1000, int("historyCapacity", 500))) }

    // MARK: History storage
    private func saveHistory() {
        guard flag("saveHistory", true), !flag("privateSession", false) else { return }
        let days = int("historyRetentionDays", 0)
        let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 86400) : Date.distantPast
        let retained = Array(history.filter { $0.starred || $0.date >= cutoff }.prefix(historyCapacity))
        if let d = try? JSONEncoder().encode(retained) { ud.set(d, forKey: "historyData") }
    }
    private func loadHistory() {
        guard flag("saveHistory", true) else { return }
        struct Stored: Decodable {
            let id: UUID?
            let original: String
            let translated: String
            let date: Date
            let starred: Bool?
            let sourceLanguage: String?
            let targetLanguage: String?
            let note: String?
        }
        let data = ud.data(forKey: "historyData") ?? ud.data(forKey: "screenlingo.history.v1")
        guard let data, let records = try? JSONDecoder().decode([Stored].self, from: data) else { return }
        history = records.map { HistoryItem(id: $0.id ?? UUID(), original: $0.original,
                                            translated: $0.translated, date: $0.date, starred: $0.starred ?? false,
                                            sourceLanguage: $0.sourceLanguage, targetLanguage: $0.targetLanguage, note: $0.note) }
        applyHistoryRetention()
    }

    func applyHistoryRetention() {
        let days = int("historyRetentionDays", 0)
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        history.removeAll { !$0.starred && $0.date < cutoff }
    }

    // MARK: Packets from the extension
    private func handle(_ incoming: Packet) {
        let p = incoming
        let now = Date()
        let wasAlive = captureAlive
        lastPacketDate = now
        if !captureAlive { captureAlive = true }
        if frames != p.frames { frames = p.frames }
        if extensionVersion != p.version { extensionVersion = p.version }
        if let t = p.ocrMs, t != ocrMs { ocrMs = t }
        if let m = p.memFreeMB, m != extFreeMB { extFreeMB = m }
        diag.onPacket(p, transport: p.ts.map { max(0, now.timeIntervalSince1970 - $0) * 1000 })

        if !wasAlive {
            startupWarmupTask?.cancel() // Live capture takes priority over idle prewarming.
            startupWarmupTask = nil
            idleValidationTask?.cancel()
            idleValidationTask = nil
            sessionStarted = now
            sessionTranslations = 0; sessionCharacters = 0
            diag.log("Capture connected (extension v\(p.version))")
            diag.noteRuntimeState("capture_connected")
            lastTextDate = now
            syncConfig()
            // Do not launch a second synthetic model job as capture starts.
            // Startup preparation runs before capture; live text owns first use.
            // Capture just started: make sure the floating window is up too.
            if flag("autoOpenPiP", true), !pip.isActive, UIApplication.shared.applicationState == .active { startPiP() }
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
    private func handleContent(_ incoming: Packet, receivedAt: Date, replayed: Bool = false) {
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
        if paused || manualMode { return }
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
        let candidateTexts = extractTexts(p.lines, count: p.stable != false && !replayed)
        guard !candidateTexts.isEmpty else {
            if diag.detailedCollection {
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                                          stage: "ocr_filtering", reason: "rejected_empty")
            }
            return
        }
        let candidateText = candidateTexts.map(TextSim.norm).joined(separator: "\n")
        if p.stable != false && !replayed && diag.enabled { diag.s.confirmedCandidatePackets += 1 }
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
            drainTask?.cancel()
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
        // First, unconfirmed sighting: translate quietly now so the result is ready the moment the text is confirmed.
        if p.stable == false {
            if speculationAllowed && flag("translateAhead", true) {
                if !speculationWindow.allowsOpportunity(enabled: flag("adaptiveSpeculation", true)) {
                    if diag.enabled { diag.s.adaptiveSpeculationSkipped += 1 }
                    diag.notePipelineDecision(candidate: p.candidateID,
                        frameIndex: p.frames, stage: "stability",
                        reason: "adaptive_speculation_backoff")
                    return
                }
                if flag("selectiveSpeculation", true), !SpeculationPolicy.credible(lines: p.lines, threshold: flag("coolMode", false) ? max(0.95, num("speculationConfidence", 0.85)) : num("speculationConfidence", 0.85)) {
                    if diag.enabled { diag.s.specSkipped += 1 }
                    if diag.detailedCollection {
                        diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                            stage: "stability", reason: "rejected_low_confidence")
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
        guard !PipelineSafety.isRecentFragment(texts.joined(separator: "\n"), of: original,
                                               age: Date().timeIntervalSince(lastShowDate)) else {
            if diag.detailedCollection {
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                    stage: "duplicate_detection", reason: "rejected_recent_fragment")
            }
            return
        }
        latestBlocks = texts
        clearTask?.cancel()
        clearTask = nil
        queuedTs = p.firstSeenAt ?? p.ts ?? now.timeIntervalSince1970
        queuedPacket = p
        enqueue(texts.map { String($0.prefix(400)) })
    }

    /// Turns raw OCR lines into the text blocks worth translating (area, rules, own window, blocks, noise…).
    /// `count` is false for early sightings so the statistics are not counted twice.
    private func extractTexts(_ lines: [OCRLine], count: Bool) -> [String] {
        let range = area.range(mode: mode)
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
            if TextSim.norm(t).count < 2 { continue }
            if flag("dropNoise", true) && TextIntel.isNoise(t) { if count && diag.enabled { diag.s.dropNoise += 1 }; continue }
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
            if diag.enabled { diag.s.specSkipped += 1 }
            return
        }
        let thermal = ProcessInfo.processInfo.thermalState
        if ProcessInfo.processInfo.isLowPowerModeEnabled || thermal == .serious || thermal == .critical { return }
        let joined = blocks.joined(separator: "\n")
        guard !frozen, joined != lastHandled, joined != lastSpecText else { return }
        if flag("selectiveSpeculation", true), TextSim.similar(joined, lastSpecText, 0.97) {
            if diag.enabled { diag.s.specSkipped += 1 }
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

    // MARK: Text blocks
    /// Lines in reading order: top to bottom, left to right within a row.
    private func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        OCRGrouping.readingOrder(lines)
    }

    private func makeBlocks(_ lines: [OCRLine]) -> [[OCRLine]] {
        OCRGrouping.makeBlocks(lines, movie: mode == .movie)
    }

    private func blockHeight(_ b: [OCRLine]) -> Double {
        let h = b.map(\.h).sorted()
        return h.isEmpty ? 0 : h[h.count / 2]
    }
    private func blockWeight(_ b: [OCRLine]) -> Double {
        blockHeight(b) * Double(b.reduce(0) { $0 + $1.t.count }).squareRoot()
    }

    /// Movie mode keeps the dominant block(s); other modes keep everything that isn't tiny.
    private func selectBlocks(_ blocks: [[OCRLine]], diagnosticCount: Bool) -> [[OCRLine]] {
        guard !blocks.isEmpty else { return [] }
        let maxH = blocks.map { blockHeight($0) }.max() ?? 0
        var kept = blocks
        if mode == .movie {
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
            if let chosen { kept = groups[chosen] } else { kept = [] }
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

    private func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xFF00...0xFFEF).contains(v)
    }

    /// One block's lines joined into running text ("p-" + "pq" → "p-pq").
    private func blockText(_ lines: [OCRLine]) -> String {
        var out = ""
        for l in readingOrder(lines) {
            let t = l.t.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if out.isEmpty { out = t }
            else if out.hasSuffix("-") { out += t }
            else if let last = out.last, isCJK(last) { out += t }
            else { out += " " + t }
        }
        return out
    }

    private func languageEvidence(_ text: String, limit: Int) -> (NLLanguage?, [NLLanguage: Double]) {
        let key = "\(limit)|\(text)"
        if let hit = languageCache[key] { return hit }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let evidence = (recognizer.dominantLanguage, recognizer.languageHypotheses(withMaximum: limit))
        if languageCache.count >= 128 { languageCache.removeAll(keepingCapacity: true) }
        languageCache[key] = evidence
        return evidence
    }

    /// Removes lines that are the floating window's own text, and learns where that window sits.
    private func removeOwnOutput(_ lines: [OCRLine]) -> [OCRLine] {
        var mine: [OCRLine] = []
        var rest: [OCRLine] = []
        for l in lines {
            if TextSim.norm(l.t).count >= 3 {
                let inOutput = TextSim.containment(of: l.t, in: renderedGrams)
                let inSource = TextSim.containment(of: l.t, in: sourceGrams)
                if inOutput >= 0.85 && inOutput > inSource + 0.1 { mine.append(l); continue }
            }
            rest.append(l)
        }
        if !mine.isEmpty {
            var r = CGRect.null
            for l in mine {
                let w = l.w ?? 0.25
                r = r.union(CGRect(x: l.x - w / 2, y: l.y - l.h / 2, width: w, height: l.h))
            }
            // The original text can sit above the translation, so reach further up when it is shown
            pipRegion = r.insetBy(dx: -0.04, dy: showOriginal ? -0.18 : -0.06)
            pipRegionStamp = Date()
            if let g = pipRegion {
                if diag.enabled { diag.s.pipRegion = "x \(Int(g.minX * 100))–\(Int(g.maxX * 100))%, y \(Int(g.minY * 100))–\(Int(g.maxY * 100))%" }
            }
        }
        if let reg = pipRegion, Date().timeIntervalSince(pipRegionStamp) < 15 {
            rest.removeAll { reg.contains(CGPoint(x: $0.x, y: $0.y)) }
        }
        return rest
    }

    private func dedupe(_ lines: [String]) -> [String] {
        var out: [String] = []
        for l in lines where !out.contains(where: { TextSim.similar($0, l, 0.9) }) { out.append(l) }
        return out
    }

    private func enqueue(_ blocks: [String]) {
        let joined = blocks.joined(separator: "\n")
        guard !blocks.isEmpty, joined != lastHandled else { return }
        if PipelineSafety.isDuplicate(blocks, previous: lastHandled.components(separatedBy: "\n")) { return }
        generation += 1
        cancelPresentation()
        lastHandled = joined
        if queued != nil { diag.noteQueueReplacement() }
        queued = blocks
        queuedAt = Date()
        if SubtitlePerformancePolicy.preemptSpeculation(activeText: currentSpeculativeText, confirmedText: joined) {
            // Different input cannot supply an exact whole-caption reuse result.
            // Cancellation unwinds the single drain before confirmed work starts.
            if diag.enabled { diag.s.specPreemptionRequested += 1 }
            drainTask?.cancel()
        } else if currentSpeculativeText == joined {
            if diag.enabled { diag.s.specMatchingConfirmation += 1 }
        }
        startDrain()
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

    private func performClear() {
        clearTask = nil
        guard showing, !frozen else { return }
        diag.event(.translation, "Cleared – the text ended")
        showing = false
        lastHandled = ""
        original = ""
        translated = ""
        renderedGrams = placeholderGrams
        pip.render(original: "", translated: "Listening…", showOriginal: false)
    }

    /// Only strong, long Automatic-mode evidence may discard target-language background text.
    private func isTargetLanguage(_ text: String) -> Bool {
        guard sourceCode == "auto" else { return false }
        let evidence = languageEvidence(text, limit: 5).1
        return SourceLanguageRouter.shouldDropTarget(selected: sourceCode, target: targetCode,
            hypotheses: Dictionary(uniqueKeysWithValues: evidence.map { ($0.key.rawValue, $0.value) }),
            letters: text.filter(\.isLetter).count)
    }

    private func startDrain() {
        guard !busy, drainTask == nil, queued != nil || specQueued != nil else { return }
        drainTask = Task { await drain() }
    }

    private func drain() async {
        guard !busy else { return }
        busy = true
        defer {
            busy = false
            drainTask = nil
            replayDeferredConfirmedIfPossible()
            startDrain()
        }
        while queued != nil || specQueued != nil {
            guard !Task.isCancelled else { return }
            if let b = queued {
                queued = nil
                currentTs = queuedTs; currentPacket = queuedPacket; currentQueuedAt = queuedAt
                await process(b, display: true)
            } else if let sp = specQueued {
                specQueued = nil
                currentPacket = specPacket
                if speculationAllowed {
                    currentSpeculativeText = sp.joined(separator: "\n")
                    await process(sp, display: false)
                    currentSpeculativeText = nil
                }
            }
        }
    }

    /// A one-slot bounded handoff; if a delayed presentation is pending, its
    /// display callback replays the newest confirmed candidate.
    private func replayDeferredConfirmedIfPossible() {
        guard !busy, !waitingToDisplay, let packet = deferredConfirmedPacket else { return }
        deferredConfirmedPacket = nil
        confirmedHandoffDeadlineTask?.cancel()
        confirmedHandoffDeadlineTask = nil
        guard !paused, !manualMode, captureAlive else { return }
        handleContent(packet, receivedAt: deferredConfirmedReceivedAt, replayed: true)
    }

    // MARK: Translation
    private var memoryRuleToken: String {
        let keys = ["cleanOCR", "slang", "speakerDetect", "neverTranslate", "sourceFixes", "glossary"]
        let snapshot = keys.map { key in "\(key)=\(ud.object(forKey: key) ?? Self.defaults[key] ?? "")" }.joined(separator: "\u{1F}")
        if snapshot != rulesSnapshot {
            rulesSnapshot = snapshot
            rulesDigest = SHA256.hash(data: Data(snapshot.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return rulesDigest
    }

    private func detectSource(_ text: String, record: Bool = true) -> (language: Locale.Language, origin: SourceLanguageOrigin)? {
        if sourceCode != "auto" { return (Locale.Language(identifier: sourceCode), .selected) }
        var evidence = languageEvidence(text, limit: 5).1
        var usedContext = false
        let now = Date().timeIntervalSince1970
        let rawHypotheses = Dictionary(uniqueKeysWithValues: evidence.map { ($0.key.rawValue, $0.value) })
        if flag("contextualLanguage", true), languageContext.mayAssist(rawHypotheses, now: now) {
            let combined = languageEvidence(languageContext.text + " " + text, limit: 5).1
            if let best = combined.max(by: { $0.value < $1.value }), best.value >= 0.8,
               SourceLanguageRouter.sameLanguage(best.key.rawValue, languageContext.code) {
                evidence = combined; usedContext = true
            }
        }
        let previous = languageRouter.locked
        let choice = languageRouter.resolve(
            hypotheses: Dictionary(uniqueKeysWithValues: evidence.map { ($0.key.rawValue, $0.value) }),
            target: targetCode, letters: text.filter(\.isLetter).count,
            useLock: flag("langLock", true), record: record)
        if record, previous != languageRouter.locked {
            lockedLang = languageRouter.locked
            diag.log(lockedLang.map { "Language locked to \($0)" } ?? "Language lock released")
        }
        guard let choice else { return nil }
        if record && diag.enabled {
            diag.s.languageConfidence = evidence.filter { SourceLanguageRouter.sameLanguage($0.key.rawValue, choice.code) }.values.max() ?? 0
            diag.s.languageContextUsed = usedContext
        }
        if record, !SourceLanguageRouter.sameLanguage(choice.code, targetCode) {
            let currentConfidence = languageEvidence(text, limit: 5).1.filter { SourceLanguageRouter.sameLanguage($0.key.rawValue, choice.code) }.values.max() ?? 0
            languageContext.record(text, code: choice.code, confidence: currentConfidence, now: now)
        }
        return (Locale.Language(identifier: choice.code), choice.origin)
    }

    private func pairStatus(_ src: Locale.Language, _ target: Locale.Language) async -> LanguageAvailability.Status {
        if target.minimalIdentifier == Locale.Language(identifier: targetCode).minimalIdentifier,
           src.minimalIdentifier == Locale.Language(identifier: sourceCode).minimalIdentifier,
           let s = langStatus[sourceCode] { return s }
        let k = "\(src.minimalIdentifier)>\(target.minimalIdentifier)"
        if let c = availCache[k], Date().timeIntervalSince(c.0) < 60 { return c.1 }
        let s = await LanguageAvailability().status(from: src, to: target)
        availCache[k] = (Date(), s)
        return s
    }

    /// Splits a block into sentences so each is translated on its own (better quality, cacheable).
    private func splitSentences(_ text: String) -> [String] {
        guard text.count > 24 else { return [text] }
        // Include effective language context: an OCR language correction must not
        // borrow the segmentation calculated for a different configuration.
        let key = "seg\(TranslationUnitPlanning.version)|\(sourceCode)|\(detectedLang)|\(targetCode)|\(text)"
        let started = ProcessInfo.processInfo.systemUptime
        if let cached = segmentationCache.lookup(key) {
            diag.noteSegmentation(candidate: activeCandidateID, reused: true,
                durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000)
            return cached
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var units: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.isEmpty { return true }
            if sentence.count < 4, let previous = units.popLast() {
                units.append(previous + " " + sentence)
            } else {
                units.append(sentence)
            }
            return true
        }
        let result = TranslationUnitPlanning.units(source: text, candidates: units.isEmpty ? [text] : units)
        segmentationCache.insert(key, units: result)
        diag.noteSegmentation(candidate: activeCandidateID, reused: false,
            durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        return result
    }

    /// User glossary ("word=replacement" lines) applied to the finished translation.
    private func applyGlossary(_ s: String) -> String {
        var out = s
        for (from, to) in pairs("glossary") { out = out.replacingOccurrences(of: from, with: to, options: [.caseInsensitive]) }
        return out
    }

    private func process(_ blocks: [String], display: Bool = true) async {
        if display { isTranslating = true }
        defer { if display { isTranslating = false } }
        let t0 = Date()
        if display { processingStarted = t0; savedRequests = 0 }
        let workGeneration = generation
        let workContext = contextRevision
        let workCandidate = activeCandidateID
        let rules = memoryRuleToken
        let destination = targetCode
        let speculativeStart = Date()
        let diagnosticEpoch = diag.started
        let speculativeID: UInt64? = display ? nil : speculationWindow.begin()
        if !display && diag.enabled { diag.s.specStarted += 1 }
        defer {
            let discarded = Task.isCancelled || workContext != contextRevision || workCandidate != activeCandidateID
            if let speculativeID { speculationWindow.finish(speculativeID, discarded: discarded) }
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

        var units: [[TUnit]] = []
        var pending: [String: [(b: Int, u: Int, s: Int, text: String, key: String)]] = [:]
        var srcLangs: [String: Locale.Language] = [:]
        var eligibleMemoryKeys = Set<String>()
        var translatedAny = false
        var unresolvedSource = false
        var failureReason: String? = nil
        func isCurrent() -> Bool {
            let current = !Task.isCancelled && workContext == contextRevision &&
                (!display || workGeneration == generation) &&
                CandidateValidity.isCurrent(workCandidate, active: activeCandidateID,
                    enabled: flag("steadyCaptions", true))
            if display && !current && diag.detailedCollection {
                diag.trace(workCandidate, stage: "cancelled",
                           detail: "Obsolete translation generation or candidate")
            }
            return current
        }

        /// Remembers a finished sentence. Early (translate-ahead) results are marked so we can show how often they pay off.
        func store(_ key: String, _ out: String) {
            guard isCurrent() else { return }
            guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            cache[key] = out
            savedKeys.remove(key)
            if display && eligibleMemoryKeys.contains(key) && !flag("freshTranslationTest", false) {
                confirmedKeys.insert(key)
                queueMemory(key, out, independentlyConfirmed: true)
            }
            memoryDirty = true
            touchCache(key)
            if !display {
                specKeys.insert(key)
                if let speculativeID { speculativeOrigins[key] = speculativeID }
            }
        }

        for (bi, raw) in blocks.enumerated() {
            var text = cleanOn ? TextIntel.cleanOCR(raw) : raw
            for (from, to) in fixes { text = text.replacingOccurrences(of: from, with: to, options: [.caseInsensitive]) }
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
                units.append([TUnit(label: nil, sentences: [text], out: [text], tokens: [])])
                continue
            }
            guard choice.language.languageCode != target.languageCode else {
                units.append([TUnit(label: nil, sentences: [text], out: [text], tokens: [])])
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
                selectedSource: sourceCode != "auto", confidence: sourceConfidence, confirmed: display)
            if slangOn { text = TextIntel.expandSlang(text, lang: src.languageCode?.identifier ?? id) }
            let parts = speakerOn ? TextIntel.splitDialogue(text) : [(label: String?.none, text: text)]
            var row: [TUnit] = []
            for (ui, d) in parts.enumerated() {
                if display, let name = d.label { diag.learn(name) }
                let prot = TextIntel.protect(d.text, words: never)
                let sentences = splitSentences(prot.text)
                if display && diag.detailedCollection {
                    diag.trace(workCandidate, stage: "segmentation",
                               detail: "Translation units assigned to stable block")
                }
                if display && diag.enabled { diag.s.sentences += sentences.count }
                var outs: [String?] = []
                for (si, s) in sentences.enumerated() {
                    let key = PipelineSafety.cacheKey(source: id, target: destination, text: s, protectedWords: prot.tokens.map { "\($0.0)=\($0.1)" }, rules: rules)
                    if memoryEligible && TranslationUnitPlanning.mayRemember(s, confirmed: display) {
                        eligibleMemoryKeys.insert(key)
                    }
                    let lookupStart = ProcessInfo.processInfo.systemUptime
                    let bypassReuse = bypassMemory || flag("freshTranslationTest", false)
                    var resolvedHit = bypassReuse ? nil : cache[key]
                    var diskHit = false
                    if resolvedHit == nil, !bypassReuse, memoryReady, flag("remember", true), !flag("privateSession", false) {
                        let lookup = await memoryStore.lookup(key: key)
                        guard isCurrent() else {
                            if display {
                                // Never attribute an obsolete result to the newer
                                // packet. Count it as cancelled, not as a usable hit.
                                diag.recordMemory(.cancelled, durationMs: lookup.durationMs,
                                    candidate: workCandidate, unitKey: key)
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
                        if let value = resolvedHit { cache[key] = value; touchCache(key) }
                    }
                    if let hit = resolvedHit {
                        touchCache(key)
                        outs.append(hit); translatedAny = true
                        if display {
                            let speculativeHit = specKeys.remove(key) != nil
                            if speculativeHit, let origin = speculativeOrigins.removeValue(forKey: key) {
                                speculationWindow.reuse(origin)
                            }
                            let savedHit = diskHit || savedKeys.remove(key) != nil
                            if !diskHit { diag.recordMemory(speculativeHit ? .speculativeHit : .ramHit,
                                                                  durationMs: (ProcessInfo.processInfo.systemUptime - lookupStart) * 1000,
                                                                  candidate: currentPacket?.candidateID,
                                                                  frameIndex: currentPacket?.frames, unitKey: key) }
                            // A speculative result was produced by the current on-device
                            // model, not by historical memory. Once this exact key is
                            // independently confirmed by stable OCR, it is safe to use
                            // as evidence for lazy legacy reconciliation without another
                            // model call. Ordinary RAM/SQLite hits remain untrusted proof.
                            if memoryEligible && confirmedKeys.insert(key).inserted {
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
                        if display && diag.enabled { diag.s.cacheMisses += 1 }
                        pending[id, default: []].append((bi, ui, si, s, key))
                    }
                }
                row.append(TUnit(label: d.label, sentences: sentences, out: outs, tokens: prot.tokens))
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
            if !display && diag.enabled { diag.s.specModelRequests += plan.unique.count }
            if display && diag.detailedCollection {
                diag.trace(workCandidate, stage: "freshTranslation",
                           detail: "Uncached units submitted to on-device translation")
            }
            let batch = await translateBatch(plan.unique, source: src, target: target, installed: installed, speculative: !display)
            if !display, !isCurrent() {
                // Cancellation is cooperative: the model can finish after a
                // different caption arrives. Recover only completed exact-key
                // units in the SAME context, never publish this old caption,
                // never retry it and never write unconfirmed output to disk.
                let recovered = SubtitlePerformancePolicy.retainedSpeculativeResults(
                    keys: items.map { $0.key },
                    values: batch.flatMap { plan.expand($0.map(Optional.some)) },
                    workContext: workContext, currentContext: contextRevision,
                    reuseAllowed: !bypassMemory && !flag("freshTranslationTest", false) &&
                        rules == memoryRuleToken && destination == targetCode)
                var retained = 0
                for (key, value) in recovered where cache[key] == nil {
                    cache[key] = value
                    savedKeys.remove(key)
                    specKeys.insert(key)
                    if let speculativeID { speculativeOrigins[key] = speculativeID }
                    touchCache(key)
                    retained += 1
                }
                trimCache()
                if diag.enabled && diag.started == diagnosticEpoch { diag.s.specRetainedUnits += retained }
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
                for sentence in plan.unique {
                    guard isCurrent() else { return }
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
        if !display { return }          // translate-ahead: the result now waits in the cache
        guard !failed else {
            lastHandled = ""
            status = failureReason ?? "Translation incomplete – keeping the previous result. Tap Retry."
            return
        }
        var outBlocks: [String] = []
        for row in units {
            var lines: [String] = []
            for u in row {
                var body: [String] = []
                for (si, s) in u.sentences.enumerated() { body.append(u.out[si] ?? s) }
                let joined = TextIntel.restore(body.joined(separator: " "), tokens: u.tokens)
                lines.append(u.label.map { "\($0): \(joined)" } ?? joined)
            }
            outBlocks.append(applyGlossary(lines.joined(separator: "\n")))
        }
        languageFailures = 0
        translateMs = Date().timeIntervalSince(t0) * 1000
        diag.trace(currentPacket?.candidateID, stage: "ready", detail: "Translation assembled")
        var sentenceCount = 0
        for row in units { for u in row { sentenceCount += u.sentences.count } }
        diag.recordTranslate(ms: translateMs, sentences: sentenceCount,
                             from: srcLangs.keys.sorted().joined(separator: "+"), to: targetCode,
                             preview: outBlocks.joined(separator: " / "))
        if diag.enabled { diag.s.translations += 1 }
        if diag.enabled { diag.s.chars += blocks.joined().count }
        status = "\(srcLangs.keys.sorted().joined(separator: "+")) → \(targetCode) ✓"
        let timing = PresentationTiming(packet: currentPacket, firstSeen: currentTs,
            queuedAt: currentQueuedAt, processingAt: processingStarted, processingMs: translateMs,
            savedRequests: savedRequests, readyAt: Date())
        schedulePresentation(blocks.joined(separator: "\n"), outBlocks.joined(separator: "\n"),
                             generation: workGeneration, context: workContext, timing: timing)
    }

    /// Translates many sentences in one call.
    private func translateBatch(_ texts: [String], source: Locale.Language, target: Locale.Language,
                                installed: Bool, speculative: Bool = false) async -> [String]? {
        if #available(iOS 26.0, *), installed {
            let k = "\(source.minimalIdentifier)>\(targetCode)"
            if directSession == nil || directKey != k {
                diag.noteModelState("model_session_created")
                directSession = TranslationSession(installedSource: source, target: target)
                directKey = k
            }
            if diag.enabled { diag.s.sessionKind = "Direct session (iOS 26)" }
            guard let session = directSession else { return nil }
            let r = await runBatch(session, texts, speculative: speculative)
            if r == nil { directSession = nil }
            else { warmupStatus = "Ready" }
            return r
        }
        if diag.enabled { diag.s.sessionKind = "Hosted view (iOS 18)" }
        return await translateLegacy(texts, source: source, target: target, speculative: speculative)
    }

    private func runBatch(_ session: TranslationSession, _ texts: [String],
                          warmup: Bool = false, speculative: Bool = false) async -> [String]? {
        let began = ProcessInfo.processInfo.systemUptime
        let modelCandidate = warmup ? nil : currentPacket?.candidateID
        let first30s = !warmup && sessionStarted.map {
            let age = Date().timeIntervalSince($0)
            return age >= 0 && age <= 30
        } == true
        diag.noteModelState(warmup ? "warmup_model_submitted" :
            (speculative ? "speculative_model_submitted" : "confirmed_model_submitted"), candidate: modelCandidate)
        let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        do {
            let res = try await session.translations(from: reqs)
            let result = PipelineSafety.orderedTranslations(res.map { ($0.clientIdentifier, $0.targetText) }, count: texts.count)
            diag.noteModelState(result == nil ? "model_batch_failed" : "model_batch_completed",
                durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
            if result != nil {
                diag.noteModelState(warmup ? "warmup_model_completed" :
                    (speculative ? "speculative_model_completed" : "confirmed_model_completed"),
                    durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000,
                    candidate: modelCandidate)
            }
            if first30s {
                diag.noteModelState("model_batch_first_30s",
                    durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
            }
            return result
        } catch {
            if Task.isCancelled {
                diag.noteModelState("model_batch_cancelled",
                    durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
                return nil
            }
            diag.noteModelState("model_batch_failed",
                durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
            diag.event(.error, "Translation engine failed: \(error.localizedDescription)")
            return nil
        }
    }

    private struct PresentationTiming {
        let packet: Packet?
        let firstSeen: Double
        let queuedAt: Date
        let processingAt: Date
        let processingMs: Double
        let savedRequests: Int
        let readyAt: Date
    }

    private func cancelPresentation() {
        presentationTask?.cancel(); presentationTask = nil
        presentationID = UUID()
        if waitingToDisplay { waitingToDisplay = false }
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

    private func show(_ text: String, _ result: String, timing: PresentationTiming) {
        clearTask?.cancel()
        clearTask = nil
        guard !frozen, (!paused || manualMode),
              CandidateValidity.isCurrent(timing.packet?.candidateID, active: activeCandidateID, enabled: flag("steadyCaptions", true), allowLegacy: true) else { return }
        guard !PipelineSafety.isRecentFragment(text, of: original, age: Date().timeIntervalSince(lastShowDate)) else { return }
        let renderStart = Date()
        pip.style = pipStyle
        guard pip.render(original: text, translated: result, showOriginal: showOriginal,
                         size: windowSize.size) else {
            lastHandled = ""
            status = "Frame preparation failed – keeping the previous subtitle. Tap Retry."
            diag.notePipelineDecision(candidate: timing.packet?.candidateID,
                frameIndex: timing.packet?.frames, stage: "pip_enqueue", reason: "enqueue_failed")
            return
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
        if diag.enabled { diag.s.enqueuedCandidateFrames += 1 }
        if total >= 1200 {
            if diag.enabled { diag.s.slowTailEnqueues += 1 }
            diag.notePipelineDecision(candidate: packet?.candidateID,
                frameIndex: packet?.frames, stage: "pip_enqueue",
                reason: "slow_tail", durationMs: total)
        }
        diag.recordPipeline(latency.last)
        if total > 0 { diag.recordLatency(ms: total) }
        if history.first?.original != text {
            sessionTranslations += 1; sessionCharacters += text.count
            if !flag("privateSession", false) {
                history.insert(HistoryItem(original: text, translated: result,
                                           sourceLanguage: sourceCode == "auto" ? detectedLang : sourceCode,
                                           targetLanguage: targetCode), at: 0)
                if history.count > historyCapacity { history.removeLast() }
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
            ud.set(sourceToRemember, forKey: "lastEffectiveSource")
            ud.set(Date().timeIntervalSince1970, forKey: "lastEffectiveSourceAt")
        }
        replayDeferredConfirmedIfPossible()
    }

    func speak(_ s: String) {
        let voices = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "pt": "pt-BR", "en": "en-US", "es": "es-ES",
                      "fr": "fr-FR", "de": "de-DE", "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR", "ru": "ru-RU",
                      "ar": "ar-SA", "tr": "tr-TR", "hi": "hi-IN", "id": "id-ID", "nl": "nl-NL", "pl": "pl-PL",
                      "th": "th-TH", "vi": "vi-VN", "uk": "uk-UA"]
        if speech.isSpeaking, !flag("interruptSpeech", true) { return }
        speech.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: s)
        u.voice = AVSpeechSynthesisVoice(language: voices[targetCode] ?? targetCode)
        u.rate = Float(num("speechRate", 0.5))
        speech.speak(u)
    }

    // MARK: Translation memory (kept between launches)
    private var memoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenLingo", isDirectory: true).appendingPathComponent("translation-memory-v4.json")
    }

    private func loadMemory() {
        diag.memoryStore = memoryStore
        let legacy = [memoryURL, FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("translation-memory.json")]
        Task { [weak self] in
            guard let self else { return }
            do {
                self.memoryHealth = try await self.memoryStore.prepare(legacyURLs: legacy)
                self.memoryReady = true
                await self.refreshMemoryHealth()
                self.saveMemory(force: true)
            } catch {
                self.memoryFailure = "Memory unavailable; fresh translation remains available"
                self.diag.log("Memory initialization failed; preserved data requires recovery")
            }
        }
    }

    private func touchCache(_ key: String) {
        cacheClock &+= 1
        cacheUse[key] = cacheClock
    }

    private func queueMemory(_ key: String, _ value: String, independentlyConfirmed: Bool = false) {
        guard flag("remember", true), !flag("privateSession", false),
              !flag("freshTranslationTest", false) else { return }
        // Bound pending writes without claiming unsaved entries are durable.
        guard pendingMemory[key] != nil || pendingMemory.count < 3000 else {
            memoryFailure = "Memory write queue full; new entries remain session-only"
            return
        }
        pendingMemory[key] = value
        if independentlyConfirmed { pendingLegacyProof[key] = value }
        else if pendingLegacyProof[key] != value { pendingLegacyProof[key] = nil }
        memoryPendingWrites = pendingMemory.count
        memoryDirty = true
        saveMemory()
    }

    func saveMemory(force: Bool = false) {
        guard memoryReady, !memorySaving, !memoryMutationInProgress, !pendingMemory.isEmpty,
              force || Date() >= storageFullRetryNotBefore else { return }
        memorySaving = true
        let snapshot = pendingMemory
        let freshKeys = Set(snapshot.compactMap { key, value in
            pendingLegacyProof[key] == value ? key : nil
        })
        memoryRevision += 1
        let revision = memoryRevision
        Task { [weak self] in
            guard let self else { return }
            let writeStart = ProcessInfo.processInfo.systemUptime
            var committed = false
            var storageFull = false
            do {
                self.memoryHealth = try await self.memoryStore.save(snapshot,
                    revision: revision, independentlyConfirmedKeys: freshKeys)
                committed = true
                if self.memoryRevision == revision {
                    for (key, value) in snapshot where self.pendingMemory[key] == value {
                        self.pendingMemory[key] = nil
                        if self.pendingLegacyProof[key] == value {
                            self.pendingLegacyProof[key] = nil
                        }
                    }
                }
                self.memoryFailure = nil
                self.diag.recordMemory(.persisted, durationMs: (ProcessInfo.processInfo.systemUptime - writeStart) * 1000)
            } catch MemoryStoreError.storageFull {
                storageFull = true
                // Avoid retry storms on every changed subtitle when storage is full.
                // Confirmed results remain pending for the next explicit/periodic retry.
                self.storageFullRetryNotBefore = Date().addingTimeInterval(30)
                self.memoryFailure = "Device storage full; remembered translations are pending, not saved"
                self.diag.recordMemory(.writeFailed,
                    durationMs: (ProcessInfo.processInfo.systemUptime - writeStart) * 1000)
            } catch {
                self.memoryFailure = "Memory write failed; pending entries will retry"
                self.diag.recordMemory(.writeFailed,
                    durationMs: (ProcessInfo.processInfo.systemUptime - writeStart) * 1000)
            }
            self.memorySaving = false
            self.memoryPendingWrites = self.pendingMemory.count
            self.memoryDirty = !self.pendingMemory.isEmpty
            if committed {
                self.memoryRetryAttempts = 0
                self.storageFullRetryNotBefore = .distantPast
            }
            await self.refreshMemoryHealth()
            guard !self.pendingMemory.isEmpty else { return }
            if committed {
                // Confirmations queued during the previous commit must not get stranded.
                self.saveMemory(force: true)
            } else if !storageFull && self.memoryRetryAttempts < 3 {
                self.memoryRetryAttempts += 1
                let delay: UInt64 = [2, 5, 15][self.memoryRetryAttempts - 1] * 1_000_000_000
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: delay)
                    self?.saveMemory(force: true)
                }
            }
        }
    }

    /// Best-effort bounded persistence for iOS suspension. Returning false means
    /// confirmed entries remain visibly pending; it is never a durability claim.
    func flushPendingMemory(maxWaitSeconds: Double = 2.5) async -> Bool {
        guard memoryReady else { return pendingMemory.isEmpty && !memorySaving }
        let seconds = min(5.0, max(0.1, maxWaitSeconds))
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var retries = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            if pendingMemory.isEmpty && !memorySaving { return true }
            if !memorySaving && !memoryMutationInProgress && retries < 2 {
                retries += 1
                saveMemory(force: true)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        memoryPendingWrites = pendingMemory.count
        if !pendingMemory.isEmpty {
            memoryFailure = "Confirmed translations remain pending after background flush"
        }
        return pendingMemory.isEmpty && !memorySaving
    }

    func refreshMemoryHealth() async {
        do {
            let health = try await memoryStore.health()
            memoryHealth = health
            memoryCount = health.totalEntries
            diag.memoryHealth.totalEntries = health.totalEntries
            diag.memoryHealth.readyEntries = health.readyEntries
            diag.memoryHealth.needsValidation = health.needsValidation
            diag.memoryHealth.legacyValidated = health.legacyValidated
            diag.memoryHealth.legacySuperseded = health.legacySuperseded
            diag.memoryHealth.legacyUnverified = health.legacyUnverified
            diag.memoryHealth.suggestedOCRMatches = health.suggestedOCRMatches
            diag.memoryHealth.suggestedFragmentMatches = health.suggestedFragmentMatches
            diag.memoryHealth.conflicts = health.conflicts
            diag.memoryHealth.databaseBytes = health.databaseBytes
            diag.memoryHealth.migrationStatus = health.migrationStatus
            diag.memoryHealth.integrity = health.integrity
            diag.memoryHealth.failedWrites = health.failedWrites
            diag.memoryHealth.pendingWrites = memoryPendingWrites
            diag.memoryHealth.ramEntries = cache.count
            diag.memoryHealth.categoryCounts = health.categoryCounts
        } catch { memoryFailure = "Memory health unavailable" }
    }

    func clearRAMCache() {
        invalidatePending()
        cache.removeAll(); cacheUse.removeAll()
        segmentationCache.clear()
        specKeys.removeAll(); speculativeOrigins.removeAll(); savedKeys.removeAll(); confirmedKeys.removeAll()
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

    func removeMemoryEntries(ids: [Int64]) async throws {
        guard memoryReady, !memorySaving, !memoryMutationInProgress, pendingMemory.isEmpty
        else { throw MemoryStoreError.unavailable }
        memoryMutationInProgress = true
        defer {
            memoryMutationInProgress = false
            saveMemory(force: true)
        }
        clearRAMCache()
        try await memoryStore.delete(ids: ids)
        await refreshMemoryHealth()
    }


    /// Storage imports and review operations are serialized against engine writes.
    /// New confirmations arriving while a maintenance operation awaits the store
    /// remain in pendingMemory and are flushed after its commit.
    func importMemoryData(_ data: Data) async throws {
        guard memoryReady, !memorySaving, !memoryMutationInProgress, pendingMemory.isEmpty
        else { throw MemoryStoreError.unavailable }
        memoryMutationInProgress = true
        defer {
            memoryMutationInProgress = false
            saveMemory(force: true)
        }
        _ = try await memoryStore.importData(data)
        clearRAMCache()
        await refreshMemoryHealth()
    }

    func quarantineMemoryEntries(ids: [Int64]) async throws {
        guard memoryReady, !memorySaving, !memoryMutationInProgress, pendingMemory.isEmpty
        else { throw MemoryStoreError.unavailable }
        memoryMutationInProgress = true
        defer {
            memoryMutationInProgress = false
            saveMemory(force: true)
        }
        _ = try await memoryStore.quarantineEntries(ids: ids)
        clearRAMCache()
        await refreshMemoryHealth()
    }

    func mergeMemoryRecoverySnapshot(named name: String) async throws {
        guard memoryReady, !memorySaving, !memoryMutationInProgress, pendingMemory.isEmpty
        else { throw MemoryStoreError.unavailable }
        memoryMutationInProgress = true
        defer {
            memoryMutationInProgress = false
            saveMemory(force: true)
        }
        _ = try await memoryStore.mergeRecoverySnapshot(named: name)
        clearRAMCache()
        await refreshMemoryHealth()
    }

    /// The management UI must not report deletion until the SQLite transaction commits.
    /// Existing callers can still invoke the fire-and-forget compatibility entry point.
    func clearMemory() {
        Task { _ = await clearMemoryConfirmed() }
    }

    @discardableResult
    func clearMemoryConfirmed() async -> Bool {
        // Enforce a barrier across the suspension: new confirmed translations
        // remain pending and cannot be written until the clear completes.
        guard memoryReady, !memoryMutationInProgress, !memorySaving, pendingMemory.isEmpty else {
            memoryFailure = "Wait for pending memory writes before deleting"
            return false
        }
        memoryMutationInProgress = true
        clearRAMCache()
        memoryRevision += 1
        let revision = memoryRevision
        defer {
            memoryMutationInProgress = false
            // Any new confirmations queued while SQLite was busy are still owed a write.
            saveMemory(force: true)
        }
        do {
            try await memoryStore.clear(revision: revision)
            clearRAMCache()
            await refreshMemoryHealth()
            memoryFailure = nil
            toast("Translation memory cleared")
            return true
        } catch {
            memoryFailure = "Memory could not be cleared; saved data was preserved"
            return false
        }
    }

    /// Only call after clearMemoryConfirmed() succeeded and the user explicitly
    /// requested erasure of recoverable memory originals and snapshots.
    func purgePreservedMemoryCopies() async throws {
        let legacy = [memoryURL,
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("translation-memory.json")]
        try await memoryStore.deletePreservedCopies(legacyURLs: legacy)
        await refreshMemoryHealth()
    }

    /// Explicit maintenance route when SQLite initialization failed. A failed
    /// recovery leaves pending confirmations intact and fresh translation active.
    func restoreUnavailableMemoryFromSnapshot(named name: String) async throws {
        guard !memoryReady, !memorySaving, !memoryMutationInProgress else {
            throw MemoryStoreError.unavailable
        }
        memoryMutationInProgress = true
        defer {
            memoryMutationInProgress = false
            if memoryReady { saveMemory(force: true) }
        }
        memoryHealth = try await memoryStore.recoverUnavailableStore(named: name)
        memoryReady = true
        clearRAMCache()
        await refreshMemoryHealth()
        memoryFailure = nil
        diag.log("Unavailable memory database restored from verified snapshot; damaged originals retained")
    }

    /// Called from the live app on an iOS memory warning. Persistent SQLite entries
    /// remain untouched; only evictable RAM entries are reduced.
    func handleMemoryPressure() {
        let configured = max(250, min(6000, int("memoryRAMCapacity", 3000)))
        memoryPressureCapacity = max(250, configured / 4)
        trimCache()
    }

    private func trimCache() {
        let configured = max(250, min(6000, int("memoryRAMCapacity", 3000)))
        let limit = min(configured, memoryPressureCapacity ?? configured)
        let excess = cache.count - limit
        guard excess > 0 else { return }
        // The common case is one insertion beyond capacity. Finding the oldest
        // key with a linear scan avoids sorting the entire cache on every frame.
        let victims: [String]
        if excess == 1 {
            victims = cacheUse.min(by: { $0.value < $1.value }).map { [$0.key] } ??
                      Array(cache.keys.prefix(1))
        } else {
            victims = cacheUse.sorted(by: { $0.value < $1.value }).prefix(excess).map(\.key)
        }
        for key in victims {
            cache[key] = nil; cacheUse[key] = nil
            specKeys.remove(key); speculativeOrigins.removeValue(forKey: key); savedKeys.remove(key); confirmedKeys.remove(key)
        }
        // Report entries evicted, not maintenance batches; persistence is untouched.
        diag.recordMemory(.ramEviction, count: victims.count)
    }

    // MARK: Bounded concurrent, foreground-only legacy validation

    private var mayRunIdleValidation: Bool {
        memoryReady && !memorySaving && !memoryMutationInProgress &&
        pendingMemory.isEmpty && !legacyValidationBusy && !warming &&
        !captureAlive && !pipActive && !busy &&
        UIApplication.shared.applicationState == .active &&
        !flag("privateSession", false) && !flag("freshTranslationTest", false) &&
        !ProcessInfo.processInfo.isLowPowerModeEnabled &&
        ProcessInfo.processInfo.thermalState != .serious &&
        ProcessInfo.processInfo.thermalState != .critical
    }

    /// After *every* suspension, capture and changed processing rules win over
    /// idle work. Never commit translations created under outdated settings.
    private func idleValidationStillSafe(revision: Int, target: String,
                                         rules: String) -> Bool {
        !Task.isCancelled && !captureAlive && !pipActive && !busy &&
        UIApplication.shared.applicationState == .active &&
        !flag("privateSession", false) && !flag("freshTranslationTest", false) &&
        !ProcessInfo.processInfo.isLowPowerModeEnabled &&
        ProcessInfo.processInfo.thermalState != .serious &&
        ProcessInfo.processInfo.thermalState != .critical &&
        contextRevision == revision && targetCode == target &&
        memoryRuleToken == rules && !memorySaving &&
        !memoryMutationInProgress && pendingMemory.isEmpty && memoryReady
    }

    func cancelLegacyValidation() {
        idleValidationTask?.cancel()
        legacyIdleValidationStatus = "Stopping after current on-device model request…"
    }

    func startLegacyValidation(maxEntries: Int = IdleLegacyBatchPolicy.manualEntries) {
        guard idleValidationTask == nil else { return }
        refreshLegacyScanContext()
        if legacyValidationExhausted {
            // Manual validation is a new scan after settings/model availability
            // may have changed; automatic idle checks avoid repeated futile scans.
            legacyValidationCursor = 0
            legacyValidationExhausted = false
        }
        idleValidationTask = Task { [weak self] in
            await self?.validateIdleLegacy(maxEntries: maxEntries)
            self?.idleValidationTask = nil
        }
    }

    /// One isolated model session per worker, with at most twelve texts in a
    /// single call. No shared foreground session, no 50 simultaneous models.
    private nonisolated static func translateIdleChunk(source: String, target: String,
                                                       texts: [String]) async -> [String]? {
        guard #available(iOS 26.0, *), !Task.isCancelled, !texts.isEmpty else { return nil }
        let session = TranslationSession(installedSource: Locale.Language(identifier: source),
                                         target: Locale.Language(identifier: target))
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element,
                                       clientIdentifier: String($0.offset))
        }
        do {
            let response = try await session.translations(from: requests)
            guard !Task.isCancelled else { return nil }
            return PipelineSafety.orderedTranslations(
                response.map { ($0.clientIdentifier, $0.targetText) }, count: texts.count)
        } catch { return nil }
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
        let fair = ProcessInfo.processInfo.thermalState == .fair
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
            memoryHealth = try await memoryStore.confirmIdleLegacyBatch(
                commits, revision: memoryRevision)
            legacyValidatedThisSession += commits.count
            legacyBatchCompleted = commits.count
            diag.noteLegacyBatch(selected: items.count, committed: commits.count,
                skipped: legacyBatchSkipped, workers: workers,
                durationMs: max(0, Date().timeIntervalSince(legacyBatchStartedAt) * 1000))
            await refreshMemoryHealth()
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
        guard src.languageCode != target.languageCode,
              let word = Self.warmWords[src.languageCode?.identifier ?? code] else { return }
        // Avoid reloading the same model while a usable warm session exists.
        let warmKey = "\(src.minimalIdentifier)>\(destination)"
        guard directSession == nil || directKey != warmKey else {
            warmupStatus = "Ready"
            return
        }
        guard await pairStatus(src, target) == .installed, !Task.isCancelled,
              workContext == contextRevision, !busy, queued == nil,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return }
        // Direct sessions can warm independently; the iOS 18 hosted path has one continuation.
        guard #available(iOS 26.0, *) else { return }
        lastWarm = Date()
        let t0 = Date()
        warmupStatus = predicted ? "Predictive warm-up…" : "Warming up…"
        diag.noteModelState("warmup_started")
        if predicted { diag.noteModelState("warmup_predicted_source") }
        let session = TranslationSession(installedSource: src, target: target)
        // Exercise both a short word and a subtitle-length sentence on the same
        // retained session. Synthetic output never enters memory/history/PiP.
        let sample = Self.warmSentences[src.languageCode?.identifier ?? code]
        let warmed = await runBatch(session, [word] + (sample.map { [$0] } ?? []), warmup: true)
        guard !Task.isCancelled, workContext == contextRevision else {
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
        cache.removeAll()
        specKeys.removeAll(); speculativeOrigins.removeAll(); savedKeys.removeAll(); confirmedKeys.removeAll()
        bypassMemory = true
        lastHandled = ""
        let blocks = original.components(separatedBy: "\n")
        diag.log("Retranslating current text")
        queuedPacket = nil
        queuedTs = Date().timeIntervalSince1970
        enqueue(blocks)
    }

    func toggleStar(_ id: UUID) {
        if let i = history.firstIndex(where: { $0.id == id }) { history[i].starred.toggle() }
    }

    // iOS 18 path (needs the hosted .translationTask view in RootView)
    private func translateLegacy(_ texts: [String], source: Locale.Language, target: Locale.Language,
                                 speculative: Bool = false) async -> [String]? {
        let requestID = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { (cont: CheckedContinuation<[String]?, Never>) in
                legacyRequestID = requestID
                legacyContinuation = cont
                pendingTexts = texts
                legacySpeculative = speculative
                if var c = legacyConfig, c.source == source, c.target == target {
                    c.invalidate(); legacyConfig = c
                } else {
                    legacyConfig = .init(source: source, target: target)
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    if self?.legacyRequestID == requestID { self?.finishLegacy(nil) }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.legacyRequestID == requestID else { return }
                self.legacyConfig = nil
                self.finishLegacy(nil)
            }
        }
    }
    func runLegacy(_ session: TranslationSession) async {
        let requestID = legacyRequestID
        let texts = pendingTexts
        let speculative = legacySpeculative
        let result = await runBatch(session, texts, speculative: speculative)
        if legacyRequestID == requestID { finishLegacy(result) }
    }
    private func finishLegacy(_ r: [String]?) {
        legacyContinuation?.resume(returning: r)
        legacyContinuation = nil
    }

    // MARK: Languages / downloads
    func loadLanguages() async {
        let supported = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        var items: [LangItem] = []
        for l in supported {
            let code = l.minimalIdentifier
            guard seen.insert(code).inserted else { continue }
            items.append(LangItem(code: code, name: Locale.current.localizedString(forIdentifier: code) ?? code))
        }
        if !items.isEmpty { languages = items.sorted { $0.name < $1.name } }
        await refreshStatus()
    }

    func refreshStatus() async {
        availCache.removeAll()
        let destination = targetCode
        let target = Locale.Language(identifier: destination)
        let av = LanguageAvailability()
        var out: [String: LanguageAvailability.Status] = [:]
        // Read the active pair first so readiness does not wait behind every other language.
        var seen = Set<String>()
        let preferred = sourceCode == "auto" ? [] : [sourceCode]
        let codes = (preferred + languages.map(\.code)).filter { seen.insert($0).inserted }
        for code in codes {
            let source = Locale.Language(identifier: code)
            let availability = await av.status(from: source, to: target)
            guard destination == targetCode else { return }
            out[code] = availability
            availCache["\(source.minimalIdentifier)>\(target.minimalIdentifier)"] = (Date(), availability)
            if code == sourceCode { langStatus[code] = availability }
        }
        guard destination == targetCode else { return }
        langStatus = out
    }

    func download(_ code: String) {
        let src = Locale.Language(identifier: code)
        let tgt = Locale.Language(identifier: targetCode)
        if var c = downloadConfig, c.source == src, c.target == tgt {
            c.invalidate(); downloadConfig = c
        } else {
            downloadConfig = .init(source: src, target: tgt)
        }
    }
    func runDownload(_ session: TranslationSession) async {
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
        }
    }

    // MARK: Backup + bulk changes
    private func snapshot() -> [String: Any] {
        var snap: [String: Any] = [:]
        for k in Self.settingKeys { if let v = ud.object(forKey: k) { snap[k] = v } }
        return snap
    }
    func exportSettings() -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: snapshot(), options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
    func importSettings(_ text: String) -> Bool {
        guard let d = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        for k in Self.settingKeys {
            guard let v = o[k], !(v is NSNull), v is String || v is NSNumber else { continue }
            ud.set(v, forKey: k)
        }
        if let minimum = o["minDisplay"] as? NSNumber {
            ud.set(PresentationSchedule.inferredPolicy(saved: o["displayPolicy"] as? String,
                minimum: minimum.doubleValue), forKey: "displayPolicy")
        }
        reloadSettings()
        return true
    }
    /// Puts the given settings back to their defaults (used by every "Reset this page" button).
    func resetKeys(_ keys: [String]) {
        for k in keys { ud.removeObject(forKey: k) }
        reloadSettings()
        toast("Reset to defaults")
    }
    func resetAllSettings() { resetKeys(Self.settingKeys) }
    /// Re-reads everything after settings were changed in bulk.
    func reloadSettings() {
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
    /// A picture of the current translation, for sharing.
    func snapshotImage() -> UIImage {
        PiPRenderer.image(original: original, translated: translated.isEmpty ? "Nothing translated yet" : translated,
                          showOriginal: showOriginal, size: windowSize.size, style: pipStyle)
    }

    // MARK: Test
    func runTest() {
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

// MARK: - Loopback server (extension ⇄ app, UDP on 127.0.0.1)
final class LoopbackServer {
    private var listener: NWListener?
    private var peer: NWConnection?
    private let queue = DispatchQueue(label: "loopback.server", qos: .userInitiated)
    var onPacket: (@MainActor (Packet) -> Void)?

    func start() {
        stop()
        guard let port = NWEndpoint.Port(rawValue: Loopback.port),
              let l = try? NWListener(using: .udp, on: port) else { return }
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
            self.peer = c
            self.receive(on: c)
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.queue.asyncAfter(deadline: .now() + 1) { self?.start() }
            }
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil }

    /// Sends settings back to the capture extension.
    func send(_ cfg: Config) {
        guard let data = try? JSONEncoder().encode(cfg) else { return }
        queue.async { [weak self] in
            self?.peer?.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            if let data, let p = try? JSONDecoder().decode(Packet.self, from: data) {
                // One actor handoff, rather than dispatching to main and then creating another main-actor task.
                Task(priority: .userInitiated) { @MainActor [weak self] in self?.onPacket?(p) }
            }
            if error == nil { self?.receive(on: c) }
        }
    }
}

