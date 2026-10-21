// ScreenLingo – App – v0.7.0
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
        // Movie mode defaults to the subtitle band to avoid mixing background signs,
        // UI labels and unrelated text into the dialogue translation. Other modes
        // need a wider search area because text can appear anywhere on screen.
        case .smart:
            return mode == .movie ? 0.02...0.58 : 0.04...0.92
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

private struct StoredHistoryItem: Codable {
    let original: String
    let translated: String
    let date: Date
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
    @Published var lastSelectedBlocks = ""
    @Published var lastTranslationInput = ""
    @Published var lastOutputQuality = "Not evaluated"
    @Published var selectedBlockCount = 0
    @Published var lastOCRLineCount = 0
    @Published var ocrMs: Double = 0
    @Published var translateMs: Double = 0
    @Published var extFreeMB: Double = 0
    @Published var lastPacketAge: Double = 0
    @Published var lastDetectedLanguage = "—"
    @Published var cacheHits = 0
    @Published var translationFailures = 0
    @Published var lastTranslationError = "None"
    @Published var history: [HistoryItem] = [] {
        didSet { saveHistory() }
    }
    // Translation session plumbing
    @Published var legacyConfig: TranslationSession.Configuration?
    @Published var downloadConfig: TranslationSession.Configuration?

    let pip = PiPRenderer()
    let server = LoopbackServer()

    private var lastHandled = ""
    private var queued: [String]?
    private var busy = false
    private var showing = false
    private var pendingTexts: [String] = []
    private var legacyContinuation: CheckedContinuation<[String]?, Never>?
    private var legacyRequestID = UUID()
    private let speech = AVSpeechSynthesizer()
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
    private var speakEnabled: Bool { (ud.object(forKey: "speak") as? Bool) ?? false }
    private var pipStyle: PiPStyle {
        PiPStyle.make(theme: PiPTheme(rawValue: ud.string(forKey: "theme") ?? "") ?? .dark,
                      size: PiPTextSize(rawValue: ud.string(forKey: "textSize") ?? "") ?? .auto)
    }
    private var autoClear: Bool { (ud.object(forKey: "autoClear") as? Bool) ?? true }
    private var minimumOCRConfidence: Double { ud.object(forKey: "ocrConfidence") as? Double ?? 0.30 }
    private var languageCorrection: Bool { (ud.object(forKey: "languageCorrection") as? Bool) ?? true }

    init() {
        sourceCode = UserDefaults.standard.string(forKey: "source") ?? "auto"
        targetCode = UserDefaults.standard.string(forKey: "target") ?? "en"
        history = Self.loadHistory()
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
                self.lastPacketAge = self.lastPacketDate == .distantPast ? -1 : Date().timeIntervalSince(self.lastPacketDate)
            }
        }
        pip.setSize(windowSize.size)
        pip.onStatus = { [weak self] s in Task { @MainActor in self?.status = s } }
        pip.onActiveChange = { [weak self] a in Task { @MainActor in self?.pipActive = a } }
    }


    private static let historyKey = "screenlingo.history.v1"

    private static func loadHistory() -> [HistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let stored = try? JSONDecoder().decode([StoredHistoryItem].self, from: data) else { return [] }
        return stored.prefix(100).map { item in
            let value = HistoryItem(original: item.original, translated: item.translated, date: item.date)
            return value
        }
    }

    private func saveHistory() {
        let stored = history.prefix(100).map {
            StoredHistoryItem(original: $0.original, translated: $0.translated, date: $0.date)
        }
        guard let data = try? JSONEncoder().encode(Array(stored)) else { return }
        UserDefaults.standard.set(data, forKey: Self.historyKey)
    }

    // MARK: Settings → capture extension
    /// Sends OCR area, source-language hint and speed to the extension.
    func syncConfig() {
        let r = area.range(mode: mode)
        server.send(Config(lang: sourceCode, y0: r.lowerBound, y1: r.upperBound,
                           maxEdge: speed.maxEdge, interval: speed.interval, paused: paused,
                           minimumConfidence: minimumOCRConfidence, languageCorrection: languageCorrection))
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
    func applyStyle() { pip.style = pipStyle; pip.rerender() }

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
        lastRaw = String(p.lines.map(\.t).joined(separator: " ").prefix(500))
        lastOCRLineCount = p.lines.count

        let range = area.range(mode: mode)
        var cand = p.lines.filter { range.contains($0.y) }
        cand = removeOwnOutput(cand)
        cand = cand.filter { !isTargetLanguage($0.t) }
        // Group lines into text blocks (speech bubble, caption, background text…), read each in order
        let blocks = selectBlocks(makeBlocks(cand))
        let texts = dedupe(blocks.map { blockText($0) }.filter { TextSim.norm($0).count >= 2 && plausiblySource($0) })
        selectedBlockCount = texts.count
        lastSelectedBlocks = texts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        guard !texts.isEmpty else { handleClear(); return }

        // Translate dialogue as a contextual unit in movie/comic modes. Translating
        // each OCR box separately loses clause context and makes short fragments
        // such as "p-" and "pq ele..." independently translated/reordered.
        // Movie mode uses a single flowing subtitle string; comics keep line breaks
        // so the translation can infer dialogue layout without losing the order.
        if mode == .movie {
            let context = texts.map { String($0.prefix(400)) }.joined(separator: " ")
            enqueue([String(context.prefix(1800))])
        } else if mode == .comic {
            let context = texts.map { String($0.prefix(400)) }.joined(separator: "\n")
            enqueue([String(context.prefix(1800))])
        } else {
            enqueue(texts.map { String($0.prefix(400)) })
        }
    }

    // MARK: Text blocks
    /// Lines in reading order: top to bottom, left to right within a row.
    private func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        // Vision coordinates use a bottom-left origin: larger y is visually higher.
        // Explicit row bands avoid unstable ordering from fuzzy sort comparators.
        let sorted = lines.enumerated().sorted {
            if abs($0.element.y - $1.element.y) < 0.000001 { return $0.offset < $1.offset }
            return $0.element.y > $1.element.y
        }.map { $0.element }
        var rows: [[OCRLine]] = []
        var anchors: [Double] = []
        for line in sorted {
            let tolerance = max(0.012, min(max(line.h, 0.012), 0.06) * 0.55)
            if let idx = anchors.indices.first(where: { abs(anchors[$0] - line.y) <= tolerance }) {
                rows[idx].append(line)
                anchors[idx] = rows[idx].map(\.y).reduce(0, +) / Double(rows[idx].count)
            } else {
                rows.append([line])
                anchors.append(line.y)
            }
        }
        return rows.flatMap { row in
            row.enumerated().sorted {
                if abs($0.element.x - $1.element.x) < 0.000001 { return $0.offset < $1.offset }
                return $0.element.x < $1.element.x
            }.map { $0.element }
        }
    }

    /// Clusters lines that belong together (similar size, stacked closely, overlapping horizontally).
    private func makeBlocks(_ lines: [OCRLine]) -> [[OCRLine]] {
        let sorted = lines.sorted { $0.y != $1.y ? $0.y > $1.y : $0.x < $1.x }
        var blocks: [[OCRLine]] = []
        for l in sorted {
            let lw = l.w ?? 0.2
            var placed = false
            for i in blocks.indices {
                guard let last = blocks[i].last else { continue }
                let w2 = last.w ?? 0.2
                let overlap = min(l.x + lw / 2, last.x + w2 / 2) - max(l.x - lw / 2, last.x - w2 / 2)
                let xGap = max(0, max(l.x - lw / 2, last.x - w2 / 2) - min(l.x + lw / 2, last.x + w2 / 2))
                let gap = last.y - l.y
                let lineH = max(last.h, l.h)
                let sizeRatio = min(last.h, l.h) / max(last.h, l.h, 0.0001)
                let verticallyAdjacent = gap > 0.15 * lineH && gap < 2.8 * lineH
                let horizontalOverlap = overlap > 0.15 * min(lw, w2)
                // Center-aligned manga dialogue often has ragged line widths.
                // Group aligned lines even when their bounding boxes barely overlap.
                let sameTextColumn = abs(l.x - last.x) < max(0.075, 0.35 * max(lw, w2))
                let stacked = verticallyAdjacent && (horizontalOverlap || sameTextColumn)
                let sameRow = abs(gap) <= 0.45 * lineH && xGap < 0.08
                if sizeRatio > 0.42 && (stacked || sameRow) {
                    blocks[i].append(l)
                    placed = true
                    break
                }
            }
            if !placed { blocks.append([l]) }
        }
        return blocks
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
            // Subtitle mode prioritizes the largest, most subtitle-like blocks.
            kept = blocks.filter { blockHeight($0) >= maxH * 0.62 }
            if kept.count > 3 { kept = Array(kept.sorted { blockWeight($0) > blockWeight($1) }.prefix(3)) }
        } else if area == .smart {
            kept = blocks.filter { blockHeight($0) >= maxH * (mode == .comic ? 0.22 : 0.32) }
        }
        // Comic/game mode must not throw away small dialogue bubbles just because
        // they are smaller than a title or a background sign.
        let limit = mode == .comic ? 14 : (mode == .game ? 10 : 3)
        if kept.count > limit {
            kept = Array(kept.sorted { blockWeight($0) > blockWeight($1) }.prefix(limit))
        }
        func top(_ b: [OCRLine]) -> Double { b.map { $0.y + $0.h / 2 }.max() ?? 0 }
        func left(_ b: [OCRLine]) -> Double { b.map { $0.x - ($0.w ?? 0) / 2 }.min() ?? 0 }
        // Build explicit top-to-bottom row bands. A fuzzy pairwise comparator
        // can be non-transitive and accidentally shuffle complete dialogue blocks.
        let byTop = kept.enumerated().sorted {
            let ay = top($0.element), by = top($1.element)
            if abs(ay - by) < 0.000001 { return $0.offset < $1.offset }
            return ay > by
        }.map { $0.element }
        var rows: [[[OCRLine]]] = []
        var anchors: [Double] = []
        for block in byTop {
            let y = top(block)
            let tolerance = max(0.018, min(max(blockHeight(block), 0.018), 0.08) * 0.8)
            if let idx = anchors.indices.first(where: { abs(anchors[$0] - y) <= tolerance }) {
                rows[idx].append(block)
                anchors[idx] = rows[idx].map { top($0) }.reduce(0, +) / Double(rows[idx].count)
            } else {
                rows.append([block])
                anchors.append(y)
            }
        }
        let rightToLeft = mode == .comic && ud.bool(forKey: "rightToLeftReading")
        return rows.flatMap { row in
            row.enumerated().sorted {
                let ax = left($0.element), bx = left($1.element)
                if abs(ax - bx) < 0.000001 { return $0.offset < $1.offset }
                return rightToLeft ? ax > bx : ax < bx
            }.map { $0.element }
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
        guard joined != lastHandled else { return }
        if TextSim.similar(joined, lastHandled, 0.92) { lastHandled = joined; return }   // tiny OCR jitter
        lastHandled = joined
        queued = blocks
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

    /// Re-run translation on the most recently recognized text without restarting capture.
    func retranslateLast() {
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Nothing to re-translate yet"
            return
        }
        lastHandled = ""
        enqueue([original])
    }

    /// Retranslate the latest source text after evicting cached model output.
    func retranslateLastFresh() {
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Nothing to retry yet"
            return
        }
        let count = cache.count
        cache.removeAll()
        lastHandled = ""
        status = "Retrying without cached output (cleared \(count) entries)…"
        enqueue([original])
    }

    /// Clear cached translations when diagnosing a suspicious or stale result.
    func clearTranslationCache() {
        let count = cache.count
        cache.removeAll()
        status = "Translation cache cleared (\(count) entries)"
    }

    /// Clear the current floating-window result while keeping screen capture running.
    func clearCurrentTranslation() {
        showing = false
        lastHandled = ""
        original = ""
        translated = ""
        renderedGrams = placeholderGrams
        sourceGrams = []
        pip.render(original: "", translated: "Listening…", showOriginal: false)
        status = "Output cleared — capture is still running"
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
        while let b = queued { queued = nil; await process(b) }
    }

    // MARK: Translation
    private func detectSource(_ text: String) -> Locale.Language? {
        if sourceCode != "auto" { return Locale.Language(identifier: sourceCode) }
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
        guard let d = dom else { return nil }
        return Locale.Language(identifier: d.rawValue)
    }

    private func pairStatus(_ src: Locale.Language, _ target: Locale.Language) async -> LanguageAvailability.Status {
        if sourceCode != "auto", let s = langStatus[sourceCode] { return s }
        return await LanguageAvailability().status(from: src, to: target)
    }

    /// Splits a block into sentences so each is translated on its own (better quality, cacheable).
    private func splitSentences(_ text: String) -> [String] {
        guard text.count > 160 else { return [text] }
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

    private func process(_ blocks: [String]) async {
        let t0 = Date()
        lastTranslationError = "None"
        lastTranslationInput = blocks.joined(separator: "\n")
        let target = Locale.Language(identifier: targetCode)

        var sentences: [[String]] = []          // per block
        var done: [[String?]] = []              // translated sentence, nil = still to translate
        var pending: [String: [(block: Int, index: Int, text: String)]] = [:]
        var srcLangs: [String: Locale.Language] = [:]
        var translatedAny = false

        for (bi, text) in blocks.enumerated() {
            guard let src = detectSource(text), src.languageCode != target.languageCode else {
                sentences.append([text]); done.append([text]); continue
            }
            let id = src.minimalIdentifier
            lastDetectedLanguage = Locale.current.localizedString(forIdentifier: id) ?? id
            srcLangs[id] = src
            // Do not split ordinary multi-sentence dialogue into isolated fragments.
            // Short fragments lose grammatical context and can be translated in the
            // wrong order. Only split unusually long OCR dumps to keep requests bounded.
            let parts = text.count <= 900 ? [text] : splitSentences(text)
            sentences.append(parts)
            var row: [String?] = []
            for (si, part) in parts.enumerated() {
                if let hit = cache["\(id)>\(targetCode)|\(part)"] {
                    row.append(hit); translatedAny = true; cacheHits += 1
                } else {
                    row.append(nil)
                    pending[id, default: []].append((bi, si, part))
                }
            }
            done.append(row)
        }

        var failed = false
        for (id, items) in pending {
            guard let src = srcLangs[id] else { continue }
            let availability = await pairStatus(src, target)
            if availability == .unsupported { status = "\(id) → \(targetCode) isn't supported"; failed = true; continue }
            if availability == .supported { status = "Language pack missing – open the Languages tab" }
            guard let out = await translateBatch(items.map { $0.text }, source: src, target: target,
                                                 installed: availability == .installed),
                  out.count == items.count else { failed = true; continue }
            translatedAny = true
            for (k, it) in items.enumerated() {
                done[it.block][it.index] = out[k]
                cache["\(id)>\(targetCode)|\(it.text)"] = out[k]
            }
        }
        if cache.count > 600 { cache.removeAll() }

        guard translatedAny else {
            if failed && lastTranslationError == "None" { lastTranslationError = "No translated output returned" }
            status = failed ? "Translation failed – check diagnostics and language packs"
                            : "Text is already in the target language"
            return
        }
        var outBlocks: [String] = []
        for (bi, row) in done.enumerated() {
            var parts: [String] = []
            for (si, v) in row.enumerated() { parts.append(v ?? sentences[bi][si]) }
            outBlocks.append(parts.joined(separator: " "))
        }
        translateMs = Date().timeIntervalSince(t0) * 1000
        let finalOutput = outBlocks.joined(separator: "\n")
        lastOutputQuality = Self.outputQuality(source: blocks.joined(separator: " "), output: finalOutput)
        status = "\(srcLangs.keys.sorted().joined(separator: "+")) → \(targetCode) ✓"
        show(blocks.joined(separator: "\n"), finalOutput)
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
            guard let session = directSession else { return nil }
            let r = await runBatch(session, texts)
            if r == nil { directSession = nil }
            return r
        }
        return await translateLegacy(texts, source: source, target: target)
    }

    private func runBatch(_ session: TranslationSession, _ texts: [String]) async -> [String]? {
        let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        guard let res = try? await session.translations(from: reqs) else { return nil }
        var out = [String](repeating: "", count: texts.count)
        for r in res {
            if let id = r.clientIdentifier, let i = Int(id), i < out.count { out[i] = r.targetText }
        }
        return out
    }

    /// Conservative warning signal for clearly truncated or empty outputs.
    /// This is diagnostic only: translated word order legitimately differs by language.
    private static func outputQuality(source: String, output: String) -> String {
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let dst = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, !dst.isEmpty else { return "Suspicious: empty text" }
        let srcWords = src.split(whereSeparator: { $0.isWhitespace }).count
        let dstWords = dst.split(whereSeparator: { $0.isWhitespace }).count
        if dst.count < 3 { return "Suspicious: very short output" }
        if srcWords >= 6 && dstWords <= 2 { return "Review: output may be truncated" }
        if dst.count > max(1200, src.count * 8) { return "Review: output unusually long" }
        return "No obvious truncation detected"
    }

    private func show(_ text: String, _ result: String) {
        original = text
        translated = result
        showing = true
        if history.first?.original != text {
            history.insert(HistoryItem(original: text, translated: result), at: 0)
            if history.count > 100 { history.removeLast() }
            if speakEnabled { speak(result) }
        }
        renderedGrams = TextSim.grams(result).union(placeholderGrams)
        sourceGrams = TextSim.grams(text)
        pip.setSize(windowSize.size)
        pip.style = pipStyle
        pip.render(original: text, translated: result, showOriginal: showOriginal)
    }

    private func speak(_ s: String) {
        let voices = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "pt": "pt-BR", "en": "en-US", "es": "es-ES",
                      "fr": "fr-FR", "de": "de-DE", "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR", "ru": "ru-RU",
                      "ar": "ar-SA", "tr": "tr-TR", "hi": "hi-IN", "id": "id-ID", "nl": "nl-NL", "pl": "pl-PL",
                      "th": "th-TH", "vi": "vi-VN", "uk": "uk-UA"]
        speech.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: s)
        u.voice = AVSpeechSynthesisVoice(language: voices[targetCode] ?? targetCode)
        speech.speak(u)
    }

    // iOS 18 path (needs the hosted .translationTask view in RootView)
    private func translateLegacy(_ texts: [String], source: Locale.Language, target: Locale.Language) async -> [String]? {
        let requestID = UUID()
        return await withCheckedContinuation { (cont: CheckedContinuation<[String]?, Never>) in
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
                guard self.legacyRequestID == requestID else { return }
                self.finishLegacy(nil)
            }
        }
    }
    func runLegacy(_ session: TranslationSession) async {
        finishLegacy(await runBatch(session, pendingTexts))
    }
    private func finishLegacy(_ r: [String]?) {
        guard let continuation = legacyContinuation else { return }
        legacyContinuation = nil
        legacyRequestID = UUID()
        continuation.resume(returning: r)
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
