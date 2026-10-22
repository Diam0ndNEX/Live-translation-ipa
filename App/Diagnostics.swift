// Screen Translator – App – v0.8.0
import SwiftUI
import os

struct LogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
}

struct Stats {
    var packets = 0, ocrPackets = 0, clearPackets = 0
    var frames = 0, passes = 0, skippedFrames = 0
    var fps = 0.0
    var bufferSize = "–", cropSize = "–", orientation = "–"
    var extFreeMB = 0.0, minExtFreeMB = 9999.0
    var linesIn = 0, dropArea = 0, dropSmall = 0, dropIgnore = 0, dropSelf = 0, dropTarget = 0, dropNoise = 0, dropLanguage = 0
    var blocksIn = 0, blocksKept = 0
    var sentences = 0, cacheHits = 0, cacheMisses = 0, batches = 0, failures = 0, translations = 0, chars = 0
    var sessionKind = "–"
    var detected = "–"
    var lockedLang = "–"
    var orderVote = 0.0
    var rotation = 0
    var calibrated = false
    var pipRegion = "–"
}

@MainActor
final class Diagnostics: ObservableObject {
    @Published var s = Stats()
    @Published var ocrSeries: [Double] = []
    @Published var translateSeries: [Double] = []
    @Published var latencySeries: [Double] = []
    @Published var transportSeries: [Double] = []
    @Published var names: [String] = []
    @Published var events: [LogEntry] = []
    let started = Date()
    private var lastFrames = 0
    private var lastFrameTime = Date()

    func log(_ t: String) {
        events.insert(LogEntry(time: Date(), text: t), at: 0)
        if events.count > 150 { events.removeLast() }
    }

    static func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > 60 { a.removeFirst() }
    }

    func learn(_ name: String) {
        guard !names.contains(name) else { return }
        names.append(name)
        names.sort()
        if names.count > 60 { names.removeLast() }
    }

    func reset() {
        s = Stats(); ocrSeries = []; translateSeries = []; latencySeries = []; transportSeries = []
        names = []; events = []
    }

    static func orientationName(_ v: Int) -> String {
        let n = ["up", "up mirrored", "down", "down mirrored", "left mirrored", "right", "right mirrored", "left"]
        return (1...8).contains(v) ? "\(n[v - 1]) (\(v))" : "\(v)"
    }

    func onPacket(_ p: Packet, transport: Double?) {
        s.packets += 1
        if p.kind == "ocr" { s.ocrPackets += 1 } else if p.kind == "clear" { s.clearPackets += 1 }
        let now = Date()
        let dt = now.timeIntervalSince(lastFrameTime)
        if p.frames < lastFrames {
            lastFrames = p.frames; lastFrameTime = now
        } else if dt >= 1 {
            s.fps = Double(p.frames - lastFrames) / dt
            lastFrames = p.frames; lastFrameTime = now
        }
        s.frames = p.frames
        if let m = p.memFreeMB { s.extFreeMB = m; if m > 0 { s.minExtFreeMB = min(s.minExtFreeMB, m) } }
        if let o = p.ocrMs, o > 0, p.kind != "ping" { Diagnostics.push(&ocrSeries, o) }
        if let v = p.passes { s.passes = v }
        if let v = p.skipped { s.skippedFrames = v }
        if let w = p.bufW, let h = p.bufH { s.bufferSize = "\(w)×\(h)" }
        if let w = p.cropW, let h = p.cropH { s.cropSize = "\(w)×\(h)" }
        if let o = p.orient { s.orientation = Diagnostics.orientationName(o) }
        if let t = transport, p.kind != "ping" { Diagnostics.push(&transportSeries, t) }
    }

    static func summary(_ a: [Double]) -> String {
        guard let last = a.last else { return "–" }
        let avg = a.reduce(0, +) / Double(a.count)
        return "\(Int(last)) ms  (avg \(Int(avg)), max \(Int(a.max() ?? 0)))"
    }

    func report(engine: TranslatorEngine) -> String {
        var l: [String] = []
        l.append("Screen Translator \(AppVersion.full) – diagnostics")
        l.append("Capture: \(engine.captureAlive ? "connected" : "not connected"), extension v\(engine.extensionVersion)")
        l.append("Frames \(s.frames) (\(Int(s.fps)) fps), OCR passes \(s.passes), skipped \(s.skippedFrames)")
        l.append("Buffer \(s.bufferSize), crop \(s.cropSize), orientation \(s.orientation), rotation \(s.rotation * 90)°")
        l.append("OCR \(Diagnostics.summary(ocrSeries)); translate \(Diagnostics.summary(translateSeries))")
        l.append("Latency \(Diagnostics.summary(latencySeries)); transport \(Diagnostics.summary(transportSeries))")
        l.append("Extension memory free \(Int(s.extFreeMB)) MB (lowest \(Int(s.minExtFreeMB)) MB)")
        l.append("Lines in \(s.linesIn); dropped area \(s.dropArea), small \(s.dropSmall), ignore \(s.dropIgnore), own output \(s.dropSelf), target language \(s.dropTarget), noise \(s.dropNoise), other language \(s.dropLanguage)")
        l.append("Blocks \(s.blocksIn) → kept \(s.blocksKept); reading-order vote \(String(format: "%.1f", s.orderVote)), calibrated \(s.calibrated)")
        l.append("Translations \(s.translations), sentences \(s.sentences), cache \(s.cacheHits)/\(s.cacheHits + s.cacheMisses), failures \(s.failures), session \(s.sessionKind)")
        l.append("Language \(s.detected), locked \(s.lockedLang)")
        l.append("Speakers: \(names.joined(separator: ", "))")
        l.append("")
        l.append("Recent events:")
        for e in events.prefix(40) { l.append("\(e.time.formatted(date: .omitted, time: .standard)) \(e.text)") }
        return l.joined(separator: "\n")
    }
}

// MARK: - Views
struct Sparkline: View {
    let values: [Double]
    var color: Color = .cyan
    var body: some View {
        GeometryReader { geo in
            Path { p in
                guard values.count > 1, let mx = values.max(), mx > 0 else { return }
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = geo.size.height * (1 - CGFloat(v / mx))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, lineWidth: 1.5)
        }
        .frame(height: 34)
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var engine: TranslatorEngine
    var body: some View { DiagnosticsBody(diag: engine.diag) }
}

private struct DiagnosticsBody: View {
    @EnvironmentObject var engine: TranslatorEngine
    @ObservedObject var diag: Diagnostics

    private func row(_ k: String, _ v: String) -> some View { LabeledContent(k, value: v) }
    private func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "–" : "\(Int(Double(n) / Double(d) * 100))%" }

    private var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot (throttling)"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
    private var battery: String {
        let b = UIDevice.current.batteryLevel
        return b < 0 ? "–" : "\(Int(b * 100))%"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    row("Capture", engine.captureAlive ? "Connected" : "Not connected")
                    row("Floating window", engine.pipActive ? "Open" : "Closed")
                    row("Translating", engine.paused ? "Paused" : (engine.frozen ? "Frozen" : "Live"))
                    LabeledContent("Session started") { Text(diag.started, style: .relative) }
                    Text(engine.status).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Capture extension") {
                    row("Version", engine.extensionVersion)
                    row("Frames received", "\(diag.s.frames)  (\(Int(diag.s.fps)) fps)")
                    row("OCR passes", "\(diag.s.passes)")
                    row("Unchanged frames skipped", "\(diag.s.skippedFrames)")
                    row("Frame size", diag.s.bufferSize)
                    row("Orientation from iOS", diag.s.orientation)
                    row("Read area size", diag.s.cropSize)
                    row("Memory free now", "\(Int(diag.s.extFreeMB)) MB")
                    row("Memory free (lowest)", diag.s.minExtFreeMB > 9000 ? "–" : "\(Int(diag.s.minExtFreeMB)) MB")
                    row("Packets (text / clear / total)", "\(diag.s.ocrPackets) / \(diag.s.clearPackets) / \(diag.s.packets)")
                }
                Section("Speed") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reading text: \(Diagnostics.summary(diag.ocrSeries))").font(.footnote)
                        Sparkline(values: diag.ocrSeries, color: .green)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Translating: \(Diagnostics.summary(diag.translateSeries))").font(.footnote)
                        Sparkline(values: diag.translateSeries, color: .cyan)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Read → shown on screen: \(Diagnostics.summary(diag.latencySeries))").font(.footnote)
                        Sparkline(values: diag.latencySeries, color: .orange)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Extension → app transfer: \(Diagnostics.summary(diag.transportSeries))").font(.footnote)
                        Sparkline(values: diag.transportSeries, color: .purple)
                    }
                }
                Section("Reading order") {
                    row("Frame rotation applied", "\(diag.s.rotation * 90)°")
                    row("Order confidence", String(format: "%.1f", diag.s.orderVote))
                    row("Calibrated", diag.s.calibrated ? "Yes" : "Not yet")
                }
                Section("What got filtered") {
                    row("Lines read", "\(diag.s.linesIn)")
                    row("Outside OCR area", "\(diag.s.dropArea)")
                    row("Too small", "\(diag.s.dropSmall)")
                    row("Ignore list", "\(diag.s.dropIgnore)")
                    row("Own floating window", "\(diag.s.dropSelf)")
                    row("Already target language", "\(diag.s.dropTarget)")
                    row("Numbers / noise", "\(diag.s.dropNoise)")
                    row("Other language", "\(diag.s.dropLanguage)")
                    row("Text blocks (found / kept)", "\(diag.s.blocksIn) / \(diag.s.blocksKept)")
                    row("Floating window position", diag.s.pipRegion)
                }
                Section("Translation") {
                    row("Engine", diag.s.sessionKind)
                    row("Detected language", diag.s.detected)
                    row("Locked language", diag.s.lockedLang)
                    row("Translations", "\(diag.s.translations)")
                    row("Sentences", "\(diag.s.sentences)")
                    row("Characters", "\(diag.s.chars)")
                    row("Cache hit rate", pct(diag.s.cacheHits, diag.s.cacheHits + diag.s.cacheMisses))
                    row("Batches / failures", "\(diag.s.batches) / \(diag.s.failures)")
                }
                Section("Speakers learned") {
                    if diag.names.isEmpty {
                        Text("Names appear here when text looks like \"Name: line\".").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text(diag.names.joined(separator: ", ")).font(.footnote)
                    }
                }
                Section("Device") {
                    row("Temperature", thermal)
                    row("Low Power Mode", ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
                    row("Battery", battery)
                    row("App memory free", "\(Int(Double(os_proc_available_memory()) / 1_048_576)) MB")
                }
                Section("Event log") {
                    if diag.events.isEmpty { Text("Nothing yet.").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(diag.events.prefix(40)) { e in
                        HStack(alignment: .top) {
                            Text(e.time, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            Text(e.text).font(.caption)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Diagnostics")
            .onAppear { UIDevice.current.isBatteryMonitoringEnabled = true }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ShareLink(item: diag.report(engine: engine)) }
                ToolbarItem(placement: .topBarTrailing) { Button("Reset") { diag.reset() } }
            }
        }
    }
}
