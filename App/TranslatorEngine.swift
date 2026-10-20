// Screen Translator – App – v0.3.0
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
        case .smart: "Smart"; case .full: "Full screen"; case .bottom: "Bottom third"
        case .top: "Top half"; case .middle: "Middle band"
        }
    }
    func range(mode: TranslateMode) -> ClosedRange<Double> {   // y: 0 = bottom, 1 = top
        switch self {
        case .smart: return mode == .movie ? 0...0.45 : 0...1
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

struct LangItem: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

@MainActor
final class TranslatorEngine: ObservableObject {
    // Settings
    @Published var sourceCode: String {
        didSet { UserDefaults.standard.set(sourceCode, forKey: "source"); lastHandled = "" }
    }
    @Published var targetCode: String {
        didSet {
            UserDefaults.standard.set(targetCode, forKey: "target"); lastHandled = ""
            Task { await refreshStatus() }
        }
    }
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
    // Translation session plumbing
    @Published var legacyConfig: TranslationSession.Configuration?
    @Published var downloadConfig: TranslationSession.Configuration?

    let pip = PiPRenderer()
    let server = LoopbackServer()

    private var lastHandled = ""
    private var queued: String?
    private var busy = false
    private var pendingText = ""
    private var legacyContinuation: CheckedContinuation<String?, Never>?
    private var lastPacketDate = Date.distantPast

    private var ud: UserDefaults { .standard }
    private var mode: TranslateMode { TranslateMode(rawValue: ud.string(forKey: "mode") ?? "") ?? .movie }
    private var area: OCRArea { OCRArea(rawValue: ud.string(forKey: "area") ?? "") ?? .smart }
    private var windowSize: WindowSize { WindowSize(rawValue: ud.string(forKey: "winSize") ?? "") ?? .normal }
    private var showOriginal: Bool { (ud.object(forKey: "showOriginal") as? Bool) ?? true }

    init() {
        sourceCode = UserDefaults.standard.string(forKey: "source") ?? "auto"
        targetCode = UserDefaults.standard.string(forKey: "target") ?? "en"
        server.onPacket = { [weak self] p in Task { @MainActor in self?.handle(p) } }
        server.start()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.captureAlive = Date().timeIntervalSince(self.lastPacketDate) < 5
            }
        }
        pip.setSize(windowSize.size)
        pip.onStatus = { [weak self] s in Task { @MainActor in self?.status = s } }
        pip.onActiveChange = { [weak self] a in Task { @MainActor in self?.pipActive = a } }
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
        lastPacketDate = Date()
        captureAlive = true
        frames = p.frames
        extensionVersion = p.version
        guard p.kind == "ocr" else { return }
        ocrCount += 1

        let range = area.range(mode: mode)
        let lines = p.lines.filter { range.contains($0.y) }.map(\.t).filter { !isTargetLanguage($0) }
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: mode == .movie ? " " : "\n")
        enqueue(text)
    }

    private func enqueue(_ text: String) {
        guard text != lastHandled else { return }
        lastHandled = text
        queued = text
        if !busy { Task { await drain() } }
    }

    /// Drops lines already in the target language (also stops feedback if the PiP window is captured).
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
        while let t = queued { queued = nil; await process(t) }
    }

    // MARK: Translation
    private func process(_ text: String) async {
        let target = Locale.Language(identifier: targetCode)
        let source: Locale.Language
        if sourceCode == "auto" {
            let rec = NLLanguageRecognizer()
            rec.processString(text)
            guard let dom = rec.dominantLanguage else { status = "Couldn't detect the language"; return }
            source = Locale.Language(identifier: dom.rawValue)
        } else {
            source = Locale.Language(identifier: sourceCode)
        }
        if source.languageCode == target.languageCode { status = "Text is already in the target language"; return }

        let availability = await LanguageAvailability().status(from: source, to: target)
        if availability == .unsupported {
            status = "\(source.minimalIdentifier) → \(targetCode) isn't supported"; return
        }

        var result: String?
        if #available(iOS 26.0, *), availability == .installed {
            let session = TranslationSession(installedSource: source, target: target)
            result = try? await session.translate(text).targetText
        } else {
            if availability == .supported { status = "Language pack missing – open the Languages tab" }
            result = await translateLegacy(text, source: source, target: target)
        }
        guard let result else {
            status = "Translation failed – download the language packs (Languages tab)"; return
        }
        original = text
        translated = result
        status = "\(source.minimalIdentifier) → \(targetCode) ✓"
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

// MARK: - Loopback server (merged from LoopbackServer.swift)
/// Receives OCR packets from the broadcast extension over 127.0.0.1 (UDP).
final class LoopbackServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "loopback.server")
    var onPacket: ((Packet) -> Void)?

    func start() {
        stop()
        guard let port = NWEndpoint.Port(rawValue: Loopback.port),
              let l = try? NWListener(using: .udp, on: port) else { return }
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
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

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            if let data, let p = try? JSONDecoder().decode(Packet.self, from: data) {
                DispatchQueue.main.async { self?.onPacket?(p) }
            }
            if error == nil { self?.receive(on: c) }
        }
    }
}
