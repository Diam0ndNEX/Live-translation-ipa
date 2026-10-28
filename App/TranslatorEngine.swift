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
        "autoCopy", "adaptive", "idleMinutes", "translateAhead", "keepWarm", "remember",
        "displayPolicy", "pipWeight", "pipAlignment", "pipLineSpacing", "pipPadding", "originalFraction", "pipScale", "speakerAccent", "heartbeatInterval", "hapticStrength", "autoCopyFormat", "interruptSpeech", "ocrConfidence", "ocrCorrection", "idleBackoff", "coolMode", "adaptiveOCR", "adaptiveConfirmation", "subtitleTracking", "selectiveSpeculation", "speculationConfidence", "confirmationDeadline", "smartCool", "steadyCaptions", "languageRecovery", "deduplicateCopies", "continuousRotation", "contextualLanguage"
    ]
    /// App look & behaviour that presets do not touch.
    static let interfaceKeys = ["accent", "keepAwake", "saveHistory", "historyRetentionDays", "uiHaptics", "homePresets", "homeTools", "homeQuick", "homeStatus", "homeRecent", "privateSession", "diagIncludeText", "readerFont", "readerSpacing", "readerWidth", "historyCapacity", "memoryCapacity", "diagSamples", "diagnosticsEnabled", "detailedCollection", "showSessionSpeakers", "homeMetrics", "homeQuickExpanded", "homeDetailsExpanded", "photoOCREdge", "photoAutoTranslate", "sessionLimit", "readerSize", "readerOriginal", "readerAlignment"]
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
        "displayPolicy": "immediate", "pipWeight": "bold", "pipAlignment": "left", "pipLineSpacing": 0.0,
        "pipPadding": 24.0, "originalFraction": 0.27, "pipScale": 1.0, "speakerAccent": "blue", "heartbeatInterval": 1.0,
        "readerFont": "rounded", "readerSpacing": 8.0, "readerWidth": "full", "historyCapacity": 500,
        "memoryCapacity": 3000, "diagSamples": 600, "homeMetrics": true, "homeQuickExpanded": false,
        "homeDetailsExpanded": false, "hapticStrength": "light", "autoCopyFormat": "translation", "interruptSpeech": true,
        "photoOCREdge": 2400, "photoAutoTranslate": false,
        "adaptiveOCR": true, "adaptiveConfirmation": false, "subtitleTracking": true, "selectiveSpeculation": true,
        "speculationConfidence": 0.85, "confirmationDeadline": 0.6, "smartCool": true, "steadyCaptions": true,
        "languageRecovery": true, "deduplicateCopies": true, "continuousRotation": false, "contextualLanguage": true,
        "coolMode": false, "diagnosticsEnabled": true, "detailedCollection": false, "showSessionSpeakers": true,
        "privateSession": false, "diagIncludeText": false, "sessionLimit": 0, "readerSize": 28.0,
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
    private var languageCache: [String: (NLLanguage?, [NLLanguage: Double])] = [:]
    private var drainTask: Task<Void, Never>?
    private var activeCandidateText = ""
    private var activeCandidateID: String?
    private var specPacket: Packet?
    private var savedKeys = Set<String>()
    private var confirmedKeys = Set<String>()
    private var subtitleRegions = SubtitleRegions()
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
    let memoryStore = TranslationMemoryStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScreenLingo/TranslationMemory", isDirectory: true))
    @Published var memoryHealth: MemoryStoreHealth?
    @Published var memoryPendingWrites = 0
    @Published var memoryFailure: String?
    private var pendingMemory: [String: String] = [:]
    private var memorySaving = false
    private var memoryMutationInProgress = false
    private var memoryRetryAttempts = 0
    private var memoryPressureCapacity: Int?
    private var memoryReady = false
    private var cacheUse: [String: UInt64] = [:]
    private var cacheClock: UInt64 = 0
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
            Task { @MainActor in self?.pipActive = a; self?.diag.log(a ? "Floating window opened" : "Floating window closed") }
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
    }

    private func tick() {
        tickCount += 1
        let alive = Date().timeIntervalSince(lastPacketDate) < 5
        if captureAlive && !alive {
            status = "Capture stopped – iOS may have closed the capture extension. Tap the broadcast icon again (try Speed: Fast)."
            diag.log("Capture stopped")
        }
        if captureAlive != alive { captureAlive = alive }
        if alive, let started = sessionStarted, int("sessionLimit", 0) > 0,
           Date().timeIntervalSince(started) >= Double(int("sessionLimit", 0)) * 60, !paused {
            paused = true
            toast("Session timer reached – translation paused")
        }
        diag.tick(alive: alive, paused: paused, frozen: frozen)
        if tickCount % 5 == 0 { saveMemory() }
        if tickCount % 60 == 0 { applyHistoryRetention() }
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
                           adaptiveOCR: speed == .automatic || (speed == .balanced && flag("adaptiveOCR", true)),
                           adaptiveConfirmation: flag("adaptiveConfirmation", false), subtitleTracking: flag("subtitleTracking", true),
                           confirmationDeadline: num("confirmationDeadline", 0.6), smartCool: intelligentCool,
                           pressure: flag("adaptive", true) && (intelligentCool || speed == .automatic || (speed == .balanced && flag("adaptiveOCR", true))) && (ProcessInfo.processInfo.thermalState != .nominal || (busy && queued != nil)),
                           selectiveSpeculation: flag("selectiveSpeculation", true), speculationConfidence: num("speculationConfidence", 0.85),
                           detailCeiling: (ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical || (extFreeMB > 0 && extFreeMB < 12)) ? maxEdge : 2400))
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
        activeCandidateID = nil; activeCandidateText = ""
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
        var p = incoming
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
            sessionStarted = now
            sessionTranslations = 0; sessionCharacters = 0
            diag.log("Capture connected (extension v\(p.version))")
            lastTextDate = now
            syncConfig()
            Task { await prewarm() }
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
        if paused || manualMode { return }
        if let rev = p.rev, rev != rotRev { return }
        if p.kind == "clear" { invalidatePending(); latestBlocks = []; handleClear(); return }
        guard p.kind == "ocr" else { return }
        let candidateTexts = extractTexts(p.lines, count: p.stable != false)
        guard !candidateTexts.isEmpty else { return }
        let candidateText = candidateTexts.map(TextSim.norm).joined(separator: "\n")
        if flag("steadyCaptions", true), let candidate = p.candidateID, activeCandidateText != candidateText {
            if let previous = activeCandidateID {
                diag.trace(previous, stage: "superseded", detail: "New subtitle candidate")
            }
            activeCandidateID = candidate; activeCandidateText = candidateText
            clearTask?.cancel(); clearTask = nil
            generation += 1
            cancelPresentation()
            queued = nil; specQueued = nil
            drainTask?.cancel()
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
                if flag("selectiveSpeculation", true), !SpeculationPolicy.credible(lines: p.lines, threshold: flag("coolMode", false) ? max(0.95, num("speculationConfidence", 0.85)) : num("speculationConfidence", 0.85)) {
                    if diag.enabled { diag.s.specSkipped += 1 }
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
        guard revision == rotRev else { return }

        let texts = candidateTexts
        guard !PipelineSafety.isRecentFragment(texts.joined(separator: "\n"), of: original,
                                               age: Date().timeIntervalSince(lastShowDate)) else { return }
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
        let blocks = selectBlocks(allBlocks)
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
    private func selectBlocks(_ blocks: [[OCRLine]]) -> [[OCRLine]] {
        guard !blocks.isEmpty else { return [] }
        let maxH = blocks.map { blockHeight($0) }.max() ?? 0
        var kept = blocks
        if mode == .movie {
            kept = blocks.filter { blockHeight($0) >= maxH * 0.7 }
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
            kept = groups.max(by: { a, b in a.reduce(0) { $0 + blockWeight($1) } < b.reduce(0) { $0 + blockWeight($1) } }) ?? []
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
        queued = blocks
        queuedAt = Date()
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
                if speculationAllowed { await process(sp, display: false) }
            }
        }
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
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        var out: [String] = []
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let s = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return true }
            if s.count < 4, let last = out.popLast() { out.append(last + " " + s) } else { out.append(s) }
            return true
        }
        return out.isEmpty ? [text] : out
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
        if !display && diag.enabled { diag.s.specStarted += 1 }
        defer {
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
            !Task.isCancelled && workContext == contextRevision && (!display || workGeneration == generation)
                && CandidateValidity.isCurrent(workCandidate, active: activeCandidateID, enabled: flag("steadyCaptions", true))
        }

        /// Remembers a finished sentence. Early (translate-ahead) results are marked so we can show how often they pay off.
        func store(_ key: String, _ out: String) {
            guard isCurrent() else { return }
            guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            cache[key] = out
            savedKeys.remove(key)
            if display && eligibleMemoryKeys.contains(key) {
                confirmedKeys.insert(key)
                queueMemory(key, out)
            }
            memoryDirty = true
            touchCache(key)
            if !display { specKeys.insert(key) }
        }

        for (bi, raw) in blocks.enumerated() {
            var text = cleanOn ? TextIntel.cleanOCR(raw) : raw
            for (from, to) in fixes { text = text.replacingOccurrences(of: from, with: to, options: [.caseInsensitive]) }
            guard let choice = detectSource(text, record: display) else {
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
                if display && diag.enabled { diag.s.sentences += sentences.count }
                var outs: [String?] = []
                for (si, s) in sentences.enumerated() {
                    let key = PipelineSafety.cacheKey(source: id, target: destination, text: s, protectedWords: prot.tokens.map { "\($0.0)=\($0.1)" }, rules: rules)
                    if memoryEligible { eligibleMemoryKeys.insert(key) }
                    let lookupStart = ProcessInfo.processInfo.systemUptime
                    var resolvedHit = bypassMemory ? nil : cache[key]
                    var diskHit = false
                    if resolvedHit == nil, !bypassMemory, memoryReady, flag("remember", true), !flag("privateSession", false) {
                        let lookup = await memoryStore.lookup(key: key)
                        guard isCurrent() else { return }
                        resolvedHit = lookup.value
                        diskHit = lookup.value != nil
                        if display {
                            let outcome: MemoryDiagnosticOutcome
                            switch lookup.outcome {
                            case "timeout": outcome = .timeout
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
                            let savedHit = diskHit || savedKeys.remove(key) != nil
                            if !diskHit { diag.recordMemory(speculativeHit ? .speculativeHit : .ramHit,
                                                                  durationMs: (ProcessInfo.processInfo.systemUptime - lookupStart) * 1000,
                                                                  candidate: currentPacket?.candidateID,
                                                                  frameIndex: currentPacket?.frames, unitKey: key) }
                            if memoryEligible && confirmedKeys.insert(key).inserted { queueMemory(key, hit) }
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
            let batch = await translateBatch(plan.unique, source: src, target: target, installed: installed)
            guard isCurrent() else { return }
            var uniqueResults: [String?]
            if let batch, batch.count == plan.unique.count {
                uniqueResults = batch.map(Optional.some)
            } else {
                diag.log("Batch failed – retrying unique sentences")
                uniqueResults = []
                for sentence in plan.unique {
                    guard isCurrent() else { return }
                    if !display && diag.enabled { diag.s.specModelRequests += 1 }
                    let result = await translateBatch([sentence], source: src, target: target, installed: installed)
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
                                installed: Bool) async -> [String]? {
        if #available(iOS 26.0, *), installed {
            let k = "\(source.minimalIdentifier)>\(targetCode)"
            if directSession == nil || directKey != k {
                directSession = TranslationSession(installedSource: source, target: target)
                directKey = k
            }
            if diag.enabled { diag.s.sessionKind = "Direct session (iOS 26)" }
            guard let session = directSession else { return nil }
            let r = await runBatch(session, texts)
            if r == nil { directSession = nil }
            return r
        }
        if diag.enabled { diag.s.sessionKind = "Hosted view (iOS 18)" }
        return await translateLegacy(texts, source: source, target: target)
    }

    private func runBatch(_ session: TranslationSession, _ texts: [String]) async -> [String]? {
        let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        do {
            let res = try await session.translations(from: reqs)
            return PipelineSafety.orderedTranslations(res.map { ($0.clientIdentifier, $0.targetText) }, count: texts.count)
        } catch {
            if Task.isCancelled { return nil }
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
        original = text
        translated = result
        showing = true
        lastTextDate = Date()
        lastShowDate = Date()
        let renderStart = Date()
        pip.setSize(windowSize.size)
        pip.style = pipStyle
        pip.render(original: text, translated: result, showOriginal: showOriginal)
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

    private func queueMemory(_ key: String, _ value: String) {
        guard flag("remember", true), !flag("privateSession", false) else { return }
        // Bound pending writes without claiming unsaved entries are durable.
        guard pendingMemory[key] != nil || pendingMemory.count < 3000 else {
            memoryFailure = "Memory write queue full; new entries remain session-only"
            return
        }
        pendingMemory[key] = value
        memoryPendingWrites = pendingMemory.count
        memoryDirty = true
        saveMemory()
    }

    func saveMemory(force: Bool = false) {
        guard memoryReady, !memorySaving, !memoryMutationInProgress, !pendingMemory.isEmpty else { return }
        memorySaving = true
        let snapshot = pendingMemory
        memoryRevision += 1
        let revision = memoryRevision
        Task { [weak self] in
            guard let self else { return }
            let writeStart = ProcessInfo.processInfo.systemUptime
            var committed = false
            do {
                self.memoryHealth = try await self.memoryStore.save(snapshot, revision: revision)
                committed = true
                if self.memoryRevision == revision {
                    for (key, value) in snapshot where self.pendingMemory[key] == value { self.pendingMemory[key] = nil }
                }
                self.memoryFailure = nil
                self.diag.recordMemory(.persisted, durationMs: (ProcessInfo.processInfo.systemUptime - writeStart) * 1000)
            } catch {
                self.memoryFailure = "Memory write failed; pending entries will retry"
                self.diag.recordMemory(.writeFailed, durationMs: (ProcessInfo.processInfo.systemUptime - writeStart) * 1000)
            }
            self.memorySaving = false
            self.memoryPendingWrites = self.pendingMemory.count
            self.memoryDirty = !self.pendingMemory.isEmpty
            if committed { self.memoryRetryAttempts = 0 }
            await self.refreshMemoryHealth()
            guard !self.pendingMemory.isEmpty else { return }
            if committed {
                // Confirmations queued during the previous commit must not get stranded.
                self.saveMemory(force: true)
            } else if self.memoryRetryAttempts < 3 {
                self.memoryRetryAttempts += 1
                let delay: UInt64 = [2, 5, 15][self.memoryRetryAttempts - 1] * 1_000_000_000
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: delay)
                    self?.saveMemory(force: true)
                }
            }
        }
    }

    func refreshMemoryHealth() async {
        do {
            let health = try await memoryStore.health()
            memoryHealth = health
            memoryCount = health.totalEntries
            diag.memoryHealth.totalEntries = health.totalEntries
            diag.memoryHealth.readyEntries = health.readyEntries
            diag.memoryHealth.needsValidation = health.needsValidation
            diag.memoryHealth.conflicts = health.conflicts
            diag.memoryHealth.databaseBytes = health.databaseBytes
            diag.memoryHealth.migrationStatus = health.migrationStatus
            diag.memoryHealth.integrity = health.integrity
            diag.memoryHealth.failedWrites = health.failedWrites
            diag.memoryHealth.pendingWrites = memoryPendingWrites
            diag.memoryHealth.ramEntries = cache.count
        } catch { memoryFailure = "Memory health unavailable" }
    }

    func clearRAMCache() {
        invalidatePending()
        cache.removeAll(); cacheUse.removeAll()
        specKeys.removeAll(); savedKeys.removeAll(); confirmedKeys.removeAll()
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
            specKeys.remove(key); savedKeys.remove(key); confirmedKeys.remove(key)
        }
        // Report entries evicted, not maintenance batches; persistence is untouched.
        diag.recordMemory(.ramEviction, count: victims.count)
    }

    // MARK: Keep the translator warm
    private static let warmWords = ["en": "Hello.", "pt": "Olá.", "es": "Hola.", "fr": "Bonjour.", "de": "Hallo.",
                                    "it": "Ciao.", "ja": "こんにちは。", "ko": "안녕하세요.", "zh": "你好。", "ru": "Привет."]

    /// Loads the translation models before they're needed so the first real sentence isn't slow.
    func prewarm() async {
        guard runtimePolicy.allowsPrewarming, flag("keepWarm", true), !paused, !busy, !warming,
              Date().timeIntervalSince(lastWarm) > 25 else { return }
        warming = true
        defer { warming = false }
        let code: String
        if sourceCode != "auto" { code = sourceCode }
        else if let l = lockedLang { code = l }
        else if detectedLang != "–" { code = detectedLang }
        else { return }
        let workContext = contextRevision
        let destination = targetCode
        let src = Locale.Language(identifier: code)
        let target = Locale.Language(identifier: destination)
        guard src.languageCode != target.languageCode,
              let word = Self.warmWords[src.languageCode?.identifier ?? code] else { return }
        guard await pairStatus(src, target) == .installed, workContext == contextRevision, !busy,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return }
        // Direct sessions can warm independently; the iOS 18 hosted path has one continuation.
        guard #available(iOS 26.0, *) else { return }
        lastWarm = Date()
        let t0 = Date()
        let session = TranslationSession(installedSource: src, target: target)
        _ = await runBatch(session, [word])
        if !busy, workContext == contextRevision, directSession == nil {
            directSession = session
            directKey = "\(src.minimalIdentifier)>\(destination)"
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        if ms > 300 { diag.event(.translation, "Warmed up the translator in \(Int(ms)) ms") }
    }

    /// Translate the current text again from scratch (ignores the cache).
    func retranslate() {
        guard !original.isEmpty else { return }
        invalidatePending()
        cache.removeAll()
        specKeys.removeAll(); savedKeys.removeAll(); confirmedKeys.removeAll()
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
    private func translateLegacy(_ texts: [String], source: Locale.Language, target: Locale.Language) async -> [String]? {
        let requestID = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { (cont: CheckedContinuation<[String]?, Never>) in
                legacyRequestID = requestID
                legacyContinuation = cont
                pendingTexts = texts
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
        let result = await runBatch(session, texts)
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
