// Screen Translator – App – v0.11.0
import SwiftUI
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
    case fast, balanced, sharp
    var id: String { rawValue }
    var title: String {
        switch self { case .fast: "Fast"; case .balanced: "Balanced"; case .sharp: "Sharp (small text)" }
    }
    var maxEdge: Double {
        switch self { case .fast: 1000; case .balanced: 1400; case .sharp: 2000 }
    }
    var interval: Double {
        switch self { case .fast: 0.12; case .balanced: 0.22; case .sharp: 0.4 }
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
        "autoCopy", "adaptive", "idleMinutes", "translateAhead", "keepWarm", "remember"
    ]
    /// App look & behaviour that presets do not touch.
    static let interfaceKeys = ["accent", "keepAwake", "saveHistory", "historyRetentionDays", "uiHaptics",
                                "homePresets", "homeTools", "homeQuick", "homeStatus", "homeRecent", "privateSession", "diagIncludeText",
                                "sessionLimit", "readerSize", "readerOriginal", "readerAlignment", "ocrConfidence", "ocrCorrection", "idleBackoff"]
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
        "privateSession": false, "diagIncludeText": false, "sessionLimit": 0, "readerSize": 28.0,
        "readerOriginal": true, "readerAlignment": false, "ocrConfidence": 0.3, "ocrCorrection": true, "idleBackoff": true
    ]

    // Settings that live in the engine
    @Published var sourceCode: String {
        didSet { UserDefaults.standard.set(sourceCode, forKey: "source"); invalidatePending(); lockedLang = nil; directSession = nil; syncConfig(); noteRecentPair() }
    }
    @Published var targetCode: String {
        didSet {
            UserDefaults.standard.set(targetCode, forKey: "target"); invalidatePending(); directSession = nil; langStatus = [:]; availCache.removeAll()
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
    private var undoHistory: [HistoryItem]?
    @Published var toastText: String?
    @Published var detectedLang = "–"
    @Published var recentPairs: [String] = []
    @Published var memoryCount = 0
    // Languages
    @Published var languages: [LangItem] = TranslatorEngine.fallbackLanguages
    @Published var langStatus: [String: LanguageAvailability.Status] = [:]
    @Published var lockedLang: String? = nil { didSet { diag.s.lockedLang = lockedLang ?? "–" } }
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

    private var contextRevision = 0
    private var generation = 0
    private var legacyRequestID = UUID()
    private var latestBlocks: [String] = []
    private var lastHandled = ""
    private var queued: [String]?
    private var queuedTs: Double = 0
    private var currentTs: Double = 0
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
    private let memoryWriter = MemoryWriter()
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
    private var detectLog: [String] = []
    private var mismatchStreak = 0

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
        server.onPacket = { [weak self] p in Task { @MainActor in self?.handle(p) } }
        server.start()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        pip.setSize(windowSize.size)
        pip.onStatus = { [weak self] s in Task { @MainActor in self?.status = s } }
        pip.onActiveChange = { [weak self] a in
            Task { @MainActor in self?.pipActive = a; self?.diag.log(a ? "Floating window opened" : "Floating window closed") }
        }
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
        captureAlive = alive
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
        autoRot = 0; trial = 0; orderVote = 0; votesSinceChange = 0; calibrated = false
        rotRev += 1
        invalidatePending()
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
        diag.s.rotation = effectiveRot
        server.send(Config(lang: lockedLang ?? sourceCode, y0: r.lowerBound, y1: r.upperBound,
                           maxEdge: maxEdge, interval: interval, paused: paused || manualMode,
                           stability: int("stability", 2), rot: effectiveRot, rev: rotRev,
                           boost: int("boost", 1), skipUnchanged: flag("skipUnchanged", true),
                           speculate: flag("translateAhead", true), confidence: num("ocrConfidence", 0.3),
                           correction: flag("ocrCorrection", true), idleBackoff: flag("idleBackoff", true)))
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
    func applyStyle() { pip.style = pipStyle; pip.rerender(showOriginal: showOriginal) }

    /// A shareable picture of one history entry.
    func image(for h: HistoryItem) -> UIImage {
        PiPRenderer.image(original: h.original, translated: h.translated, showOriginal: true,
                          size: CGSize(width: 720, height: 420), style: pipStyle)
    }

    /// Invalidate suspended work before changing language, capture state, or settings.
    private func invalidatePending() {
        contextRevision += 1
        generation += 1
        queued = nil
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
        lockedLang = nil; detectLog = []; mismatchStreak = 0
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
        history = Array(history.sorted { $0.date > $1.date }.prefix(500))
        applyHistoryRetention()
        return true
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

    // MARK: History storage
    private func saveHistory() {
        guard flag("saveHistory", true), !flag("privateSession", false) else { return }
        let days = int("historyRetentionDays", 0)
        let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 86400) : Date.distantPast
        let retained = Array(history.filter { $0.starred || $0.date >= cutoff }.prefix(500))
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
    private func handle(_ p: Packet) {
        let now = Date()
        let wasAlive = captureAlive
        lastPacketDate = now
        captureAlive = true
        frames = p.frames
        extensionVersion = p.version
        if let t = p.ocrMs { ocrMs = t }
        if let m = p.memFreeMB { extFreeMB = m }
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
        if p.kind == "ping" { syncConfig(); return }          // keeps the extension's settings fresh
        if paused || manualMode { return }
        if let rev = p.rev, rev != rotRev { return }
        if p.kind == "clear" { invalidatePending(); latestBlocks = []; handleClear(); return }
        guard p.kind == "ocr" else { return }
        // First, unconfirmed sighting: translate quietly now so the result is ready the moment the text is confirmed.
        if p.stable == false {
            if flag("translateAhead", true) {
                let early = extractTexts(p.lines, count: false)
                if !early.isEmpty { speculate(early) }
            }
            return
        }
        ocrCount += 1
        lastRaw = String(p.lines.map(\.t).joined(separator: " ").prefix(160))

        // Is text arriving upside down? Votes only count packets made with the current rotation.
        let revision = rotRev
        updateOrderVote(removeOwnOutput(p.lines))
        guard revision == rotRev else { return }

        let texts = extractTexts(p.lines, count: true)
        guard !texts.isEmpty else { return }
        guard !PipelineSafety.isRecentFragment(texts.joined(separator: "\n"), of: original,
                                               age: Date().timeIntervalSince(lastShowDate)) else { return }
        latestBlocks = texts
        clearTask?.cancel()
        clearTask = nil
        queuedTs = p.ts ?? now.timeIntervalSince1970
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
            if count { diag.s.linesIn += 1 }
            if !range.contains(l.y) { if count { diag.s.dropArea += 1 }; continue }
            if l.h < minH { if count { diag.s.dropSmall += 1 }; continue }
            if ignore.contains(where: { l.t.lowercased().contains($0) }) { if count { diag.s.dropIgnore += 1 }; continue }
            cand.append(l)
        }
        let n1 = cand.count
        cand = removeOwnOutput(cand)
        if count { diag.s.dropSelf += n1 - cand.count }
        let allBlocks = makeBlocks(cand)
        if count { diag.s.blocksIn += allBlocks.count }
        let blocks = selectBlocks(allBlocks)
        if count { diag.s.blocksKept += blocks.count }
        var texts: [String] = []
        for b in blocks {
            let t = blockText(b)
            if TextSim.norm(t).count < 2 { continue }
            if flag("dropNoise", true) && TextIntel.isNoise(t) { if count { diag.s.dropNoise += 1 }; continue }
            if isTargetLanguage(t) { if count { diag.s.dropTarget += b.count }; continue }
            if !plausiblySource(t) { if count { diag.s.dropLanguage += 1 }; continue }
            texts.append(t)
        }
        return dedupe(texts).map { String($0.prefix(400)) }
    }

    /// Queues a quiet, low-priority translation that only fills the cache.
    private func speculate(_ blocks: [String]) {
        let thermal = ProcessInfo.processInfo.thermalState
        if ProcessInfo.processInfo.isLowPowerModeEnabled || thermal == .serious || thermal == .critical { return }
        let joined = blocks.joined(separator: "\n")
        guard !frozen, joined != lastHandled, joined != lastSpecText else { return }
        lastSpecText = joined
        specQueued = blocks
        if !busy { Task { await drain() } }
    }

    // MARK: Reading-order calibration
    /// Reads each text block forwards and backwards; if backwards reads more naturally, the frame is upside down.
    private func updateOrderVote(_ lines: [OCRLine]) {
        var diff = 0.0
        for b in makeBlocks(lines) where b.count >= 2 {
            let fwd = readingOrder(b).map(\.t)
            diff += TextIntel.orderScore(fwd) - TextIntel.orderScore(Array(fwd.reversed()))
        }
        guard diff != 0 else { return }
        orderVote = max(-30, min(30, orderVote * 0.8 + diff))
        votesSinceChange += 1
        diag.s.orderVote = orderVote
        guard frameRotMode == "auto" else { return }
        if orderVote < -4 && votesSinceChange >= 2 {
            trial = (trial + 1) % 4
            autoRot = [0, 2, 1, 3][trial]
            rotRev += 1
            invalidatePending()
            orderVote = 0; votesSinceChange = 0; calibrated = false
            diag.s.calibrated = false
            diag.log("Reading order looks reversed → trying rotation \(autoRot * 90)°")
            syncConfig()
        } else if orderVote > 4 && !calibrated {
            calibrated = true
            diag.s.calibrated = true
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

    /// With a chosen source language, skips blocks that are clearly written in another language.
    private func plausiblySource(_ text: String) -> Bool {
        guard sourceCode != "auto", text.count >= 8 else { return true }
        let rec = NLLanguageRecognizer()
        rec.processString(text)
        let hyp = rec.languageHypotheses(withMaximum: 3)
        guard let top = hyp.max(by: { $0.value < $1.value }), top.value > 0.8 else { return true }
        let src = Locale.Language(identifier: sourceCode).languageCode
        let ps = hyp.filter { Locale.Language(identifier: $0.key.rawValue).languageCode == src }.map(\.value).max() ?? 0
        return ps > 0.15
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
                diag.s.pipRegion = "x \(Int(g.minX * 100))–\(Int(g.maxX * 100))%, y \(Int(g.minY * 100))–\(Int(g.maxY * 100))%"
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
        lastHandled = joined
        queued = blocks
        if !busy { Task { await drain() } }
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

    /// Drops lines already in the target language.
    private func isTargetLanguage(_ s: String) -> Bool {
        guard s.count >= 12 else { return false }
        let r = NLLanguageRecognizer()
        r.processString(s)
        guard let d = r.dominantLanguage,
              (r.languageHypotheses(withMaximum: 1)[d] ?? 0) > 0.8 else { return false }
        return Locale.Language(identifier: d.rawValue).languageCode
            == Locale.Language(identifier: targetCode).languageCode
    }

    private func drain() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        // Confirmed text always goes first, and only the newest of it; early sightings fill the cache when idle.
        while queued != nil || specQueued != nil {
            if queued != nil {
                let wait = num("minDisplay", 0) - Date().timeIntervalSince(lastShowDate)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard let b = queued else { continue }
                queued = nil
                currentTs = queuedTs
                await process(b, display: true)
            } else if let sp = specQueued {
                specQueued = nil
                await process(sp, display: false)
            }
        }
    }

    // MARK: Translation
    private func detectSource(_ text: String, record: Bool = true) -> Locale.Language? {
        if sourceCode != "auto" { return Locale.Language(identifier: sourceCode) }
        let rec = NLLanguageRecognizer()
        rec.processString(text)
        let hyp = rec.languageHypotheses(withMaximum: 5)
        let useLock = flag("langLock", true)
        if useLock, let locked = lockedLang {
            let p = hyp[NLLanguage(rawValue: locked)] ?? 0
            if p > 0.1 || text.count < 12 { mismatchStreak = 0; return Locale.Language(identifier: locked) }
            mismatchStreak += 1
            if mismatchStreak >= 3 {
                lockedLang = nil; detectLog = []; mismatchStreak = 0
                diag.log("Language lock released")
            } else {
                return Locale.Language(identifier: locked)
            }
        }
        // Prefer a language whose pack is installed when the detector is torn between candidates
        let installed = Set(languages.filter { langStatus[$0.code] == .installed }.map {
            $0.code == "zh" ? NLLanguage.simplifiedChinese : NLLanguage(rawValue: $0.code)
        })
        var dom = rec.dominantLanguage
        if let best = hyp.filter({ installed.contains($0.key) }).max(by: { $0.value < $1.value }), best.value > 0.15 {
            dom = best.key
        }
        guard let d = dom else { return nil }
        let code = Locale.Language(identifier: d.rawValue).minimalIdentifier
        diag.s.detected = code
        detectedLang = code
        if record { diag.noteLanguage(code) }
        if useLock && record {
            detectLog.append(code)
            if detectLog.count > 6 { detectLog.removeFirst() }
            if detectLog.count >= 4, let top = Dictionary(grouping: detectLog, by: { $0 }).max(by: { $0.value.count < $1.value.count }),
               top.value.count >= 4 {
                lockedLang = top.key
                diag.log("Language locked to \(top.key)")
            }
        }
        return Locale.Language(identifier: d.rawValue)
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
        let workGeneration = generation
        let workContext = contextRevision
        let destination = targetCode
        let target = Locale.Language(identifier: destination)
        let cleanOn = flag("cleanOCR", true), slangOn = flag("slang", true), speakerOn = flag("speakerDetect", true)
        let fixes = pairs("sourceFixes")
        let never = list("neverTranslate", lower: false)

        var units: [[TUnit]] = []
        var pending: [String: [(b: Int, u: Int, s: Int, text: String)]] = [:]
        var srcLangs: [String: Locale.Language] = [:]
        var translatedAny = false
        func isCurrent() -> Bool {
            workContext == contextRevision && (!display || workGeneration == generation)
        }

        /// Remembers a finished sentence. Early (translate-ahead) results are marked so we can show how often they pay off.
        func store(_ id: String, _ sentence: String, _ out: String) {
            guard isCurrent() else { return }
            let key = PipelineSafety.cacheKey(source: id, target: destination, text: sentence, protectedWords: never)
            cache[key] = out
            memoryDirty = true
            memoryCount = cache.count
            if !display { specKeys.insert(key) }
        }

        for (bi, raw) in blocks.enumerated() {
            var text = cleanOn ? TextIntel.cleanOCR(raw) : raw
            for (from, to) in fixes { text = text.replacingOccurrences(of: from, with: to, options: [.caseInsensitive]) }
            guard let src = detectSource(text, record: display), src.languageCode != target.languageCode else {
                units.append([TUnit(label: nil, sentences: [text], out: [text], tokens: [])])
                continue
            }
            let id = src.minimalIdentifier
            srcLangs[id] = src
            if slangOn { text = TextIntel.expandSlang(text, lang: src.languageCode?.identifier ?? id) }
            let parts = speakerOn ? TextIntel.splitDialogue(text) : [(label: String?.none, text: text)]
            var row: [TUnit] = []
            for (ui, d) in parts.enumerated() {
                if display, let name = d.label { diag.learn(name) }
                let prot = TextIntel.protect(d.text, words: never)
                let sentences = splitSentences(prot.text)
                if display { diag.s.sentences += sentences.count }
                var outs: [String?] = []
                for (si, s) in sentences.enumerated() {
                    let key = PipelineSafety.cacheKey(source: id, target: destination, text: s, protectedWords: never)
                    if let hit = cache[key] {
                        outs.append(hit); translatedAny = true
                        if display {
                            if specKeys.remove(key) != nil { diag.s.specHits += 1 } else { diag.s.cacheHits += 1 }
                        }
                    } else {
                        outs.append(nil)
                        if display { diag.s.cacheMisses += 1 }
                        pending[id, default: []].append((bi, ui, si, s))
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
                if display { status = "\(id) → \(targetCode) isn't supported" }
                failed = true; continue
            }
            if availability == .supported && display { status = "Language pack missing – open the Languages tab" }
            if display { diag.s.batches += 1 }
            let installed = availability == .installed
            var results = await translateBatch(items.map { $0.text }, source: src, target: target, installed: installed)
            guard isCurrent() else { return }
            if results == nil || results?.count != items.count {
                // One bad sentence shouldn't lose the whole batch: retry them one by one.
                diag.log("Batch failed – retrying sentence by sentence")
                var singles: [String?] = []
                for it in items {
                    guard isCurrent() else { return }
                    if let r = await translateBatch([it.text], source: src, target: target, installed: installed), r.count == 1 {
                        singles.append(r[0])
                    } else {
                        singles.append(nil)
                        if display { diag.s.failures += 1 }
                    }
                }
                results = nil
                for (k, it) in items.enumerated() {
                    if let v = singles[k] {
                        units[it.b][it.u].out[it.s] = v
                        store(id, it.text, v)
                        translatedAny = true
                    } else { failed = true }
                }
            }
            if let r = results {
                translatedAny = true
                for (k, it) in items.enumerated() {
                    units[it.b][it.u].out[it.s] = r[k]
                    store(id, it.text, r[k])
                }
            }
        }
        guard isCurrent(), (!paused || manualMode) else { return }
        if cache.count > 3000 { trimCache() }

        guard translatedAny else {
            if display {
                status = failed ? "Translation failed – download the language packs (Languages tab)"
                                : "Text is already in the target language"
            }
            return
        }
        if !display { return }          // translate-ahead: the result now waits in the cache
        guard !failed else {
            lastHandled = ""
            status = "Translation incomplete – keeping the previous result. Tap Retry."
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
        translateMs = Date().timeIntervalSince(t0) * 1000
        var sentenceCount = 0
        for row in units { for u in row { sentenceCount += u.sentences.count } }
        diag.recordTranslate(ms: translateMs, sentences: sentenceCount,
                             from: srcLangs.keys.sorted().joined(separator: "+"), to: targetCode,
                             preview: outBlocks.joined(separator: " / "))
        diag.s.translations += 1
        diag.s.chars += blocks.joined().count
        status = "\(srcLangs.keys.sorted().joined(separator: "+")) → \(targetCode) ✓"
        show(blocks.joined(separator: "\n"), outBlocks.joined(separator: "\n"))
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
            diag.s.sessionKind = "Direct session (iOS 26)"
            guard let session = directSession else { return nil }
            let r = await runBatch(session, texts)
            if r == nil { directSession = nil }
            return r
        }
        diag.s.sessionKind = "Hosted view (iOS 18)"
        return await translateLegacy(texts, source: source, target: target)
    }

    private func runBatch(_ session: TranslationSession, _ texts: [String]) async -> [String]? {
        let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        guard let res = try? await session.translations(from: reqs) else { return nil }
        return PipelineSafety.orderedTranslations(res.map { ($0.clientIdentifier, $0.targetText) }, count: texts.count)
    }

    private func show(_ text: String, _ result: String) {
        clearTask?.cancel()
        clearTask = nil
        guard !frozen, (!paused || manualMode),
              !PipelineSafety.isRecentFragment(text, of: original, age: Date().timeIntervalSince(lastShowDate)) else { return }
        original = text
        translated = result
        showing = true
        lastTextDate = Date()
        lastShowDate = Date()
        if currentTs > 0 { diag.recordLatency(ms: (Date().timeIntervalSince1970 - currentTs) * 1000) }
        if history.first?.original != text {
            sessionTranslations += 1; sessionCharacters += text.count
            if !flag("privateSession", false) {
                history.insert(HistoryItem(original: text, translated: result,
                                           sourceLanguage: sourceCode == "auto" ? detectedLang : sourceCode,
                                           targetLanguage: targetCode), at: 0)
                if history.count > 500 { history.removeLast() }
            }
            if flag("speak", false) { speak(result) }
            if flag("haptics", false) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            if flag("autoCopy", false) { UIPasteboard.general.string = result }
        }
        renderedGrams = TextSim.grams(result).union(placeholderGrams)
        sourceGrams = TextSim.grams(text)
        pip.setSize(windowSize.size)
        pip.style = pipStyle
        pip.render(original: text, translated: result, showOriginal: showOriginal)
    }

    func speak(_ s: String) {
        let voices = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "pt": "pt-BR", "en": "en-US", "es": "es-ES",
                      "fr": "fr-FR", "de": "de-DE", "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR", "ru": "ru-RU",
                      "ar": "ar-SA", "tr": "tr-TR", "hi": "hi-IN", "id": "id-ID", "nl": "nl-NL", "pl": "pl-PL",
                      "th": "th-TH", "vi": "vi-VN", "uk": "uk-UA"]
        speech.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: s)
        u.voice = AVSpeechSynthesisVoice(language: voices[targetCode] ?? targetCode)
        u.rate = Float(num("speechRate", 0.5))
        speech.speak(u)
    }

    // MARK: Translation memory (kept between launches)
    private var memoryURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("translation-memory.json")
    }

    private func loadMemory() {
        guard flag("remember", true), let d = try? Data(contentsOf: memoryURL),
              let m = try? JSONDecoder().decode([String: String].self, from: d) else { return }
        cache = m
        memoryCount = m.count
    }

    func saveMemory(force: Bool = false) {
        guard flag("remember", true), !flag("privateSession", false), memoryDirty || force else { return }
        guard force || Date().timeIntervalSince(lastMemorySave) > 15 else { return }
        lastMemorySave = Date()
        memoryDirty = false
        let snapshot = cache
        memoryCount = snapshot.count
        let url = memoryURL
        memoryRevision += 1
        let revision = memoryRevision
        let writer = memoryWriter
        Task(priority: .utility) { [weak self] in
            let saved = await writer.save(snapshot, to: url, revision: revision)
            if !saved, self?.memoryRevision == revision {
                self?.memoryDirty = true
                self?.diag.log("Translation memory could not be saved; will retry")
            }
        }
    }

    func clearMemory() {
        cache.removeAll()
        specKeys.removeAll()
        memoryDirty = false
        memoryCount = 0
        memoryRevision += 1
        let revision = memoryRevision, url = memoryURL, writer = memoryWriter
        Task { await writer.clear(url, revision: revision) }
        toast("Translation memory cleared")
    }

    private func trimCache() {
        let extra = cache.count - 2000
        guard extra > 0 else { return }
        for k in cache.keys.prefix(extra) { cache[k] = nil }
    }

    // MARK: Keep the translator warm
    private static let warmWords = ["en": "Hello.", "pt": "Olá.", "es": "Hola.", "fr": "Bonjour.", "de": "Hallo.",
                                    "it": "Ciao.", "ja": "こんにちは。", "ko": "안녕하세요.", "zh": "你好。", "ru": "Привет."]

    /// Loads the translation models before they're needed so the first real sentence isn't slow.
    func prewarm() async {
        guard flag("keepWarm", true), !paused, !busy else { return }
        let code: String
        if sourceCode != "auto" { code = sourceCode }
        else if let l = lockedLang { code = l }
        else if detectedLang != "–" { code = detectedLang }
        else { return }
        let src = Locale.Language(identifier: code)
        let target = Locale.Language(identifier: targetCode)
        guard src.languageCode != target.languageCode,
              let word = Self.warmWords[src.languageCode?.identifier ?? code] else { return }
        guard await pairStatus(src, target) == .installed, !busy,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return }
        // Direct sessions can warm independently; the iOS 18 hosted path has one continuation.
        guard #available(iOS 26.0, *) else { return }
        lastWarm = Date()
        let t0 = Date()
        _ = await translateBatch([word], source: src, target: target, installed: true)
        let ms = Date().timeIntervalSince(t0) * 1000
        if ms > 300 { diag.event(.translation, "Warmed up the translator in \(Int(ms)) ms") }
    }

    /// Translate the current text again from scratch (ignores the cache).
    func retranslate() {
        guard !original.isEmpty else { return }
        cache.removeAll()
        specKeys.removeAll()
        memoryDirty = true
        lastHandled = ""
        let blocks = original.components(separatedBy: "\n")
        diag.log("Retranslating current text")
        enqueue(blocks)
    }

    func toggleStar(_ id: UUID) {
        if let i = history.firstIndex(where: { $0.id == id }) { history[i].starred.toggle() }
    }

    // iOS 18 path (needs the hosted .translationTask view in RootView)
    private func translateLegacy(_ texts: [String], source: Locale.Language, target: Locale.Language) async -> [String]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[String]?, Never>) in
            let requestID = UUID()
            legacyRequestID = requestID
            legacyContinuation = cont
            pendingTexts = texts
            if var c = legacyConfig, c.source == source, c.target == target {
                c.invalidate(); legacyConfig = c
            } else {
                legacyConfig = .init(source: source, target: target)
            }
            Task {
                try? await Task.sleep(for: .seconds(10))
                if legacyRequestID == requestID { finishLegacy(nil) }
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
        for l in languages {
            out[l.code] = await av.status(from: Locale.Language(identifier: l.code), to: target)
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
        do {
            try await session.prepareTranslation()
            downloadMessage = "Language pack ready"
            toast(downloadMessage)
        } catch {
            downloadMessage = "Download failed: " + error.localizedDescription
            toast("Download failed. Check Languages for details.")
        }
        await refreshStatus()
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
        rotationSettingChanged()
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
    private let queue = DispatchQueue(label: "loopback.server")
    var onPacket: ((Packet) -> Void)?

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
                DispatchQueue.main.async { self?.onPacket?(p) }
            }
            if error == nil { self?.receive(on: c) }
        }
    }
}
