// Screen Translator – App – v0.8.0
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
        case .smart: return 0.04...0.92
        case .full: return 0...1
        case .bottom: return 0...0.33
        case .top: return 0.5...1
        case .middle: return 0.3...0.7
        case .custom:
            let a = (UserDefaults.standard.object(forKey: "customY0") as? Double) ?? 0
            let b = (UserDefaults.standard.object(forKey: "customY1") as? Double) ?? 0.5
            let lo = min(max(a, 0), 0.9)
            let hi = max(min(b, 1), lo + 0.1)
            return lo...hi
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
    var starred = false
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
    static let settingKeys = [
        "source", "target", "mode", "area", "customY0", "customY1", "speed", "stability", "minTextH", "ignoreList",
        "frameRot", "dropNoise", "boost", "skipUnchanged", "cleanOCR", "slang", "speakerDetect", "highlightNames",
        "langLock", "neverTranslate", "sourceFixes", "glossary", "winSize", "theme", "textSize", "pipFont",
        "showOriginal", "autoClear", "clearHold", "minDisplay", "autoOpenPiP", "haptics", "speak", "adaptive", "idleMinutes"
    ]

    // Settings that live in the engine
    @Published var sourceCode: String {
        didSet { UserDefaults.standard.set(sourceCode, forKey: "source"); lastHandled = ""; lockedLang = nil; syncConfig() }
    }
    @Published var targetCode: String {
        didSet {
            UserDefaults.standard.set(targetCode, forKey: "target"); lastHandled = ""; directSession = nil
            Task { await refreshStatus() }
        }
    }
    @Published var paused = false { didSet { syncConfig() } }
    @Published var frozen = false
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
    @Published var history: [HistoryItem] = []
    @Published var profileNames: [String] = []
    // Translation session plumbing
    @Published var legacyConfig: TranslationSession.Configuration?
    @Published var downloadConfig: TranslationSession.Configuration?

    let pip = PiPRenderer()
    let server = LoopbackServer()
    let diag = Diagnostics()

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
        profileNames = loadProfiles().keys.sorted()
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
                           maxEdge: maxEdge, interval: interval, paused: paused,
                           stability: int("stability", 2), rot: effectiveRot, rev: rotRev,
                           boost: int("boost", 1), skipUnchanged: flag("skipUnchanged", true)))
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

    /// One-tap bundles of settings for the common situations.
    func applyPreset(_ name: String) {
        switch name {
        case "movie": ud.set("movie", forKey: "mode"); ud.set("smart", forKey: "area"); ud.set("balanced", forKey: "speed")
        case "game": ud.set("game", forKey: "mode"); ud.set("full", forKey: "area"); ud.set("fast", forKey: "speed")
        default: ud.set("comic", forKey: "mode"); ud.set("full", forKey: "area"); ud.set("sharp", forKey: "speed")
        }
        lastHandled = ""
        syncConfig()
        status = "Preset applied: \(name)"
        diag.log("Preset: \(name)")
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
            diag.log("Capture connected (extension v\(p.version))")
            lastTextDate = now
            syncConfig()
            // Capture just started: make sure the floating window is up too.
            if flag("autoOpenPiP", true), !pip.isActive, UIApplication.shared.applicationState == .active { startPiP() }
        }
        if p.kind == "ping" { syncConfig(); return }          // keeps the extension's settings fresh
        if paused { return }
        if p.kind == "clear" { handleClear(); return }
        guard p.kind == "ocr" else { return }
        ocrCount += 1
        lastRaw = String(p.lines.map(\.t).joined(separator: " ").prefix(160))

        // Is text arriving upside down? Votes only count packets made with the current rotation.
        if p.rev == nil || p.rev == rotRev { updateOrderVote(p.lines) }

        let range = area.range(mode: mode)
        let minH = num("minTextH", 0)
        let ignore = list("ignoreList", lower: true)
        var cand: [OCRLine] = []
        for l in p.lines {
            diag.s.linesIn += 1
            if !range.contains(l.y) { diag.s.dropArea += 1; continue }
            if l.h < minH { diag.s.dropSmall += 1; continue }
            if ignore.contains(where: { l.t.lowercased().contains($0) }) { diag.s.dropIgnore += 1; continue }
            cand.append(l)
        }
        let n1 = cand.count
        cand = removeOwnOutput(cand)
        diag.s.dropSelf += n1 - cand.count
        let n2 = cand.count
        cand = cand.filter { !isTargetLanguage($0.t) }
        diag.s.dropTarget += n2 - cand.count

        let allBlocks = makeBlocks(cand)
        diag.s.blocksIn += allBlocks.count
        let blocks = selectBlocks(allBlocks)
        diag.s.blocksKept += blocks.count
        var texts: [String] = []
        for b in blocks {
            let t = blockText(b)
            if TextSim.norm(t).count < 2 { continue }
            if flag("dropNoise", true) && TextIntel.isNoise(t) { diag.s.dropNoise += 1; continue }
            if !plausiblySource(t) { diag.s.dropLanguage += 1; continue }
            texts.append(t)
        }
        texts = dedupe(texts)
        guard !texts.isEmpty else { handleClear(); return }
        clearTask?.cancel()
        clearTask = nil
        queuedTs = p.ts ?? now.timeIntervalSince1970
        enqueue(texts.map { String($0.prefix(400)) })
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
        let byY = lines.sorted { $0.y > $1.y }
        var rows: [[OCRLine]] = []
        for l in byY {
            if let first = rows.last?.first, abs(first.y - l.y) < 0.4 * min(first.h, l.h) {
                rows[rows.count - 1].append(l)
            } else {
                rows.append([l])
            }
        }
        return rows.flatMap { $0.sorted { $0.x < $1.x } }
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
                let stacked = gap > 0.2 * lineH && gap < 2.2 * lineH && overlap > 0.25 * min(lw, w2)
                let sameRow = abs(gap) <= 0.35 * lineH && xGap < 0.06
                if sizeRatio > 0.5 && (stacked || sameRow) {
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
            kept = blocks.filter { blockHeight($0) >= maxH * 0.7 }
            if kept.count > 2 { kept = Array(kept.sorted { blockWeight($0) > blockWeight($1) }.prefix(2)) }
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
        guard joined != lastHandled else { return }
        if TextSim.similar(joined, lastHandled, 0.92) { lastHandled = joined; return }   // tiny OCR jitter
        lastHandled = joined
        queued = blocks
        if !busy { Task { await drain() } }
    }

    private func handleClear() {
        guard flag("autoClear", true), showing, clearTask == nil else { return }
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
        guard showing else { return }
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
        while queued != nil {
            let wait = num("minDisplay", 0) - Date().timeIntervalSince(lastShowDate)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let b = queued else { break }
            queued = nil
            currentTs = queuedTs
            await process(b)
        }
    }

    // MARK: Translation
    private func detectSource(_ text: String) -> Locale.Language? {
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
        if useLock {
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
        if sourceCode != "auto", let s = langStatus[sourceCode] { return s }
        return await LanguageAvailability().status(from: src, to: target)
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

    private func process(_ blocks: [String]) async {
        let t0 = Date()
        let target = Locale.Language(identifier: targetCode)
        let cleanOn = flag("cleanOCR", true), slangOn = flag("slang", true), speakerOn = flag("speakerDetect", true)
        let fixes = pairs("sourceFixes")
        let never = list("neverTranslate", lower: false)

        var units: [[TUnit]] = []
        var pending: [String: [(b: Int, u: Int, s: Int, text: String)]] = [:]
        var srcLangs: [String: Locale.Language] = [:]
        var translatedAny = false

        for (bi, raw) in blocks.enumerated() {
            var text = cleanOn ? TextIntel.cleanOCR(raw) : raw
            for (from, to) in fixes { text = text.replacingOccurrences(of: from, with: to, options: [.caseInsensitive]) }
            guard let src = detectSource(text), src.languageCode != target.languageCode else {
                units.append([TUnit(label: nil, sentences: [text], out: [text], tokens: [])])
                continue
            }
            let id = src.minimalIdentifier
            srcLangs[id] = src
            if slangOn { text = TextIntel.expandSlang(text, lang: src.languageCode?.identifier ?? id) }
            let parts = speakerOn ? TextIntel.splitDialogue(text) : [(label: String?.none, text: text)]
            var row: [TUnit] = []
            for (ui, d) in parts.enumerated() {
                if let name = d.label { diag.learn(name) }
                let prot = TextIntel.protect(d.text, words: never)
                let sentences = splitSentences(prot.text)
                diag.s.sentences += sentences.count
                var outs: [String?] = []
                for (si, s) in sentences.enumerated() {
                    if let hit = cache["\(id)>\(targetCode)|\(s)"] {
                        outs.append(hit); translatedAny = true; diag.s.cacheHits += 1
                    } else {
                        outs.append(nil); diag.s.cacheMisses += 1
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
            let availability = await pairStatus(src, target)
            if availability == .unsupported { status = "\(id) → \(targetCode) isn't supported"; failed = true; continue }
            if availability == .supported { status = "Language pack missing – open the Languages tab" }
            diag.s.batches += 1
            let installed = availability == .installed
            var results = await translateBatch(items.map { $0.text }, source: src, target: target, installed: installed)
            if results == nil || results?.count != items.count {
                // One bad sentence shouldn't lose the whole batch: retry them one by one.
                diag.log("Batch failed – retrying sentence by sentence")
                var singles: [String?] = []
                for it in items {
                    if let r = await translateBatch([it.text], source: src, target: target, installed: installed), r.count == 1 {
                        singles.append(r[0])
                    } else {
                        singles.append(nil); diag.s.failures += 1
                    }
                }
                results = nil
                for (k, it) in items.enumerated() {
                    if let v = singles[k] {
                        units[it.b][it.u].out[it.s] = v
                        cache["\(id)>\(targetCode)|\(it.text)"] = v
                        translatedAny = true
                    } else { failed = true }
                }
            }
            if let r = results {
                translatedAny = true
                for (k, it) in items.enumerated() {
                    units[it.b][it.u].out[it.s] = r[k]
                    cache["\(id)>\(targetCode)|\(it.text)"] = r[k]
                }
            }
        }
        if cache.count > 600 { cache.removeAll() }

        guard translatedAny else {
            status = failed ? "Translation failed – download the language packs (Languages tab)"
                            : "Text is already in the target language"
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
        Diagnostics.push(&diag.translateSeries, translateMs)
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
        var out = [String](repeating: "", count: texts.count)
        for r in res {
            if let id = r.clientIdentifier, let i = Int(id), i < out.count { out[i] = r.targetText }
        }
        return out
    }

    private func show(_ text: String, _ result: String) {
        clearTask?.cancel()
        clearTask = nil
        guard !frozen else { return }
        original = text
        translated = result
        showing = true
        lastTextDate = Date()
        lastShowDate = Date()
        if currentTs > 0 { Diagnostics.push(&diag.latencySeries, (Date().timeIntervalSince1970 - currentTs) * 1000) }
        if history.first?.original != text {
            history.insert(HistoryItem(original: text, translated: result), at: 0)
            if history.count > 200 { history.removeLast() }
            if flag("speak", false) { speak(result) }
            if flag("haptics", false) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
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

    /// Translate the current text again from scratch (ignores the cache).
    func retranslate() {
        guard !original.isEmpty else { return }
        cache.removeAll()
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
            legacyContinuation = cont
            pendingTexts = texts
            if var c = legacyConfig, c.source == source, c.target == target {
                c.invalidate(); legacyConfig = c
            } else {
                legacyConfig = .init(source: source, target: target)
            }
            Task { try? await Task.sleep(for: .seconds(10)); finishLegacy(nil) }
        }
    }
    func runLegacy(_ session: TranslationSession) async {
        finishLegacy(await runBatch(session, pendingTexts))
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

    // MARK: Profiles + backup
    private func snapshot() -> [String: Any] {
        var snap: [String: Any] = [:]
        for k in Self.settingKeys { if let v = ud.object(forKey: k) { snap[k] = v } }
        return snap
    }
    private func loadProfiles() -> [String: [String: Any]] {
        guard let d = ud.data(forKey: "profiles"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]] else { return [:] }
        return o
    }
    func saveProfile(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        var all = loadProfiles()
        all[n] = snapshot()
        if let d = try? JSONSerialization.data(withJSONObject: all) { ud.set(d, forKey: "profiles") }
        profileNames = all.keys.sorted()
        status = "Profile saved: \(n)"
        diag.log("Profile saved: \(n)")
    }
    func applyProfile(_ name: String) {
        guard let snap = loadProfiles()[name] else { return }
        for k in Self.settingKeys { if let v = snap[k] { ud.set(v, forKey: k) } else { ud.removeObject(forKey: k) } }
        reloadSettings()
        status = "Profile applied: \(name)"
        diag.log("Profile applied: \(name)")
    }
    func deleteProfile(_ name: String) {
        var all = loadProfiles()
        all[name] = nil
        if let d = try? JSONSerialization.data(withJSONObject: all) { ud.set(d, forKey: "profiles") }
        profileNames = all.keys.sorted()
    }
    func exportSettings() -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: snapshot(), options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
    func importSettings(_ text: String) -> Bool {
        guard let d = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        for k in Self.settingKeys { if let v = o[k] { ud.set(v, forKey: k) } }
        reloadSettings()
        return true
    }
    func resetAllSettings() {
        for k in Self.settingKeys { ud.removeObject(forKey: k) }
        reloadSettings()
    }
    /// Re-reads everything after settings were changed in bulk.
    func reloadSettings() {
        sourceCode = ud.string(forKey: "source") ?? "auto"
        targetCode = ud.string(forKey: "target") ?? "en"
        lastHandled = ""
        rotationSettingChanged()
        applyStyle()
        applyWindowSize()
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
