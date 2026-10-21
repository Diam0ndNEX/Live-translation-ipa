// Screen Translator – App – v0.5.0
import SwiftUI
import Translation
import NaturalLanguage
import AVFoundation
import Network

enum TranslateMode: String, CaseIterable, Identifiable {
    case movie, game, comic
    var id: String { rawValue }
    var title: String {
        switch self { case .movie: "Movie / subtitles"; case .game: "Game / apps"; case .comic: "Comic / manga" }
    }
}
enum OCRArea: String, CaseIterable, Identifiable {
    case smart, full, bottom, top, middle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: "Smart (auto)"; case .full: "Full screen"; case .bottom: "Bottom third"
        case .top: "Top half"; case .middle: "Middle band"
        }
    }
    func range(mode: TranslateMode) -> ClosedRange<Double> {   // y: 0 = bottom, 1 = top
        switch self {
        case .smart: return 0.04...0.92
        case .full: return 0...1
        case .bottom: return 0...0.33
        case .top: return 0.5...1
        case .middle: return 0.3...0.7
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

struct HistoryItem: Identifiable {
    let id = UUID()
    let original: String
    let translated: String
    var date = Date()
}

@MainActor
final class TranslatorEngine: ObservableObject {
    // Settings
    @Published var sourceCode: String {
        didSet { UserDefaults.standard.set(sourceCode, forKey: "source"); lastHandled = ""; syncConfig() }
    }
    @Published var targetCode: String {
        didSet {
            UserDefaults.standard.set(targetCode, forKey: "target"); lastHandled = ""; directSession = nil
            Task { await refreshStatus() }
        }
    }
    @Published var paused = false { didSet { syncConfig() } }
    // Languages
    @Published var languages: [LangItem] = TranslatorEngine.fallbackLanguages
    @Published var langStatus: [String: LanguageAvailability.Status] = [:]
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
    @Published var history: [HistoryItem] = []
    // Translation session plumbing
    @Published var legacyConfig: TranslationSession.Configuration?
    @Published var downloadConfig: TranslationSession.Configuration?

    let pip = PiPRenderer()
    let server = LoopbackServer()

    private var lastHandled = ""
    private var queued: String?
    private var busy = false
    private var showing = false
    private var pendingText = ""
    private var legacyContinuation: CheckedContinuation<String?, Never>?
    private var lastPacketDate = Date.distantPast
    private var cache: [String: String] = [:]
    private var directSession: TranslationSession?
    private var directKey = ""

    // Self-reading protection: what the PiP window currently shows, and where it is on screen
    private let placeholderGrams = TextSim.grams("Waiting for screen text… Listening…")
    private var renderedGrams = TextSim.grams("Waiting for screen text… Listening…")
    private var sourceGrams: Set<String> = []
    private var pipRegion: CGRect?
    private var pipRegionStamp = Date.distantPast

    private var ud: UserDefaults { .standard }
    private var mode: TranslateMode { TranslateMode(rawValue: ud.string(forKey: "mode") ?? "") ?? .movie }
    private var area: OCRArea { OCRArea(rawValue: ud.string(forKey: "area") ?? "") ?? .smart }
    private var windowSize: WindowSize { WindowSize(rawValue: ud.string(forKey: "winSize") ?? "") ?? .normal }
    private var speed: SpeedPreset { SpeedPreset(rawValue: ud.string(forKey: "speed") ?? "") ?? .balanced }
    private var showOriginal: Bool { (ud.object(forKey: "showOriginal") as? Bool) ?? false }
    private var autoClear: Bool { (ud.object(forKey: "autoClear") as? Bool) ?? true }

    init() {
        sourceCode = UserDefaults.standard.string(forKey: "source") ?? "auto"
        targetCode = UserDefaults.standard.string(forKey: "target") ?? "en"
        server.onPacket = { [weak self] p in Task { @MainActor in self?.handle(p) } }
        server.start()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let alive = Date().timeIntervalSince(self.lastPacketDate) < 5
                if self.captureAlive && !alive {
                    self.status = "Capture stopped – iOS may have closed the capture extension. Tap the broadcast icon again (try Speed: Fast)."
                }
                self.captureAlive = alive
            }
        }
        pip.setSize(windowSize.size)
        pip.onStatus = { [weak self] s in Task { @MainActor in self?.status = s } }
        pip.onActiveChange = { [weak self] a in Task { @MainActor in self?.pipActive = a } }
    }

    // MARK: Settings → capture extension
    /// Sends OCR area, source-language hint and speed to the extension.
    func syncConfig() {
        let r = area.range(mode: mode)
        server.send(Config(lang: sourceCode, y0: r.lowerBound, y1: r.upperBound,
                           maxEdge: speed.maxEdge, interval: speed.interval, paused: paused))
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
        sourceCode = targetCode
        targetCode = s
    }
    func applyWindowSize() { pip.setSize(windowSize.size) }

    // MARK: Packets from the extension
    private func handle(_ p: Packet) {
        let wasAlive = captureAlive
        lastPacketDate = Date()
        captureAlive = true
        frames = p.frames
        extensionVersion = p.version
        if let t = p.ocrMs { ocrMs = t }
        if let m = p.memFreeMB { extFreeMB = m }

        if !wasAlive {
            syncConfig()
            // Capture just started: make sure the floating window is up too.
            if !pip.isActive, UIApplication.shared.applicationState == .active { startPiP() }
        }
        if p.kind == "ping" { syncConfig(); return }       // keeps the extension's settings fresh
        if paused { return }
        if p.kind == "clear" { handleClear(); return }
        guard p.kind == "ocr" else { return }
        ocrCount += 1
        lastRaw = String(p.lines.map(\.t).joined(separator: " ").prefix(160))

        let range = area.range(mode: mode)
        var cand = p.lines.filter { range.contains($0.y) }
        cand = removeOwnOutput(cand)
        // Smart: keep the dominant (biggest) text, ignore small UI/watermark text
        if area == .smart, let maxH = cand.map(\.h).max() {
            cand = cand.filter { $0.h >= maxH * 0.55 }
        }
        let texts = dedupe(cand.map(\.t).filter { !isTargetLanguage($0) })
        guard !texts.isEmpty else { handleClear(); return }
        let text = String(texts.joined(separator: mode == .movie ? " " : "\n").prefix(500))
        enqueue(text)
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

    private func enqueue(_ text: String) {
        guard text != lastHandled else { return }
        if TextSim.similar(text, lastHandled, 0.92) { lastHandled = text; return }   // tiny OCR jitter
        lastHandled = text
        queued = text
        if !busy { Task { await drain() } }
    }

    private func handleClear() {
        guard autoClear, showing else { return }
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
        busy = true
        defer { busy = false }
        // Always translate only the newest text; anything older is already out of date.
        while let t = queued { queued = nil; await process(t) }
    }

    // MARK: Translation
    private func process(_ text: String) async {
        let t0 = Date()
        let target = Locale.Language(identifier: targetCode)
        let cacheKey = "\(sourceCode)>\(targetCode)|\(text)"
        if let hit = cache[cacheKey] { show(text, hit); return }

        let source: Locale.Language
        if sourceCode == "auto" {
            let rec = NLLanguageRecognizer()
            rec.processString(text)
            // Prefer a language whose pack is installed when the detector is torn between candidates
            let installed = Set(languages.filter { langStatus[$0.code] == .installed }.map {
                $0.code == "zh" ? NLLanguage.simplifiedChinese : NLLanguage(rawValue: $0.code)
            })
            var dom = rec.dominantLanguage
            if let best = rec.languageHypotheses(withMaximum: 5)
                .filter({ installed.contains($0.key) }).max(by: { $0.value < $1.value }), best.value > 0.15 {
                dom = best.key
            }
            guard let dom else { status = "Couldn't detect the language"; return }
            source = Locale.Language(identifier: dom.rawValue)
        } else {
            source = Locale.Language(identifier: sourceCode)
        }
        if source.languageCode == target.languageCode { status = "Text is already in the target language"; return }

        let availability: LanguageAvailability.Status
        if sourceCode != "auto", let s = langStatus[sourceCode] {
            availability = s
        } else {
            availability = await LanguageAvailability().status(from: source, to: target)
        }
        if availability == .unsupported {
            status = "\(source.minimalIdentifier) → \(targetCode) isn't supported"; return
        }

        var result: String?
        if #available(iOS 26.0, *), availability == .installed {
            let k = "\(source.minimalIdentifier)>\(targetCode)"
            if directSession == nil || directKey != k {
                directSession = TranslationSession(installedSource: source, target: target)
                directKey = k
            }
            result = try? await directSession?.translate(text).targetText
            if result == nil { directSession = nil }
        } else {
            if availability == .supported { status = "Language pack missing – open the Languages tab" }
            result = await translateLegacy(text, source: source, target: target)
        }
        guard let result else {
            status = "Translation failed – download the language packs (Languages tab)"; return
        }
        translateMs = Date().timeIntervalSince(t0) * 1000
        if cache.count > 300 { cache.removeAll() }
        cache[cacheKey] = result
        status = "\(source.minimalIdentifier) → \(targetCode) ✓"
        show(text, result)
    }

    private func show(_ text: String, _ result: String) {
        original = text
        translated = result
        showing = true
        if history.first?.original != text {
            history.insert(HistoryItem(original: text, translated: result), at: 0)
            if history.count > 100 { history.removeLast() }
        }
        renderedGrams = TextSim.grams(result).union(placeholderGrams)
        sourceGrams = TextSim.grams(text)
        pip.setSize(windowSize.size)
        pip.render(original: text, translated: result, showOriginal: showOriginal)
    }

    // iOS 18 path (needs the hosted .translationTask view in RootView)
    private func translateLegacy(_ text: String, source: Locale.Language, target: Locale.Language) async -> String? {
        await withCheckedContinuation { cont in
            legacyContinuation = cont
            pendingText = text
            if var c = legacyConfig, c.source == source, c.target == target {
                c.invalidate(); legacyConfig = c
            } else {
                legacyConfig = .init(source: source, target: target)
            }
            Task { try? await Task.sleep(for: .seconds(10)); finishLegacy(nil) }
        }
    }
    func runLegacy(_ session: TranslationSession) async {
        do { finishLegacy(try await session.translate(pendingText).targetText) }
        catch { finishLegacy(nil) }
    }
    private func finishLegacy(_ s: String?) {
        legacyContinuation?.resume(returning: s)
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
        let target = Locale.Language(identifier: targetCode)
        let av = LanguageAvailability()
        var out: [String: LanguageAvailability.Status] = [:]
        for l in languages {
            out[l.code] = await av.status(from: Locale.Language(identifier: l.code), to: target)
        }
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
        try? await session.prepareTranslation()
        await refreshStatus()
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
        enqueue(samples[key] ?? samples["en"]!)
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
