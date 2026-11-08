// ScreenLingo – App – Diagnostics (2.1.0, spec §13.5.4: one answer, then lenses as pushed pages)
import SwiftUI
import Charts

// MARK: - Snapshots
// The dashboard is live by design, but it never observes the whole engine or the whole recorder.
// Each section reads a small Equatable snapshot that refreshes at most a few times a second and only when it changes.

/// Slow-changing engine values (system, capture state, language pack).
struct DashboardFacts: Equatable {
    var system: TranslationSystem
    var pending: TranslationSystem
    var availability: String
    var captureAlive: Bool
    var paused: Bool
    var pipActive: Bool
    var memoryCount: Int
    var unconsumedSpeculation: String
    var sourceCode: String
    var sourceReady: Bool
    var extensionVersion: String
    var capture: CaptureReadiness.State
    var targetCode: String
    @MainActor static func read(_ e: TranslatorEngine) -> DashboardFacts {
        DashboardFacts(system: e.activeTranslationSystem, pending: e.pendingTranslationSystem, availability: e.modeAvailability,
                       captureAlive: e.captureAlive, paused: e.paused, pipActive: e.pipActive, memoryCount: e.memoryCount,
                       unconsumedSpeculation: "\(e.unconsumedSpeculation)", sourceCode: e.sourceCode,
                       sourceReady: e.langStatus[e.sourceCode] == .installed, extensionVersion: e.extensionVersion,
                       capture: e.captureStatus, targetCode: e.targetCode)
    }
    var phase: SessionPhase {
        SessionPhase.derive(capture: capture, alive: captureAlive, paused: paused, pipActive: pipActive,
                            packReady: sourceCode == "auto" || sourceReady)
    }
}

/// Fast-changing engine values. Only the overview answer and the "Right now" section read it.
struct PulseFacts: Equatable {
    var ocrMs: Double
    var translateMs: Double
    var totalMs: Double
    var lastRaw: String
    var translated: String
    var activity: String
    var status: String
    @MainActor static func read(_ e: TranslatorEngine) -> PulseFacts {
        PulseFacts(ocrMs: e.ocrMs, translateMs: e.translateMs, totalMs: e.latency.last.total, lastRaw: e.lastRaw,
                   translated: e.translated, activity: e.translationActivity.title, status: e.status)
    }
}

struct SeriesMark: Equatable {
    var count: Int
    var last: Date?
    init(_ samples: [Sample]) { count = samples.count; last = samples.last?.t }
}

/// What changed in the recorder. Arrays are summarised by length and newest timestamp, so a full ring still registers.
struct DiagTick: Equatable {
    var stats: Stats
    var series: [SeriesMark]
    var events: Int
    var lastEvent: Date?
    var spans: Int
    var traces: Int
    var structured: Int
    var pipeline: Int
    var names: Int
    var memoryEntries: Int
    var pendingWrites: Int
    var archive: String
    var exporting: Bool
    var recording: Bool
    var runs: Int
    @MainActor static func read(_ d: Diagnostics) -> DiagTick {
        DiagTick(stats: d.s,
                 series: [d.ocr, d.translate, d.latency, d.transport, d.fps, d.lineCounts, d.extMem, d.appMem, d.thermal, d.battery, d.cacheRate].map(SeriesMark.init),
                 events: d.events.count, lastEvent: d.events.last?.time, spans: d.spans.count, traces: d.subtitleTraces.count,
                 structured: d.structuredEvents.count, pipeline: d.pipeline.count, names: d.names.count,
                 memoryEntries: d.memoryHealth.totalEntries, pendingWrites: d.memoryHealth.pendingWrites,
                 archive: d.archiveStatus, exporting: d.exportInProgress, recording: d.activeRun != nil, runs: d.testRuns.count)
    }
}

// MARK: - Small helpers
private func fmt(_ v: Double) -> String { v >= 100 ? "\(Int(v))" : String(format: "%.1f", v) }

private func level(_ v: Double, _ n: Int, _ warn: Double, _ bad: Double) -> Color {
    n == 0 ? Color.primary : (v > bad ? Color.red : (v > warn ? Color.orange : Color.green))
}

private struct BarRow: Identifiable {
    let name: String
    let value: Int
    var id: String { name }
}

private struct DonutPart: Identifiable {
    let name: String
    let value: Int
    let color: Color
    var id: String { name }
}

private struct Bucket: Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
}

// MARK: - Building blocks
/// One labelled value per row (replaces the 2.0.0 tile grid).
private struct StatTile: View {
    let title: String
    let value: String
    var tint: Color = Color.primary
    var icon: String? = nil
    var body: some View {
        HStack(spacing: KitSpace.row) {
            if let icon { Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24).accessibilityHidden(true) }
            Text(title).font(.body)
            Spacer(minLength: KitSpace.tight)
            Text(value).font(.body.monospacedDigit()).foregroundStyle(tint == Color.primary ? Color.secondary : tint)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

private struct LineCard: View {
    let title: String
    let samples: [Sample]
    var color: Color = Color.cyan
    var unit = "ms"
    var rule: Double? = nil
    var markers: [TimelineEvent] = []

    private func stat(_ n: String, _ v: Double) -> some View {
        VStack(spacing: 1) {
            Text(fmt(v)).font(.caption.weight(.semibold).monospacedDigit())
            Text(n).font(.caption).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        let sm = Diagnostics.summarize(samples)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if sm.n > 0 {
                    Text("\(fmt(sm.last)) \(unit)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(color)
                }
            }
            if samples.count < 2 {
                Text(samples.isEmpty
                     ? "No measurements in this range. Detailed collection records measured work, not synthetic values."
                     : "One measurement: \(fmt(sm.last)) \(unit). Another sample is needed for a trend.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                Chart {
                    ForEach(samples) { s in
                        AreaMark(x: .value("Time", s.t), y: .value(unit, s.v))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", s.t), y: .value(unit, s.v))
                            .foregroundStyle(color)
                            .interpolationMethod(.monotone)
                    }
                    if let r = rule {
                        RuleMark(y: .value("Limit", r))
                            .foregroundStyle(Color.red.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    ForEach(markers) { e in
                        RuleMark(x: .value("Event", e.time))
                            .foregroundStyle(e.kind.color.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.minute().second())
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 110)
                HStack {
                    stat("min", sm.min)
                    Spacer()
                    stat("avg", sm.avg)
                    Spacer()
                    stat("p95", sm.p95)
                    Spacer()
                    stat("max", sm.max)
                }
            }
        }
        .padding(.vertical, KitSpace.tight)
    }
}

private struct HistogramCard: View {
    let title: String
    let values: [Double]
    var color: Color = Color.cyan

    private struct Bin: Identifiable {
        let label: String
        let count: Int
        let order: Int
        var id: Int { order }
    }

    private var bins: [Bin] {
        guard values.count >= 3, let mx = values.max(), mx > 0 else { return [] }
        let n = 8
        let w = mx / Double(n)
        var counts = [Int](repeating: 0, count: n)
        for v in values { counts[Swift.min(n - 1, Int(v / w))] += 1 }
        return (0..<n).map { Bin(label: "\(Int(Double($0) * w))", count: counts[$0], order: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if bins.isEmpty {
                Text(values.isEmpty ? "No timing measurements in this range." :
                     "\(values.count) timing samples; at least three are needed for a histogram.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                Chart(bins) { b in
                    BarMark(x: .value("Range (ms)", b.label), y: .value("Count", b.count))
                        .foregroundStyle(color.gradient)
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 120)
            }
        }
        .padding(.vertical, KitSpace.tight)
    }
}

private struct DonutCard: View {
    let title: String
    let parts: [DonutPart]
    var body: some View {
        let shown = parts.filter { $0.value > 0 }
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if shown.isEmpty {
                Text("No data yet.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart(shown) { p in
                    SectorMark(angle: .value("Count", p.value), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(by: .value("Part", p.name))
                }
                .chartForegroundStyleScale(domain: shown.map { $0.name }, range: shown.map { $0.color })
                .chartLegend(position: .bottom, alignment: .center, spacing: 8)
                .frame(height: 210)
            }
        }
        .padding(.vertical, KitSpace.tight)
    }
}

private struct BarListCard: View {
    let title: String
    let rows: [BarRow]
    var color: Color = Color.blue
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if rows.allSatisfy({ $0.value == 0 }) {
                Text("No data yet.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Chart(rows) { r in
                    BarMark(x: .value("Count", r.value), y: .value("Item", r.name))
                        .foregroundStyle(color.gradient)
                        .annotation(position: .trailing) {
                            Text("\(r.value)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                }
                .chartYScale(domain: rows.map { $0.name })
                .frame(height: CGFloat(rows.count) * 34 + 20)
            }
        }
        .padding(.vertical, KitSpace.tight)
    }
}

private struct MultiSpeedChart: View {
    let ocr: [Sample]
    let translate: [Sample]
    let delay: [Sample]
    var body: some View {
        if ocr.count + translate.count + delay.count < 3 {
            Text("Not enough measured timing samples. Memory-only translations do not have model-duration samples.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            Chart {
                ForEach(ocr) { s in
                    LineMark(x: .value("Time", s.t), y: .value("ms", s.v), series: .value("Step", "Reading"))
                        .foregroundStyle(by: .value("Step", "Reading"))
                        .interpolationMethod(.monotone)
                }
                ForEach(translate) { s in
                    LineMark(x: .value("Time", s.t), y: .value("ms", s.v), series: .value("Step", "Translating"))
                        .foregroundStyle(by: .value("Step", "Translating"))
                        .interpolationMethod(.monotone)
                }
                ForEach(delay) { s in
                    LineMark(x: .value("Time", s.t), y: .value("ms", s.v), series: .value("Step", "Total delay"))
                        .foregroundStyle(by: .value("Step", "Total delay"))
                        .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["Reading": Color.green, "Translating": Color.cyan, "Total delay": Color.orange])
            .chartLegend(position: .bottom)
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.minute().second())
                }
            }
            .frame(height: 160)
        }
    }
}

// MARK: - Pages
enum DiagPage: String, CaseIterable, Identifiable {
    case overview, speed, timeline, pipeline, language, device, memory, sessions, log
    var id: String { rawValue }
    var title: String {
        switch self { case .overview: "Right now"; case .sessions: "Test runs"; case .log: "Event log"; default: rawValue.capitalized }
    }
    /// The lens list on the overview, in order (§13.5.4).
    static let lenses: [DiagPage] = [.speed, .timeline, .pipeline, .language, .device, .memory, .sessions, .log]
    /// Lenses with time charts get their own range control.
    var ranged: Bool { self == .speed || self == .timeline || self == .device }
    /// Lenses that only fill with Detailed collection.
    var needsDetails: Bool { self != .memory && self != .sessions && self != .language }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .speed: "speedometer"
        case .timeline: "timeline.selection"
        case .pipeline: "arrow.triangle.branch"
        case .language: "globe"
        case .device: "iphone"
        case .memory: "internaldrive"
        case .sessions: "clock.arrow.circlepath"
        case .log: "list.bullet.rectangle"
        }
    }
}

enum DiagRange: Int, CaseIterable, Identifiable {
    case oneMin = 60, fiveMin = 300, fifteenMin = 900, session = 0
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .oneMin: "1 min"
        case .fiveMin: "5 min"
        case .fifteenMin: "15 min"
        case .session: "Session"
        }
    }
}

// MARK: - Screen
struct DiagnosticsView: View {
    @EngineHandle private var engine
    var body: some View { DiagnosticsBody(diag: engine.diag) }
}

/// What is being read and shown right now. The only other section that reads the fast-changing engine values.
private struct LiveFeedSection: View {
    @EngineFacts(PulseFacts.read) private var pulse
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Right now").font(.headline)
            ListRow(title: "Reads", subtitle: pulse.lastRaw.isEmpty ? "Nothing yet" : pulse.lastRaw, symbol: "text.viewfinder") { EmptyView() }
            Divider()
            ListRow(title: "Shows", subtitle: pulse.translated.isEmpty ? "Nothing yet" : pulse.translated, symbol: "character.bubble") { EmptyView() }
            Hint("Translator: " + pulse.activity)
            Hint(pulse.status)
        }
        .padding(.vertical, KitSpace.tight)
    }
}

/// The overview's one answer: typical delay with a 60-sample sparkline and one row of secondary values.
/// With no evidence it says "No session yet"; no score or red colour without data (R7).
private struct OverviewAnswer: View {
    @EngineFacts(PulseFacts.read) private var pulse
    let diag: Diagnostics
    let captureAlive: Bool
    var body: some View {
        let delay = Diagnostics.summarize(diag.latency)
        let typical: Double? = delay.n > 0 ? delay.p50 : (pulse.totalMs > 0 ? pulse.totalMs : nil)
        var secondary: [String] = []
        if delay.n > 0 { secondary.append("P95 \(Int(delay.p95)) ms") }
        if typical != nil {
            secondary.append("\(diag.s.translations) translations")
            secondary.append("\(diag.s.failures) problem\(diag.s.failures == 1 ? "" : "s")")
        }
        return StatLine(value: typical.map { "\(Int($0)) ms" },
                        caption: "Typical delay · screen text to floating window",
                        samples: Array(diag.latency.suffix(60)).map(\.v),
                        secondary: secondary,
                        emptyCaption: captureAlive ? "Measuring: the first captions set this number" : "No session yet")
            .padding(.vertical, KitSpace.unit)
    }
}

private struct DiagnosticsBody: View {
    @EngineHandle private var engine
    @EngineFacts(DashboardFacts.read) private var facts
    @EnvironmentObject private var router: AppRouter
    let diag: Diagnostics
    @StateObject private var tick: ObjectSlice<Diagnostics, DiagTick>
    @AppStorage("diagnosticsEnabled") private var collectionEnabled = true
    @AppStorage("detailedCollection") private var collectDetails = false
    @AppStorage("diagRange") private var rangeRaw = DiagRange.fiveMin.rawValue
    @State private var kinds: Set<EventKind> = []
    @State private var query = ""
    @State private var confirmReset = false
    @State private var showSimulator = false
    @State private var confirmDeleteSessions = false
    @State private var bucketSeconds = 1
    @State private var showTestReport = false

    init(diag: Diagnostics) {
        self.diag = diag
        _tick = StateObject(wrappedValue: ObjectSlice(diag, milliseconds: 500) { DiagTick.read($0) })
    }

    private var range: DiagRange { DiagRange(rawValue: rangeRaw) ?? .fiveMin }
    private var rangeStart: Date {
        range == .session ? diag.started : Date().addingTimeInterval(-Double(range.rawValue))
    }
    private func slice(_ a: [Sample]) -> [Sample] { a.filter { $0.t >= rangeStart } }

    private func elapsed(_ d: Date) -> String {
        let s = Int(d.timeIntervalSince(diag.started))
        return String(format: "+%d:%02d", s / 60, s % 60)
    }

    // MARK: Body
    /// Opens on one answer: what state the session is in and the typical delay, then only what needs attention,
    /// then the lenses. Each lens is its own pushed page with its own title; nothing here stays above it (R6).
    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhaseHeader(phase: facts.phase, mode: facts.system.shortName)
                    if collectionEnabled {
                        OverviewAnswer(diag: diag, captureAlive: facts.captureAlive)
                    } else {
                        Toggle("Collect diagnostics", isOn: $collectionEnabled)
                        Text("Collection is off. Translation and capture continue.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                attentionSection
                Section("Lenses") {
                    ForEach(DiagPage.lenses) { lens in
                        NavigationLink { lensPage(lens) } label: {
                            LensRow(title: lens.title, value: lensValue(lens), symbol: lens.icon)
                        }
                    }
                }
                if !collectDetails && collectionEnabled {
                    Section {
                        Toggle("Detailed collection", isOn: $collectDetails)
                    } footer: {
                        Text("Adds the graphs, timings and event log. Turn it on before a test run.")
                    }
                }
            }
            .modifier(ReadableColumn())
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Sharer.shareFile(text: diag.report(engine: engine), name: "translator-report-\(Sharer.stamp()).txt") } label: {
                        Label("Share report", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Detail level") {
                            Toggle("Collect diagnostics", isOn: $collectionEnabled)
                            Toggle("Detailed collection", isOn: $collectDetails).disabled(!collectionEnabled)
                        }
                        Section("Export") {
                            Button { Task { await diag.exportZIP() } } label: {
                                Label(diag.exportInProgress ? "Preparing ZIP…" : "Export evidence ZIP", systemImage: "archivebox")
                            }.disabled(diag.exportInProgress)
                            Button { Task { await diag.exportJSON() } } label: {
                                Label(diag.exportInProgress ? "Preparing JSON…" : "Export structured JSON", systemImage: "curlybraces")
                            }.disabled(diag.exportInProgress)
                            Button { Sharer.shareFile(text: diag.csv(), name: "translator-data-\(Sharer.stamp()).csv") } label: {
                                Label("Export data (CSV)", systemImage: "tablecells")
                            }
                            Button {
                                UIPasteboard.general.string = diag.report(engine: engine)
                                engine.toast("Report copied")
                            } label: { Label("Copy report", systemImage: "doc.on.doc") }
                        }
                        Button { showSimulator = true } label: { Label("Pipeline simulator", systemImage: "point.3.connected.trianglepath.dotted") }
                        Button(role: .destructive) { confirmReset = true } label: { Label("Reset counters", systemImage: "trash") }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showSimulator) { NavigationStack { PipelineSimulatorView() } }
            .sheet(isPresented: $showTestReport) { TestRunReportSheet(diag: diag) }
            .onChange(of: collectionEnabled) { _, _ in engine.diagnosticsSettingsChanged() }
            .onChange(of: collectDetails) { _, _ in engine.diagnosticsSettingsChanged() }
            .confirmDestructive("Delete all unpinned test runs?", message: "Pinned runs, translation memory, history and settings are not changed.",
                                isPresented: $confirmDeleteSessions, button: "Delete unpinned runs") {
                Task { await diag.deleteAllUnpinnedRuns() }
            }
            .confirmDestructive("Clear all graphs, counters and the timeline?", isPresented: $confirmReset, button: "Reset counters") {
                engine.resetDiagnostics()
                engine.toast("Diagnostics reset")
            }
        }
    }

    /// Only shown when there is evidence: an issue the recorder actually found.
    @ViewBuilder private var attentionSection: some View {
        let a = diag.assessment(alive: facts.captureAlive, paused: facts.paused)
        if collectionEnabled && !a.issues.isEmpty {
            Section("Needs attention") {
                ForEach(Array(a.issues.prefix(3))) { issue in
                    HStack(alignment: .firstTextBaseline, spacing: KitSpace.row) {
                        Image(systemName: issue.severity == 2 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == 2 ? Color.red : Color.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title).font(.body)
                            Text(issue.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: KitSpace.tight)
                        if let fix = issue.fix {
                            Button(fix.label) { apply(fix) }.buttonStyle(.bordered).font(.subheadline)
                        }
                    }
                    .frame(minHeight: 44)
                }
            }
        }
    }

    /// The one-line live value next to each lens.
    private func lensValue(_ lens: DiagPage) -> String {
        switch lens {
        case .overview: return ""
        case .speed:
            let d = Diagnostics.summarize(diag.latency)
            return d.n > 0 ? "\(Int(d.p50)) ms median" : "–"
        case .timeline: return "\(tick.value.events) events"
        case .pipeline:
            let o = Diagnostics.summarize(Array(diag.ocr.suffix(20)))
            let t = Diagnostics.summarize(Array(diag.translate.suffix(20)))
            return o.n + t.n > 0 ? "Reading \(Int(o.avg)) · Translating \(Int(t.avg))" : "–"
        case .language:
            let pair = "\(facts.sourceCode == "auto" ? "Auto" : facts.sourceCode.uppercased()) → \(facts.targetCode.uppercased())"
            return pair + (facts.sourceCode == "auto" || facts.sourceReady ? " · ready" : " · needs pack")
        case .device: return thermalName
        case .memory: return "\(facts.memoryCount.formatted()) remembered"
        case .sessions: return "\(tick.value.runs) saved"
        case .log: return "\(tick.value.events) entries"
        }
    }

    /// A lens: its own large title, its own range control, an inline switch when it needs Detailed collection.
    private func lensPage(_ lens: DiagPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KitSpace.group) {
                if lens.ranged { rangePicker }
                if lens.needsDetails && !collectDetails {
                    Toggle(isOn: $collectDetails) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Detailed collection")
                            Text("Graphs on this page need it.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 44)
                }
                pageContent(lens)
            }
            .padding(.horizontal, KitSpace.margin)
            .padding(.bottom, KitSpace.group)
        }
        .navigationTitle(lens.title)
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: Simple
    private var systemCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            LabeledContent("Active system", value: facts.system.shortName)
            if facts.pending != facts.system {
                LabeledContent("Next capture", value: facts.pending.shortName)
            }
            Hint(facts.availability)
            Hint("Legacy reference: 1.7.2 (58), e94542ce. Apple default does not identify an effective model.")
        }
        .padding(.vertical, KitSpace.tight)
    }

    private var statusLine: String {
        facts.captureAlive
            ? "Capture connected · \(diag.s.translations) translation\(diag.s.translations == 1 ? "" : "s") this session"
            : "Waiting for capture to start"
    }

    /// Delay evidence plus the export button. Counters that explain it are under Advanced.
    private var evidenceCard: some View {
        let delay = Diagnostics.summarize(diag.latency)
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Text("Test evidence").font(.headline)
                Spacer()
                Text(AppVersion.full).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if delay.n > 0 {
                HStack(alignment: .top, spacing: Space.m) {
                    evidenceNumber("Typical", delay.p50)
                    evidenceNumber("Average", delay.avg)
                    evidenceNumber("Slow tail · P95", delay.p95)
                }
            } else {
                Hint("No complete OCR-to-PiP enqueue samples yet.")
            }
            Hint("Measured from first OCR sighting to PiP buffer enqueue; physical display is not measured. \(delay.n) matched samples.")
            PrimaryButton(title: diag.exportInProgress ? "Preparing evidence ZIP…" : "Export complete diagnostic ZIP",
                          symbol: "archivebox", enabled: !diag.exportInProgress) { Task { await diag.exportZIP() } }
            Hint(diag.archiveStatus)
        }
        .padding(.vertical, KitSpace.tight)
    }

    private func evidenceNumber(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(Int(value)) ms").font(.title3.weight(.semibold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The counters behind the headline numbers (shown on the Pipeline page).
    private var evidenceDetails: some View {
        let stats = diag.s
        let model = Diagnostics.summarize(diag.translate)
        return VStack(alignment: .leading, spacing: Space.s) {
            Text("Counters").font(.headline)
            LabeledContent("Confirmed candidate packets", value: "\(stats.confirmedCandidatePackets)")
            LabeledContent("Successful PiP candidate enqueues", value: "\(stats.enqueuedCandidateFrames)")
            LabeledContent("Confirmed but superseded before enqueue", value: "\(stats.supersededUnpresentedConfirmed)")
            LabeledContent("Speculative pipelines discarded", value: "\(stats.specDiscarded)")
            if facts.system == .legacy {
                LabeledContent("Superseded units retained in RAM", value: "\(stats.specRetainedUnits)")
            } else {
                LabeledContent("Speculative model requests", value: "\(stats.specModelRequests)")
                Hint("Strategy-specific session-cache reuse appears in memory counts; Legacy retained-unit accounting does not apply.")
            }
            LabeledContent("Pre-translated sentence hits", value: "\(stats.specHits)")
            if model.n > 0 {
                Hint("Measured model processing: median \(Int(model.p50)) ms · mean \(Int(model.avg)) ms · P95 \(Int(model.p95)) ms (\(model.n) batches).")
            } else if !collectDetails {
                Hint("Model timing charts require Detailed collection. Translation counters remain active in Simple mode.")
            } else if stats.translations > 0 {
                Hint("Translations selected, but no model timings recorded. The captions may have come from memory.")
            } else {
                Hint("No model timing samples yet. Start capture and translate text to collect measurements.")
            }
            Hint("Latency covers successful frame enqueues. Replaced work is excluded, so lower latency alone does not establish better subtitle continuity. Candidates, sentence hits and model requests count different events.")
        }
        .font(.footnote)
        .padding(.vertical, KitSpace.tight)
    }

    private func apply(_ f: Fix) {
        let ud = UserDefaults.standard
        switch f {
        case .fastSpeed: ud.set("fast", forKey: "speed")
        case .instantStability: ud.set(1, forKey: "stability")
        case .immediateDisplay: ud.set("immediate", forKey: "displayPolicy"); engine.timingSettingsChanged()
        case .fixedRotation:
            ud.set("0", forKey: "frameRot")
            engine.rotationSettingChanged()
        case .narrowArea: ud.set("bottom", forKey: "area")
        case .openLanguages: router.openLanguages(); return
        case .startCapture: router.go(.translate); return
        case .translateAhead: ud.set(true, forKey: "translateAhead")
        }
        engine.syncConfig()
        engine.tap()
        engine.toast("Applied: \(f.label)")
    }

    // MARK: Pages
    private var rangePicker: some View {
        Picker("Range", selection: $rangeRaw) {
            ForEach(DiagRange.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder private func pageContent(_ lens: DiagPage) -> some View {
        switch lens {
        case .overview: evidenceCard
        case .speed:
            sessionGrid
            percentileTable
            speedPage
        case .timeline: timelinePage
        case .pipeline:
            LiveFeedSection()
            pipelineStrip
            systemCard
            evidenceDetails
            pipelinePage
            adaptivePipelineCard
            subtitleLifecycleCard
        case .language: languagePage
        case .device: devicePage
        case .memory: memoryPage
        case .sessions: sessionsPage
        case .log: logPage
        }
    }

    private var memoryPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Translation memory").font(.headline)
            LabeledContent("Entries", value: String(diag.memoryHealth.totalEntries))
            LabeledContent("Ready / needs validation", value: "\(diag.memoryHealth.readyEntries) / \(diag.memoryHealth.needsValidation)")
            LabeledContent("Conflicts", value: String(diag.memoryHealth.conflicts))
            LabeledContent("Database", value: ByteCountFormatter.string(fromByteCount: diag.memoryHealth.databaseBytes, countStyle: .file))
            LabeledContent("RAM entries", value: String(diag.memoryHealth.ramEntries))
            LabeledContent("Schema", value: String(diag.memoryHealth.schemaVersion))
            LabeledContent("Migration", value: diag.memoryHealth.migrationStatus)
            LabeledContent("Integrity", value: diag.memoryHealth.integrity)
            LabeledContent("Pending / failed writes", value: "\(diag.memoryHealth.pendingWrites) / \(diag.memoryHealth.failedWrites)")
            ForEach(diag.memoryHealth.categoryCounts.keys.sorted(), id: \.self) { category in
                LabeledContent(category.replacingOccurrences(of: "_", with: " ").capitalized,
                               value: String(diag.memoryHealth.categoryCounts[category, default: 0]))
            }
            Text("Pending writes are not yet durable. RAM eviction never means permanent deletion. Lookup outcomes count translation units; persistence counters count write operations.").font(.caption).foregroundStyle(.secondary)
            ForEach(MemoryDiagnosticOutcome.allCases, id: \.self) { outcome in
                LabeledContent(outcome.rawValue, value: String(diag.memoryOutcomesForUI(outcome)))
            }
            Text(diag.archiveStatus).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, KitSpace.tight)
    }

    private var sessionsPage: some View {
        TestRunsPage(diag: diag, showReport: $showTestReport, confirmDeleteUnpinned: $confirmDeleteSessions).padding(.vertical, KitSpace.tight)
    }

    private var liveFraction: Double {
        let now = Date()
        let total = now.timeIntervalSince(diag.started)
        guard total > 1 else { return 0 }
        let live = diag.spans.filter { $0.state == .live }.reduce(0.0) { $0 + ($1.end ?? now).timeIntervalSince($1.start) }
        return Swift.min(1, live / total)
    }

    private var arrow: some View {
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
    }

    private func node(_ title: String, _ icon: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.18), in: Circle())
            Text(title).font(.caption.weight(.semibold))
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    private var pipelineStrip: some View {
        let o = Diagnostics.summarize(Array(diag.ocr.suffix(20)))
        let t = Diagnostics.summarize(Array(diag.translate.suffix(20)))
        let d = Diagnostics.summarize(Array(diag.latency.suffix(20)))
        let fpsColor: Color = !facts.captureAlive ? Color.red : (diag.s.fps >= 15 ? Color.green : Color.orange)
        let showColor: Color = !facts.pipActive ? Color.gray : level(d.avg, d.n, 1200, 2000)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Pipeline").font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                node("Capture", "video", facts.captureAlive ? "\(Int(diag.s.fps)) fps" : "off", fpsColor)
                arrow
                node("Read", "text.viewfinder", o.n > 0 ? "\(Int(o.avg)) ms" : "–", level(o.avg, o.n, 300, 500))
                arrow
                node("Filter", "line.3.horizontal.decrease", "\(diag.s.blocksKept)/\(diag.s.blocksIn)", Color.green)
                arrow
                node(facts.system == .legacy ? "Translate" : "Model", "character.bubble",
                     t.n > 0 ? "\(Int(t.avg)) ms" : "–", level(t.avg, t.n, 400, 800))
                arrow
                node("Show", "rectangle.on.rectangle", facts.pipActive ? (d.n > 0 ? "\(Int(d.avg)) ms" : "–") : "closed", showColor)
            }
        }
        .padding(.vertical, KitSpace.tight)
    }

    private var sessionGrid: some View {
        let s = diag.s
        let hits = s.cacheHits + s.savedHits + s.specHits + s.cacheMisses
        return VStack(spacing: 0) {
            StatTile(title: "Time live", value: "\(Int(liveFraction * 100))%", tint: Color.green, icon: "dot.radiowaves.left.and.right")
            StatTile(title: "Started", value: diag.started.formatted(date: .omitted, time: .shortened), icon: "clock")
            StatTile(title: "Translations", value: "\(s.translations)", tint: Color.cyan, icon: "character.bubble")
            StatTile(title: "Sentences", value: "\(s.sentences)", icon: "text.alignleft")
            StatTile(title: "Characters", value: "\(s.chars)", icon: "textformat")
            StatTile(title: "Cache hits", value: hits == 0 ? "–" : "\(Int(Double(s.cacheHits + s.savedHits + s.specHits) / Double(hits) * 100))%",
                     tint: Color.purple, icon: "memorychip")
            StatTile(title: "Capture drops", value: "\(s.captureDrops)",
                     tint: s.captureDrops > 0 ? Color.orange : Color.primary, icon: "bolt.slash")
            StatTile(title: "Failures", value: "\(s.failures)",
                     tint: s.failures > 0 ? Color.red : Color.primary, icon: "exclamationmark.triangle")
            StatTile(title: "Pre-translated", value: "\(s.specHits)", tint: Color.cyan, icon: "forward.fill")
            StatTile(title: "Remembered", value: "\(facts.memoryCount)", tint: Color.mint, icon: "externaldrive")
        }
    }

    private var percentileTable: some View {
        let rows: [(String, Summary)] = [
            ("Reading", Diagnostics.summarize(diag.ocr)),
            ("Translating", Diagnostics.summarize(diag.translate)),
            ("Total delay", Diagnostics.summarize(diag.latency)),
            ("Transfer", Diagnostics.summarize(diag.transport))
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Timing summary (ms)").font(.subheadline.weight(.semibold))
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("avg")
                    Text("p50")
                    Text("p95")
                    Text("max")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(rows, id: \.0) { r in
                    GridRow {
                        Text(r.0).font(.caption.weight(.semibold)).gridColumnAlignment(.leading)
                        Text(r.1.n > 0 ? "\(Int(r.1.avg))" : "–")
                        Text(r.1.n > 0 ? "\(Int(r.1.p50))" : "–")
                        Text(r.1.n > 0 ? "\(Int(r.1.p95))" : "–")
                        Text(r.1.n > 0 ? "\(Int(r.1.max))" : "–")
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
        .padding(.vertical, KitSpace.tight)
    }

    // MARK: Speed
    private var speedPage: some View {
        let important: Set<EventKind> = [.error, .rotation, .preset, .capture]
        let markers = Array(diag.events.filter { important.contains($0.kind) && $0.time >= rangeStart }.suffix(6))
        return VStack(spacing: 14) {
            LineCard(title: "Reading the screen", samples: slice(diag.ocr), color: Color.green, unit: "ms", rule: 300, markers: markers)
            LineCard(title: facts.system == .legacy ? "Translating" : "Completed model inference", samples: slice(diag.translate), color: Color.cyan, unit: "ms", markers: markers)
            LineCard(title: "First sighting → frame enqueue", samples: slice(diag.latency), color: Color.orange, unit: "ms", rule: 1500, markers: markers)
            LineCard(title: "Transfer extension → app", samples: slice(diag.transport), color: Color.purple, unit: "ms")
            LineCard(title: "Frames per second", samples: slice(diag.fps), color: Color.teal, unit: "fps")
            HistogramCard(title: "How long reading takes", values: slice(diag.ocr).map { $0.v }, color: Color.green)
            HistogramCard(title: "How long the total delay is", values: slice(diag.latency).map { $0.v }, color: Color.orange)
            if facts.system != .legacy {
                Text("Model-inference timings include successful backend requests even if an obsolete result was not displayed. Memory-only translations add no model sample. Total delay ends at PiP buffer enqueue.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, KitSpace.tight)
            }
            PairedTimingCard(samples: diag.pipeline.filter { $0.date >= rangeStart })
            granularityCard
        }
    }

    /// Raw bucketed counts are useful for short bursts even when timing
    /// percentile sample sizes are too small to interpret meaningfully.
    private var granularityCard: some View {
        let buckets = diag.completedIntervals(seconds: bucketSeconds)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Short-interval evidence")
                .font(.subheadline.weight(.semibold))
            Picker("Time resolution", selection: $bucketSeconds) {
                Text("1 second").tag(1)
                Text("5 seconds").tag(5)
                Text("15 seconds").tag(15)
            }
            .pickerStyle(.segmented)
            if buckets.isEmpty {
                Text(bucketSeconds == 1
                     ? "No one-second buckets yet. Enable Detailed diagnostics and run capture."
                     : "No completed buckets yet at this resolution.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(Array(buckets.suffix(12)), id: \.startedAt) { bucket in
                    HStack(alignment: .top) {
                        Text(bucket.startedAt.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit())
                            .frame(width: 76, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Confirmed \(bucket.counters["candidateConfirmed", default: 0]) · enqueued \(bucket.counters["candidateEnqueued", default: 0])")
                                .font(.caption)
                            Text("Superseded \(bucket.counters["unpresentedConfirmed", default: 0]) · enqueue failures \(bucket.counters["enqueueFailed", default: 0])")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        Text(String(format: "%.1f s", bucket.elapsedSeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("Buckets use actual elapsed time. For precise event order and durations, export events.csv; for longer sessions, use 15-second intervals. Individual buckets may have too few timings for useful P95.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, KitSpace.tight)
    }

    // MARK: Timeline
    private var stateCard: some View {
        let spans = diag.spans.filter { ($0.end ?? Date()) >= rangeStart }
        let evs = diag.events.filter { $0.time >= rangeStart && $0.kind != .translation && $0.kind != .state }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Session timeline").font(.subheadline.weight(.semibold))
            if spans.isEmpty {
                Text("No state timeline spans in this range. Capture and Detailed collection are required.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                Chart {
                    ForEach(spans) { s in
                        RectangleMark(xStart: .value("Start", Swift.max(s.start, rangeStart)),
                                      xEnd: .value("End", s.end ?? Date()),
                                      y: .value("Lane", "State"), height: .fixed(26))
                            .foregroundStyle(s.state.color.opacity(0.85))
                    }
                    ForEach(evs) { e in
                        PointMark(x: .value("Time", e.time), y: .value("Lane", "Events"))
                            .foregroundStyle(e.kind.color)
                            .symbolSize(70)
                    }
                }
                .chartXScale(domain: rangeStart...Date())
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .frame(height: 120)
                HStack(spacing: 12) {
                    ForEach([EngineState.live, .paused, .frozen, .idle], id: \.rawValue) { st in
                        HStack(spacing: 4) {
                            Circle().fill(st.color).frame(width: 8, height: 8)
                            Text(st.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, KitSpace.tight)
    }

    private var perMinuteCard: some View {
        let unit: Calendar.Component = range == .oneMin ? .second : .minute
        let tr = diag.events.filter { $0.kind == .translation && $0.time >= rangeStart && $0.text.hasPrefix("Translated") }
        let grouped = Dictionary(grouping: tr) { Calendar.current.dateInterval(of: unit, for: $0.time)?.start ?? $0.time }
        let buckets = grouped.map { Bucket(date: $0.key, count: $0.value.count) }.sorted { $0.date < $1.date }
        return VStack(alignment: .leading, spacing: 8) {
            Text(range == .oneMin ? "Translations per second" : "Translations per minute").font(.subheadline.weight(.semibold))
            if buckets.isEmpty {
                Text("No translations in this period.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                Chart(buckets) { b in
                    BarMark(x: .value("Time", b.date, unit: unit), y: .value("Translations", b.count))
                        .foregroundStyle(Color.cyan.gradient)
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 120)
            }
        }
        .padding(.vertical, KitSpace.tight)
    }

    private var timelinePage: some View {
        VStack(spacing: 14) {
            stateCard
            perMinuteCard
            eventListCard(limit: 150)
        }
    }

    private func eventRow(_ e: TimelineEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.time, format: .dateTime.hour().minute().second())
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(elapsed(e.time))
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .frame(width: 58, alignment: .leading)
            Image(systemName: e.kind.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(e.kind.color)
                .frame(width: 24, height: 24)
                .background(e.kind.color.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(e.text).font(.caption)
                if let d = e.detail, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func kindChip(_ title: String, _ icon: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(on ? Color.white : Color.secondary)
                .background(on ? color.opacity(0.7) : Palette.surface, in: Capsule())
        }
    }

    private var kindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                kindChip("All", "line.3.horizontal.decrease.circle", on: kinds.isEmpty, color: Color.gray) { kinds = [] }
                ForEach(EventKind.allCases) { k in
                    kindChip(k.title, k.icon, on: kinds.contains(k), color: k.color) {
                        if kinds.contains(k) { kinds.remove(k) } else { kinds.insert(k) }
                    }
                }
            }
        }
    }

    private func eventListCard(limit: Int) -> some View {
        let all = Array(diag.events.reversed())
        let shown = all.filter { e in
            (kinds.isEmpty || kinds.contains(e.kind))
                && (query.isEmpty || e.text.localizedCaseInsensitiveContains(query)
                    || (e.detail ?? "").localizedCaseInsensitiveContains(query))
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What happened").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(shown.count) event\(shown.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            kindChips
            if shown.isEmpty {
                Text("Nothing matches.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(shown.prefix(limit))) { e in eventRow(e) }
        }
        .padding(.vertical, KitSpace.tight)
    }

    // MARK: Pipeline
    private var subtitleLifecycleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Per-subtitle timeline").font(.headline)
            if diag.subtitleTraces.isEmpty { Text("Waiting for tracked candidates. Enable Detailed diagnostics and subtitle tracking.").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(diag.subtitleTraces.suffix(18))) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(String(item.candidate.suffix(12))) · \(item.stage) · \(item.time.formatted(date: .omitted, time: .standard))").font(.caption.monospaced())
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Times measure app processing and frame enqueue, not physical screen presentation. Full bounded timeline is in CSV.").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, KitSpace.tight)
    }

    private var adaptivePipelineCard: some View {
        let s = diag.s
        return VStack(alignment: .leading, spacing: 10) {
            Text("Recognition & work accounting").font(.headline)
            Text("OCR: \(Int(s.ocrConfidence*100))% · Source: \(s.sourceOrigin == "Selected" ? "selected" : "\(Int(s.languageConfidence*100))% confidence")").font(.footnote)
            Text(s.languageContextUsed ? "Recent source context assisted this ambiguous reading" : "Source evidence uses the current reading").font(.caption).foregroundStyle(.secondary)
            Text("\(s.recognitionReason) · \(s.confirmationReason)").font(.caption).foregroundStyle(.secondary)
            Text("Cache sentences · session \(s.cacheHits) · saved \(s.savedHits) · pre-translated \(s.specHits)").font(.footnote)
            Text("Speculative jobs · admitted \(s.specStarted) · ready \(s.specCompleted) · failed \(s.specDiscarded) · declined \(s.specSkipped)").font(.footnote)
            if facts.system == .legacy {
                Text("Spec throttled \(s.adaptiveSpeculationSkipped) · confirmed handoffs \(s.confirmedHandoffDeferred) · slow tails \(s.slowTailEnqueues)").font(.footnote)
                Text("Legacy declines · low confidence \(s.legacyLowConfidenceSkips) · low yield \(s.legacyAdaptiveLowYieldSkips) · saved memory \(s.legacyAdaptiveSavedSkips) · model busy \(s.legacyBusySpeculationSkips) · duplicate \(s.legacyDuplicateSpeculationSkips)").font(.caption).foregroundStyle(.secondary)
                Text("Discarded work: \(Int(s.specDiscardedMs)) ms · unconsumed cached results: \(facts.unconsumedSpeculation).").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Actual speculative model requests: \(s.specModelRequests) · Hybrid admission throttles: \(s.adaptiveSpeculationSkipped) · slow enqueues: \(s.slowTailEnqueues)").font(.footnote)
                Text("New-mode predictions and confirmed recoveries have separate model lanes. A cache-only result is not counted as model execution. Captions may reuse completed obsolete work.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Skipped frames · unchanged \(s.unchangedSkipped) · cadence \(s.cadenceSkipped) · paused \(s.pausedSkipped)").font(.caption)
            Text("Early OCR visual-change wakes: \(s.earlyVisualWakes) · derived from visual motion only, not confirmed text.").font(.caption).foregroundStyle(.secondary)
            Text("Capture packets over 8 KB: \(s.largePackets) · failed sends: \(s.packetSendErrors)").font(.caption).foregroundStyle(.secondary)
            Text("Pixel-verified confirmations: \(s.pixelConfirmations) · fell back to OCR: \(s.pixelRejections) · OCR skipped while caption unchanged: \(s.watchSkippedOCR) · OCR started on caption change: \(s.watchTriggeredOCR)").font(.caption).foregroundStyle(.secondary)
            Text("Recorder self-time · simple \(String(format: "%.1f", diag.recorderCosts.simpleMs)) ms · detailed \(String(format: "%.1f", diag.recorderCosts.detailedMs)) ms. Excludes chart drawing and model work; these are different workloads.").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, KitSpace.tight)
    }

    private var pipelinePage: some View {
        let s = diag.s
        let inArea = Swift.max(0, s.linesIn - s.dropArea)
        let afterRules = Swift.max(0, inArea - s.dropSmall - s.dropIgnore)
        let notOwn = Swift.max(0, afterRules - s.dropSelf)
        let needs = Swift.max(0, notOwn - s.dropTarget)
        let lines = [
            BarRow(name: "Lines read", value: s.linesIn),
            BarRow(name: "In the OCR area", value: inArea),
            BarRow(name: "Big enough & allowed", value: afterRules),
            BarRow(name: "Not our own window", value: notOwn),
            BarRow(name: "Need translating", value: needs)
        ]
        let realBlocks = Swift.max(0, s.blocksKept - s.dropNoise - s.dropLanguage)
        let blocks = [
            BarRow(name: "Text blocks found", value: s.blocksIn),
            BarRow(name: "Blocks kept", value: s.blocksKept),
            BarRow(name: "Real text", value: realBlocks),
            BarRow(name: "Sentences translated", value: s.sentences)
        ]
        let parts = [
            DonutPart(name: "Translated", value: needs, color: Color.green),
            DonutPart(name: "Outside area", value: s.dropArea, color: Color.gray),
            DonutPart(name: "Too small", value: s.dropSmall, color: Color.yellow),
            DonutPart(name: "Ignore list", value: s.dropIgnore, color: Color.orange),
            DonutPart(name: "Own window", value: s.dropSelf, color: Color.pink),
            DonutPart(name: "Already target", value: s.dropTarget, color: Color.blue)
        ]
        return VStack(spacing: 14) {
            BarListCard(title: "Where lines go", rows: lines, color: Color.blue)
            DonutCard(title: "What happens to every line", parts: parts)
            BarListCard(title: "Blocks and sentences", rows: blocks, color: Color.purple)
            LineCard(title: "Lines per read", samples: Array(diag.lineCounts.suffix(120)), color: Color.mint, unit: "lines")
            VStack(alignment: .leading, spacing: 8) {
                Text("Details").font(.subheadline.weight(.semibold))
                LabeledContent("Numbers / noise dropped", value: "\(s.dropNoise)")
                LabeledContent("Other-language blocks dropped", value: "\(s.dropLanguage)")
                LabeledContent("Floating window position", value: s.pipRegion)
                LabeledContent("Unchanged frames skipped", value: "\(s.skippedFrames)")
            }
            .font(.footnote)
            .padding(.vertical, KitSpace.tight)
            if diag.detailedCollection {
                candidateTraceCard
            }
        }
    }

    /// Unlike a plain timeline, this groups all observed stages by the same
    /// privacy-safe candidate identity. Missing stages are never synthesized.
    private var candidateTraceCard: some View {
        let candidates = DiagnosticTraceReview.review(diag.structuredEvents, limit: 12)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Translation decision traces").font(.subheadline.weight(.semibold))
            Text("Correlated metadata from this session. An absent stage was not necessarily executed or skipped; PiP timings end at buffer enqueue.")
                .font(.caption).foregroundStyle(.secondary)
            if candidates.isEmpty {
                Text("No correlated events yet. Enable detailed collection and translate a subtitle.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { candidate in
                    DisclosureGroup("Candidate \(candidate.id.uuidString.prefix(8)) · \(candidate.stages.count) events") {
                        Text(candidate.status)
                            .font(.caption.weight(.medium))
                        LabeledContent("Observed frames", value: String(candidate.frameCount))
                        ForEach(candidate.stages) { stage in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stage.stage.replacingOccurrences(of: "_", with: " "))
                                        .font(.caption.weight(.medium))
                                    Text(stage.reason.replacingOccurrences(of: "_", with: " "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let ms = stage.durationMs {
                                    Text(String(format: "%.2f ms", ms))
                                        .font(.caption.monospacedDigit())
                                }
                            }
                        }
                    }
                    .font(.footnote)
                }
            }
        }
        .padding(.vertical, KitSpace.tight)
    }

    // MARK: Language
    private var languagePage: some View {
        let s = diag.s
        let counts = diag.sourceUsage.counts.sorted { $0.value > $1.value }.prefix(8).map { BarRow(name: $0.key.uppercased(), value: $0.value) }
        let pair: String = facts.sourceCode == "auto" ? "Auto"
            : (facts.sourceReady ? "Ready" : "Needs pack")
        let cache = [
            DonutPart(name: "Session cache", value: s.cacheHits, color: Color.green),
            DonutPart(name: "Pre-translated", value: s.specHits, color: Color.cyan),
            DonutPart(name: "Saved memory", value: s.savedHits, color: Color.purple),
            DonutPart(name: "Translated fresh", value: s.cacheMisses, color: Color.orange)
        ]
        return VStack(spacing: 14) {
            VStack(spacing: 0) {
                StatTile(title: "Source used", value: s.sourceUsed == "–" ? "–" : s.sourceUsed.uppercased(), icon: "sparkle.magnifyingglass")
                StatTile(title: "Locked to", value: s.lockedLang == "–" ? "none" : s.lockedLang.uppercased(), tint: Color.purple, icon: "lock")
                StatTile(title: "Language pack", value: pair, tint: pair == "Needs pack" ? Color.orange : Color.green, icon: "arrow.down.circle")
                StatTile(title: "Engine", value: facts.system == .legacy
                         ? (s.sessionKind == "–" ? "Default" : (s.sessionKind.contains("iOS 26") ? "Direct" : "Hosted"))
                         : facts.system.shortName, icon: "cpu")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(facts.sourceCode == "auto" ? "Source: Automatic" : "Source: \(facts.sourceCode.uppercased()) selected")
                    .font(.subheadline.weight(.semibold))
                Text(facts.sourceCode == "auto" ? "With language lock enabled, four confident matching detections within six qualifying readings lock the source. Clear language changes translate immediately; three mismatches release the lock. The target language is never locked." : "Automatic detection is off. Selected-language inputs still count in the graph.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, KitSpace.tight)
            BarListCard(title: "Source languages used · session", rows: Array(counts), color: Color.purple)
            BarListCard(title: "How the source was chosen", rows: SourceLanguageOrigin.allCases.map {
                BarRow(name: $0.title, value: diag.sourceUsage.origins[$0, default: 0])
            }, color: Color.teal)
            DonutCard(title: "Where translations come from", parts: cache)
            LineCard(title: "Cache hit rate over time", samples: slice(diag.cacheRate), color: Color.green, unit: "%")
            VStack(alignment: .leading, spacing: 10) {
                Text("Recognized speaker labels · session").font(.subheadline.weight(.semibold))
                Text("This session list is local and clears on reset or app restart. Exporting names still requires text-sharing consent.").font(.caption).foregroundStyle(.secondary)
                if diag.names.isEmpty {
                    Text("Private sessions hide names. Otherwise, enable speaker recognition and session speaker labels; names appear for visible text such as \"Name: line\". Voices and unlabeled people are not identified.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(diag.names, id: \.self) { n in
                            Text(n).font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.25), in: Capsule())
                        }
                    }
                }
            }
            .padding(.vertical, KitSpace.tight)
        }
    }

    // MARK: Device
    private var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot (throttling)"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
    private var thermalColor: Color {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: Color.green
        case .fair: Color.yellow
        case .serious: Color.orange
        case .critical: Color.red
        @unknown default: Color.gray
        }
    }

    private var thermalCard: some View {
        let data = slice(diag.thermal)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Phone temperature").font(.subheadline.weight(.semibold))
                Spacer()
                Text(thermalName).font(.subheadline.weight(.bold)).foregroundStyle(thermalColor)
            }
            Text("App performance: " + ThermalPerformancePolicy.tier(for: ProcessInfo.processInfo.thermalState).rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Reduction reasons: " + diag.captureReductionReasons.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
            if data.count < 2 {
                Text(data.isEmpty ? "No thermal samples in this range. Detailed collection is required." :
                     "One thermal sample recorded. The second sample will establish a trend.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart(data) { s in
                    AreaMark(x: .value("Time", s.t), y: .value("Level", s.v))
                        .foregroundStyle(Color.orange.opacity(0.35))
                        .interpolationMethod(.stepEnd)
                    LineMark(x: .value("Time", s.t), y: .value("Level", s.v))
                        .foregroundStyle(Color.orange)
                        .interpolationMethod(.stepEnd)
                }
                .chartYScale(domain: 0.0...3.0)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0.0, 1.0, 2.0, 3.0]) { v in
                        AxisGridLine()
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(["Normal", "Warm", "Hot", "Critical"][Swift.min(3, Swift.max(0, Int(d)))])
                                    .font(.caption)
                            }
                        }
                    }
                }
                .frame(height: 110)
            }
        }
        .padding(.vertical, KitSpace.tight)
    }

    private var devicePage: some View {
        let s = diag.s
        let b = UIDevice.current.batteryLevel
        return VStack(spacing: 14) {
            LineCard(title: "Extension memory headroom", samples: slice(diag.extMem), color: Color.teal, unit: "MB", rule: 15)
            LineCard(title: "Main app memory headroom", samples: slice(diag.appMem), color: Color.indigo, unit: "MB")
            thermalCard
            LineCard(title: "Battery", samples: slice(diag.battery), color: Color.green, unit: "%")
            VStack(alignment: .leading, spacing: 8) {
                Text("Details").font(.subheadline.weight(.semibold))
                LabeledContent("Capture extension", value: facts.extensionVersion == "–" ? "not seen yet" : "v\(facts.extensionVersion)")
                LabeledContent("Frame size", value: s.bufferSize)
                LabeledContent("Orientation from iOS", value: s.orientation)
                LabeledContent("Read area size", value: s.cropSize)
                LabeledContent("Rotation applied", value: "\(s.rotation * 90)°")
                LabeledContent("Lowest extension headroom", value: s.minExtFreeMB > 9000 ? "–" : "\(Int(s.minExtFreeMB)) MB")
                LabeledContent("Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
                LabeledContent("Battery now", value: b < 0 ? "–" : "\(Int(b * 100))%")
            }
            .font(.footnote)
            .padding(.vertical, KitSpace.tight)
        }
    }

    // MARK: Log
    private var logPage: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search the log", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            .padding(12)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            eventListCard(limit: 400)
        }
    }
}
