// ScreenLingo – App – Diagnostics (2.1.0 build 92: pinned page chips, Live page first)
import SwiftUI
import Charts

// MARK: - Snapshots
// The dashboard is live by design, but it never observes the whole engine or the whole recorder.
// Each section reads a small Equatable snapshot that refreshes at most a few times a second and only when it changes.


// MARK: - Pages
enum DiagPage: String, CaseIterable, Identifiable {
    case overview, speed, timeline, pipeline, language, device, memory, sessions, log
    var id: String { rawValue }
    var title: String {
        switch self { case .overview: "Live"; case .sessions: "Test runs"; case .log: "Event log"; default: rawValue.capitalized }
    }
    /// Lenses with time charts get their own range control.
    var ranged: Bool { self == .speed || self == .timeline || self == .device }
    /// Lenses that only fill with Detailed collection.
    var needsDetails: Bool { self != .overview && self != .memory && self != .sessions && self != .language }
    var icon: String {
        switch self {
        case .overview: "dot.radiowaves.left.and.right"
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
    @EngineHandle var engine
    var body: some View { DiagnosticsBody(diag: engine.diag) }
}

/// What is being read and shown right now. The only other section that reads the fast-changing engine values.
struct LiveFeedSection: View {
    @EngineFacts(PulseFacts.read) private var pulse
    var active: Bool = true
    var body: some View {
        if active || !pulse.lastRaw.isEmpty || !pulse.translated.isEmpty { feed }
    }
    private var feed: some View {
        VStack(alignment: .leading, spacing: KitSpace.tight) {
            Text("Right now").font(.headline)
            ListRow(title: "Reads", subtitle: pulse.lastRaw.isEmpty ? "Nothing yet" : pulse.lastRaw, symbol: "text.viewfinder") { EmptyView() }
            Divider()
            ListRow(title: "Shows", subtitle: pulse.translated.isEmpty ? "Nothing yet" : pulse.translated, symbol: "character.bubble") { EmptyView() }
            Hint("Translator: " + pulse.activity)
            if pulse.status != "Idle" && !pulse.activity.hasPrefix(pulse.status) { Hint(pulse.status) }
        }
        .kitSurface()
    }
}

/// The overview's one answer: typical delay with a 60-sample sparkline and one row of secondary values.
/// With no evidence it says "No session yet"; no score or red colour without data (R7).
struct OverviewAnswer: View {
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

struct DiagnosticsBody: View {
    @EngineHandle var engine
    @EngineFacts(DashboardFacts.read) var facts
    @EnvironmentObject var router: AppRouter
    let diag: Diagnostics
    @StateObject private var tick: ObjectSlice<Diagnostics, DiagTick>
    @AppStorage("diagnosticsEnabled") var collectionEnabled = true
    @AppStorage("detailedCollection") var collectDetails = false
    @AppStorage("diagPage") private var pageRaw = DiagPage.overview.rawValue
    @AppStorage("diagRange") var rangeRaw = DiagRange.fiveMin.rawValue
    @State var kinds: Set<EventKind> = []
    @State var query = ""
    @State private var confirmReset = false
    @State var pendingCollection: PendingCollectionChange?
    @State private var showSimulator = false
    @State var confirmDeleteSessions = false
    @State var bucketSeconds = 1
    @State var showTestReport = false
    @Namespace private var chipSpace
    @Environment(\.dynamicTypeSize) var typeSize

    init(diag: Diagnostics) {
        self.diag = diag
        _tick = StateObject(wrappedValue: ObjectSlice(diag, milliseconds: 500) { DiagTick.read($0) })
    }

    var page: DiagPage { DiagPage(rawValue: pageRaw) ?? .overview }
    var range: DiagRange { DiagRange(rawValue: rangeRaw) ?? .fiveMin }
    var rangeStart: Date {
        range == .session ? diag.started : Date().addingTimeInterval(-Double(range.rawValue))
    }
    func slice(_ a: [Sample]) -> [Sample] { a.filter { $0.t >= rangeStart } }

    func elapsed(_ d: Date) -> String {
        let s = Int(d.timeIntervalSince(diag.started))
        return String(format: "+%d:%02d", s / 60, s % 60)
    }

    // MARK: Body
    /// Chip row under the title, one page at a time. It scrolls with the page (2.1.8): no pinned slab.
    /// Live opens first and carries the headline answer, what needs attention, and the old Live numbers.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: KitSpace.row) {
                    if collectionEnabled { pageBar }
                    VStack(alignment: .leading, spacing: KitSpace.group) { pageBody }
                        .padding(.horizontal, KitSpace.margin)
                        .padding(.top, KitSpace.tight)
                        .padding(.bottom, KitSpace.group)
                }
            }
            .modifier(ReadableColumn())
            .ambientGlow()
            .background(Color(.systemGroupedBackground))
            .animation(KitMotion.spring, value: pageRaw)
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Sharer.shareFile(text: diag.report(engine: engine), name: "translator-report-\(Sharer.stamp()).txt") } label: {
                        Label("Share report", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Detail level") {
                            Toggle("Collect diagnostics", isOn: $collectionEnabled.guardedByActiveRun(diag, pending: $pendingCollection))
                            Toggle("Detailed collection", isOn: $collectDetails.guardedByActiveRun(diag, pending: $pendingCollection)).disabled(!collectionEnabled)
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
            // 2.2.1 (D2): only the root handlers in ScreenTranslatorApp apply a collection change.
            .confirmCollectionChange($pendingCollection)
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

    // MARK: Chips and pages
    private func pageChip(_ p: DiagPage) -> some View {
        Button { withAnimation(KitMotion.spring) { pageRaw = p.rawValue } } label: {
            Label(p.title, systemImage: p.icon)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, KitSpace.row)
                .frame(minHeight: 36)
                .foregroundStyle(page == p ? Color.white : Color.primary)
                .background {
                    if page == p {
                        Capsule().fill(Color.accentColor).matchedGeometryEffect(id: "selectedChip", in: chipSpace)
                    } else {
                        Capsule().fill(Color(.secondarySystemFill))
                    }
                }
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(page == p ? .isSelected : [])
    }

    private var pageBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: KitSpace.tight) {
                    ForEach(DiagPage.allCases) { p in pageChip(p).id(p) }
                }
                .padding(.horizontal, KitSpace.margin)
            }
            .scrollClipDisabled()
            .onAppear { proxy.scrollTo(page, anchor: .center) }
            .onChange(of: pageRaw) { _, _ in withAnimation(KitMotion.spring) { proxy.scrollTo(page, anchor: .center) } }
            .sensoryFeedback(.selection, trigger: pageRaw)
        }
    }

    // MARK: Simple
    var systemCard: some View {
        VStack(alignment: .leading, spacing: KitSpace.tight) {
            LabeledContent("Active system", value: facts.system.shortName)
            if facts.pending != facts.system {
                LabeledContent("Next capture", value: facts.pending.shortName)
            }
            Hint(facts.availability)
            Hint(abSwitchLine)
            Hint("Legacy keeps the reading and translation steps of version 1.7.2 (build 58, commit e94542ce). Apple Default does not report which model it used.")
        }
        .kitSurface()
    }

    /// 2.3.2: the 2.2.3 test switches that are on for this session (pinned at session start). All default off.
    private var abSwitchLine: String {
        let on = [(TranslationHotPathAB.legacyConfirmedOwnLane, "Legacy own lane"),
                  (TranslationHotPathAB.refreshAvailabilityInBackground, "background language check"),
                  (TranslationHotPathAB.independentHeartbeat, "independent capture heartbeat"),
                  (TranslationHotPathAB.deferArmedSpeculation, "deferred early start"),
                  (TranslationHotPathAB.warmAtCaptureStart, "warm-up at capture start"),
                  (TranslationHotPathAB.confirmationReadReasons, "extra-read reasons"),
                  (TranslationHotPathAB.modelLengthBuckets, "length buckets"),
                  (TranslationHotPathAB.trustedCaptionBand, "trusted caption band"),
                  (TranslationHotPathAB.legacyHeadStart, "Legacy head start"),
                  (TranslationHotPathAB.quietRewarm, "quiet re-warm")].filter { $0.0 }.map { $0.1 }
        return on.isEmpty ? "Test switches on: none." : "Test switches on: " + on.joined(separator: ", ") + "."
    }

    @ViewBuilder func pageContent(_ lens: DiagPage) -> some View {
        switch lens {
        case .overview: livePage
        case .speed:
            percentileTable
            speedPage
        case .timeline: timelinePage
        case .pipeline:
            evidenceDetails
            enqueuePathCard
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

    /// 2.3.2: how this session's captions reached PiP, with the same names the exported report uses.
    /// Low Latency reports `recovery_success`; Legacy reports the same situation as confirmed fresh.
    private var enqueuePathCard: some View {
        let rows: [(String, String, Int)] = facts.system == .legacy
            ? [("Memory hit", "memory_hit", diag.enqueuePathCount("memory_hit")),
               ("Speculation ready", "speculation_match_ready", diag.enqueuePathCount("speculation_match_ready")),
               ("Speculation still running", "speculation_match_in_flight", diag.enqueuePathCount("speculation_match_in_flight")),
               ("Confirmed fresh", "confirmed_fresh", diag.enqueuePathCount("confirmed_fresh")),
               ("Fresh, text changed", "fresh_text_changed", diag.enqueuePathCount("fresh_text_changed"))]
            : [("Memory hit", "memory_hit", diag.enqueuePathCount("memory_hit")),
               ("Speculation ready", "speculation_match_ready", diag.enqueuePathCount("speculation_match_ready")),
               ("Speculation still running", "speculation_match_in_flight", diag.enqueuePathCount("speculation_match_in_flight")),
               ("Recovery after confirmation", "recovery_success", diag.enqueuePathCount("recovery_success"))]
        let total = rows.reduce(0) { $0 + $1.2 }
        return VStack(alignment: .leading, spacing: 8) {
            Text("How captions reached the screen").font(.headline)
            if total == 0 {
                Hint("No PiP enqueues recorded yet. This needs Detailed collection and a running capture.")
            } else {
                ForEach(rows, id: \.1) { row in
                    LabeledContent(row.0, value: "\(row.2) · \(Int(Double(row.2) / Double(total) * 100))%")
                }
                Hint("\(total) enqueues since the last reset. Memory and speculation answer before the caption is confirmed or from stored text; the last row(s) translate after confirmation and are the slow path.")
            }
        }
        .font(.footnote)
        .kitSurface()
    }

}
