// ScreenLingo – App – Test Runs (2.0.0 build 88)
import SwiftUI

// Test Runs UI (spec §11.6): Test card, Test Runs list and detail, report sheet.
// Every screen here reads a throttled Equatable snapshot of the recorder, never the whole recorder or the engine.

/// What the Test Runs screens show. Banners are tracked by id because they carry non-Equatable payloads.
struct TestRunsSnapshot: Equatable {
    var runs: [TestRunMeta]
    var currentID: UUID
    var currentName: String
    var activeMode: String?
    var activeStarted: Date?
    var bannerID: UUID?
    var archive: String
    var exporting: Bool
    var pruneNote: String?
    var captionCount: Int
    @MainActor static func read(_ d: Diagnostics) -> TestRunsSnapshot {
        TestRunsSnapshot(runs: d.testRuns, currentID: d.currentTestID, currentName: d.currentTestName,
                         activeMode: d.activeRun?.mode, activeStarted: d.activeRun?.startedAt, bannerID: d.lastRunBanner?.id,
                         archive: d.archiveStatus, exporting: d.exportInProgress, pruneNote: d.runPruneNote, captionCount: d.s.enqueuedCandidateFrames)
    }
}

enum TestRunText {
    static func modeTitle(_ mode: String) -> String {
        switch mode {
        case "legacy": return "Legacy"
        case "hybridRecovery": return "Hybrid"
        case "lowLatency": return "Low Latency"
        default: return "Unknown mode"
        }
    }
    static func modeIcon(_ mode: String) -> String {
        switch mode {
        case "legacy": return "clock.arrow.circlepath"
        case "hybridRecovery": return "arrow.triangle.merge"
        case "lowLatency": return "bolt"
        default: return "questionmark.circle"
        }
    }
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    static func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "–" }
    static func reason(_ code: TestRunFailReason) -> String {
        switch code {
        case .diskFull: return "the device storage is full"
        case .encodeFailed: return "the run could not be encoded"
        case .writeFailed: return "the file could not be written"
        }
    }
    static let modes = ["legacy", "hybridRecovery", "lowLatency"]
}

private struct RunBadges: View {
    let run: TestRunMeta
    private var items: [(String, Color)] {
        var items: [(String, Color)] = []
        if run.pinned { items.append(("Pinned", .yellow)) }
        if run.completeness == "recovered" { items.append(("Recovered", .orange)) }
        if run.completeness == "imported" { items.append(("Imported", .gray)) }
        if !run.trimmed.isEmpty { items.append(("Trimmed", .orange)) }
        if run.startingRAMEntries > 0 { items.append(("Memory filled at start", .orange)) }
        if run.mixedMode { items.append(("Mixed mode", .red)) }
        return items
    }

    var body: some View {
        if !items.isEmpty {
            HStack(spacing: 4) {
                ForEach(items, id: \.0) { item in
                    Text(item.0).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(item.1.opacity(0.2), in: Capsule())
                }
            }
        }
    }
}

struct TestRunRow: View {
    let run: TestRunMeta
    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: TestRunText.modeIcon(run.mode)).font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(TestRunText.modeTitle(run.mode) + (run.label.isEmpty ? "" : " · " + run.label)).font(.headline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(TestRunText.ms(run.enqueueP50Ms)).font(.headline.monospacedDigit())
                        Text("median").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("\(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(TestRunText.duration(run.durationSeconds)) · \(run.captions) captions")
                    .font(.caption).foregroundStyle(.secondary)
                Text("P95 \(TestRunText.ms(run.enqueueP95Ms)) · thermal \(run.thermal)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                RunBadges(run: run)
            }
        }.padding(.vertical, Space.xs)
    }
}

// MARK: Test card (shown in the Live Test sheet)

struct TestMemorySnapshot: Equatable {
    var captureAlive: Bool
    var temporaryEntries: Int
    @MainActor static func read(_ e: TranslatorEngine) -> TestMemorySnapshot {
        TestMemorySnapshot(captureAlive: e.captureAlive, temporaryEntries: e.temporaryMemoryEntries)
    }
}

/// The test checklist shown in the Live Test sheet. Same engine and Diagnostics calls as before, new layout.
struct TestCard: View {
    let diag: Diagnostics
    let engine: TranslatorEngine
    @StateObject private var runsSlice: ObjectSlice<Diagnostics, TestRunsSnapshot>
    @StateObject private var memory: EngineSlice<TestMemorySnapshot>
    @EnvironmentObject private var feedback: FeedbackCenter
    @AppStorage("privateSession") private var privateSession = false
    @AppStorage("testRunSaving") private var saving = "automatic"
    @State private var showRuns = false
    @State private var showReport = false
    @State private var renameTest = false
    @State private var testNameDraft = ""
    @State private var renameRun = false
    @State private var runLabelDraft = ""
    @State private var confirmClear = false

    init(diag: Diagnostics, engine: TranslatorEngine) {
        self.diag = diag
        self.engine = engine
        _runsSlice = StateObject(wrappedValue: ObjectSlice(diag) { TestRunsSnapshot.read($0) })
        _memory = StateObject(wrappedValue: EngineSlice(engine) { TestMemorySnapshot.read($0) })
    }

    private var currentRuns: [TestRunMeta] { runsSlice.value.runs.filter { $0.testID == runsSlice.value.currentID } }
    private func saved(_ mode: String) -> TestRunMeta? {
        currentRuns.filter { $0.mode == mode }.max { $0.endedAt < $1.endedAt }
    }
    private var nextMode: String? { TestRunText.modes.first { saved($0) == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Button { testNameDraft = runsSlice.value.currentName; renameTest = true } label: {
                    Label(runsSlice.value.currentName, systemImage: "pencil").font(.headline).frame(minHeight: 44)
                }.buttonStyle(.plain)
                Spacer()
                Button("New test") { diag.startNewTest(); Feedback.tap() }.frame(minHeight: 44)
            }
            if privateSession {
                Banner(text: "Private session: runs are not saved.", severity: .warning)
            } else if saving == "off" {
                Banner(text: "Saving test runs is off. Turn it on in Settings > Diagnostics & tests.", severity: .warning)
            }
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader(title: "Three systems, same content")
                HStack(spacing: Space.s) {
                    ForEach(TestRunText.modes, id: \.self) { mode in
                        let run = saved(mode)
                        VStack(spacing: Space.xs) {
                            Image(systemName: run != nil ? "checkmark.circle.fill" : TestRunText.modeIcon(mode))
                                .font(.title3).foregroundStyle(run != nil ? Palette.success : Color.secondary)
                                .accessibilityLabel(run != nil ? "Saved" : "Not saved yet")
                            Text(TestRunText.modeTitle(mode)).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            Text(run.map { TestRunText.ms($0.enqueueP50Ms) } ?? "Not run").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                    }
                }
                if let next = nextMode {
                    Text("Next: \(TestRunText.modeTitle(next))").font(.footnote).foregroundStyle(.secondary)
                }
            }.infoCard()

            if runsSlice.value.activeStarted != nil, let run = diag.activeRun {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    StatusPill(text: "Recording \(TestRunText.modeTitle(run.mode)) · \(TestRunText.duration(context.date.timeIntervalSince(run.startedAt))) · \(runsSlice.value.captionCount) captions",
                               symbol: "record.circle", severity: .error)
                }
            } else if runsSlice.value.bannerID != nil, let banner = diag.lastRunBanner {
                bannerView(banner)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Space.s) {
                SecondaryButton(title: "Save run", symbol: "tray.and.arrow.down") { Task { await diag.saveRunNow() }; Feedback.tap() }
                SecondaryButton(title: "Clear test memory", symbol: "eraser", enabled: !memory.value.captureAlive) { confirmClear = true }
                SecondaryButton(title: "Export report", symbol: "doc.text") { showReport = true }
                SecondaryButton(title: "Test runs", symbol: "list.bullet") { showRuns = true }
            }
            Text(memory.value.captureAlive ? "Stop the broadcast before clearing test memory."
                                           : "\(memory.value.temporaryEntries) temporary memory entries")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task { await diag.refreshRuns() }
        .sheet(isPresented: $showRuns) { TestRunsScreen(diag: diag) }
        .sheet(isPresented: $showReport) { TestRunReportSheet(diag: diag) }
        .alert("Rename test", isPresented: $renameTest) {
            TextField("Test name", text: $testNameDraft)
            Button("Save") { diag.renameCurrentTest(testNameDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Name this run", isPresented: $renameRun) {
            TextField("e.g. Video A", text: $runLabelDraft)
            Button("Save") {
                if case .saved(let meta) = diag.lastRunBanner?.result {
                    Task { await diag.renameRun(meta.id, label: runLabelDraft) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmDestructive("Clear temporary memory?", message: "Saved translation memory is not touched.",
                            isPresented: $confirmClear, button: "Clear test memory") {
            let ok = engine.clearTemporaryTestMemory()
            feedback.show(ok ? "Test memory cleared" : "Stop the broadcast first", severity: ok ? .success : .warning)
        }
    }

    @ViewBuilder private func bannerView(_ banner: Diagnostics.RunBanner) -> some View {
        switch banner.result {
        case .saved(let meta):
            VStack(alignment: .leading, spacing: Space.s) {
                StatusPill(text: "Run saved · \(TestRunText.modeTitle(meta.mode)) · \(TestRunText.duration(meta.durationSeconds))",
                           symbol: "checkmark.seal", severity: .success)
                if !meta.trimmed.isEmpty {
                    Hint("Trimmed to fit: " + meta.trimmed.joined(separator: ", "))
                }
                HStack(spacing: Space.s) {
                    SecondaryButton(title: "Rename") { runLabelDraft = meta.label; renameRun = true }
                    SecondaryButton(title: meta.pinned ? "Unpin" : "Pin") { Task { await diag.setRunPinned(meta.id, !meta.pinned) } }
                    SecondaryButton(title: "Undo") { Task { await diag.deleteRuns([meta.id]) } }
                }
            }
        case .skipped(_, let detail):
            Banner(text: detail, severity: .warning)
        case .failed(let reason):
            Banner(text: "Run not saved: \(TestRunText.reason(reason))", severity: .error)
        }
    }
}

// MARK: Latest run of each translation system

/// The headline of the Test Runs screens: the newest saved run of each system, median first.
struct LatestPerSystem: View {
    let runs: [TestRunMeta]
    private func latest(_ mode: String) -> TestRunMeta? { runs.filter { $0.mode == mode }.max { $0.endedAt < $1.endedAt } }
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(TestRunText.modes.enumerated()), id: \.element) { index, mode in
                if index > 0 { Divider() }
                let run = latest(mode)
                ListRow(title: TestRunText.modeTitle(mode),
                        subtitle: run.map { "P95 \(TestRunText.ms($0.enqueueP95Ms)) · \($0.captions) captions · \(TestRunText.duration($0.durationSeconds))" }
                            ?? "Not run yet in this test",
                        symbol: TestRunText.modeIcon(mode)) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(TestRunText.ms(run?.enqueueP50Ms)).font(.headline.monospacedDigit())
                            .foregroundStyle(run == nil ? Color.secondary : Color.primary)
                        Text("median").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: Diagnostics page (compact)

struct TestRunsPage: View {
    let diag: Diagnostics
    @Binding var showReport: Bool
    @Binding var confirmDeleteUnpinned: Bool
    @StateObject private var snapshot: ObjectSlice<Diagnostics, TestRunsSnapshot>
    @State private var showRuns = false

    init(diag: Diagnostics, showReport: Binding<Bool>, confirmDeleteUnpinned: Binding<Bool>) {
        self.diag = diag
        _showReport = showReport
        _confirmDeleteUnpinned = confirmDeleteUnpinned
        _snapshot = StateObject(wrappedValue: ObjectSlice(diag) { TestRunsSnapshot.read($0) })
    }

    var body: some View {
        let s = snapshot.value
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Test: \(s.currentName)",
                          detail: "A run is one broadcast in one translation system. Saved runs are metadata only: no screen images, recognized text or translations. Private sessions are never saved.")
            LatestPerSystem(runs: s.runs.filter { $0.testID == s.currentID })
            HStack(spacing: Space.s) {
                SecondaryButton(title: "Open test runs", symbol: "list.bullet") { showRuns = true }
                SecondaryButton(title: "Save run", symbol: "tray.and.arrow.down") { Task { await diag.saveRunNow() } }
            }
            SecondaryButton(title: "Export test report", symbol: "doc.text") { showReport = true }
            Hint(s.archive)
            if let note = s.pruneNote { Hint(note) }
            Button("Delete all unpinned runs", role: .destructive) { confirmDeleteUnpinned = true }.frame(minHeight: 44)
        }
        .task { await diag.refreshRuns() }
        .sheet(isPresented: $showRuns) { TestRunsScreen(diag: diag) }
    }
}

// MARK: Test Runs list

struct TestRunsScreen: View {
    let diag: Diagnostics
    @StateObject private var snapshot: ObjectSlice<Diagnostics, TestRunsSnapshot>
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<UUID>()
    @State private var editing = false
    @State private var detail: TestRunMeta?
    @State private var showReport = false
    @State private var confirmDelete = false

    init(diag: Diagnostics) {
        self.diag = diag
        _snapshot = StateObject(wrappedValue: ObjectSlice(diag) { TestRunsSnapshot.read($0) })
    }

    private var groups: [(id: UUID, name: String, runs: [TestRunMeta])] {
        let byTest = Dictionary(grouping: snapshot.value.runs, by: \.testID)
        return byTest.map { (id: $0.key, name: $0.value.first?.testName ?? "Test", runs: $0.value.sorted { $0.endedAt > $1.endedAt }) }
            .sorted { ($0.runs.first?.endedAt ?? .distantPast) > ($1.runs.first?.endedAt ?? .distantPast) }
    }

    var body: some View {
        let s = snapshot.value
        NavigationStack {
            List {
                if s.runs.isEmpty {
                    EmptyState(title: "No saved runs yet", symbol: "checklist",
                               message: "Start a broadcast. A run of 30 seconds or more is saved automatically when it ends.")
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        LatestPerSystem(runs: groups.first?.runs ?? [])
                    } header: {
                        Text("Latest in \(groups.first?.name ?? "this test")")
                    } footer: {
                        Text("OCR to PiP enqueue. Compare systems only inside one test, on the same content.")
                    }
                }
                ForEach(groups, id: \.id) { group in
                    Section(group.name) {
                        ForEach(group.runs) { run in
                            Button {
                                if editing {
                                    if selection.contains(run.id) { selection.remove(run.id) } else { selection.insert(run.id) }
                                } else { detail = run }
                            } label: {
                                HStack {
                                    if editing {
                                        Image(systemName: selection.contains(run.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selection.contains(run.id) ? Color.accentColor : Color.secondary)
                                            .accessibilityLabel(selection.contains(run.id) ? "Selected" : "Not selected")
                                    }
                                    TestRunRow(run: run)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { Task { await diag.deleteRuns([run.id]) } } label: { Label("Delete", systemImage: "trash") }
                                Button { Task { await diag.setRunPinned(run.id, !run.pinned) } } label: {
                                    Label(run.pinned ? "Unpin" : "Pin", systemImage: "pin")
                                }.tint(.yellow)
                            }
                        }
                    }
                }
                AdvancedSection(title: "Storage") {
                    let bytes = s.runs.reduce(0) { $0 + $1.bytes }
                    LabeledContent("Used", value: "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) of 100 MB")
                    Hint("The newest 40 unpinned runs are kept. Pinned runs are never removed automatically.")
                    if let note = s.pruneNote { Banner(text: note, severity: .warning) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Test runs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(editing ? "Done" : "Select") { editing.toggle(); selection.removeAll() }
                }
                if editing {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Export report") { showReport = true }.disabled(selection.isEmpty)
                        Spacer()
                        Button("Delete", role: .destructive) { confirmDelete = true }.disabled(selection.isEmpty)
                    }
                }
            }
            .sheet(item: $detail) { TestRunDetailView(diag: diag, run: $0) }
            .sheet(isPresented: $showReport) { TestRunReportSheet(diag: diag, preselected: selection) }
            .confirmDestructive("Delete \(selection.count) selected run(s)?", message: "Settings, translation memory and history are not changed.",
                                isPresented: $confirmDelete, button: "Delete runs") {
                let ids = Array(selection); selection.removeAll(); editing = false
                Task { await diag.deleteRuns(ids) }
            }
            .task { await diag.refreshRuns() }
        }
    }
}

// MARK: Run detail

struct TestRunDetailView: View {
    let diag: Diagnostics
    let run: TestRunMeta
    @StateObject private var snapshot: ObjectSlice<Diagnostics, TestRunsSnapshot>
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: DiagnosticSessionExport?
    @State private var others: [DiagnosticSessionExport] = []
    @State private var loadFailed = false
    @State private var label = ""
    @State private var renaming = false
    @State private var confirmDelete = false

    init(diag: Diagnostics, run: TestRunMeta) {
        self.diag = diag
        self.run = run
        _snapshot = StateObject(wrappedValue: ObjectSlice(diag) { TestRunsSnapshot.read($0) })
    }

    private var current: TestRunMeta { snapshot.value.runs.first { $0.id == run.id } ?? run }

    private static let comparedSettings = ["speed", "mode", "translationTestMode", "hybridSwitchGuard", "pixelConfirmation",
        "eventDrivenOCR", "fastOCR", "legacySharedSession", "effectiveRapidTextTracking", "effectiveJoinAdjacentText",
        "effectiveActiveTextFocus", "temporaryMemoryTest"]

    private var differing: [String] {
        guard let loaded else { return [] }
        return Self.comparedSettings.compactMap { key in
            let mine = loaded.settings[key] ?? "–"
            let values = Set(others.map { $0.settings[key] ?? "–" })
            return values.isEmpty || values == [mine] ? nil : "\(key): \(mine) (others: \(values.sorted().joined(separator: ", ")))"
        }
    }

    private func comparison(_ comparison: DiagnosticPerformanceComparison, metric: String) -> String {
        [("Median", comparison.medianChanges), ("Mean", comparison.meanChanges),
         ("P90", comparison.p90Changes), ("P95", comparison.p95Changes)]
            .compactMap { label, values in values[metric].map { label + String(format: " %+.1f%%", $0) } }
            .joined(separator: " · ")
    }

    private func number(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).minimumScaleFactor(0.7).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        let s = snapshot.value
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Space.m) {
                        TestRunRow(run: current)
                        HStack(alignment: .top, spacing: Space.m) {
                            number("Median", TestRunText.ms(current.enqueueP50Ms))
                            number("Slow tail · P95", TestRunText.ms(current.enqueueP95Ms))
                            number("Captions", "\(current.captions)")
                        }
                        if current.mixedMode {
                            Banner(text: "Mode may be mixed in this run. Do not use it for a mode comparison.", severity: .error)
                        }
                        if current.startingRAMEntries > 0 {
                            Banner(text: "Memory held \(current.startingRAMEntries) entries at start; the run is not a cold-start measurement.", severity: .warning)
                        }
                        if !current.trimmed.isEmpty {
                            Banner(text: "Trimmed to fit: " + current.trimmed.joined(separator: ", "), severity: .warning)
                        }
                    }
                } header: { Text("Result") }

                if let loaded {
                    let findings = DiagnosticIssueDetector.assess(loaded)
                    Section("Evidence-based issues") {
                        if findings.isEmpty {
                            Hint("None detected in this run.")
                        }
                        ForEach(findings) { finding in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(finding.code.replacingOccurrences(of: "_", with: " ").capitalized).font(.subheadline.weight(.semibold))
                                Text(finding.classification.capitalized + " · " + String(finding.occurrences) + " recorded")
                                    .font(.footnote).foregroundStyle(.secondary)
                                Text(finding.explanation).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Hint("Suspected issues are heuristics, not verified translation errors.")
                    }
                    if let baseline = others.filter({ $0.translationModes?.active == loaded.translationModes?.active && $0.endedAt < loaded.endedAt })
                        .max(by: { $0.endedAt < $1.endedAt }) {
                        let result = DiagnosticPerformanceComparison(baseline: baseline, current: loaded)
                        Section("Compared with the previous run of this mode") {
                            if result.comparable {
                                ForEach(result.p95Changes.keys.sorted(), id: \.self) { metric in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(metric).font(.subheadline.weight(.semibold))
                                        Text(comparison(result, metric: metric)).font(.footnote).monospacedDigit()
                                    }
                                }
                                Hint("Indicative only: different subtitle workloads can change latency.")
                            } else {
                                Hint(result.reason)
                            }
                        }
                    }
                } else if loadFailed {
                    Section { Banner(text: "This run could not be read from storage.", severity: .warning) }
                } else {
                    Section { ProgressRow(title: "Loading the run…") }
                }

                Section("Actions") {
                    Button { Task { await diag.exportTestReport(ids: [run.id]) } } label: { Label("Export report (this run)", systemImage: "doc.text") }
                        .disabled(s.exporting)
                    Button { Task { await diag.exportRunZIP(run.id) } } label: { Label("Export ZIP", systemImage: "archivebox") }
                        .disabled(s.exporting)
                    Button { label = current.label; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Button { Task { await diag.setRunPinned(run.id, !current.pinned) } } label: {
                        Label(current.pinned ? "Unpin" : "Pin", systemImage: "pin")
                    }
                    Menu {
                        Button("Current test (\(s.currentName))") {
                            Task { await diag.moveRun(run.id, toTest: s.currentID, name: s.currentName) }
                        }
                        ForEach(otherTests, id: \.id) { test in
                            Button(test.name) { Task { await diag.moveRun(run.id, toTest: test.id, name: test.name) } }
                        }
                    } label: { Label("Move to test", systemImage: "folder") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    Hint(s.archive)
                }

                AdvancedSection(title: "Run details") {
                    LabeledContent("Test", value: current.testName)
                    LabeledContent("Ended", value: current.endReason)
                    LabeledContent("Completeness", value: current.completeness)
                    LabeledContent("Device", value: "\(current.hardwareModel) · iOS \(current.systemVersion)")
                    LabeledContent("Language pair", value: current.languagePair)
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(current.bytes), countStyle: .file))
                    ForEach(differing, id: \.self) { Text($0).font(.footnote) }
                    if !differing.isEmpty { Hint("Settings above differ from other runs in this test.") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle(TestRunText.modeTitle(current.mode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .alert("Run label", isPresented: $renaming) {
                TextField("e.g. Video A", text: $label)
                Button("Save") { Task { await diag.renameRun(run.id, label: label) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmDestructive("Delete this run?", message: "Settings, translation memory and history are not changed.",
                                isPresented: $confirmDelete, button: "Delete run") {
                Task { await diag.deleteRuns([run.id]); dismiss() }
            }
            .task {
                if let result = try? await diag.runStore.load(id: run.id) { loaded = result.1 } else { loadFailed = true }
                let siblings = snapshot.value.runs.filter { $0.testID == run.testID && $0.id != run.id }.map(\.id)
                others = await diag.runStore.loadSnapshots(ids: siblings)
            }
        }
    }

    private var otherTests: [(id: UUID, name: String)] {
        var seen = Set<UUID>([snapshot.value.currentID]), result: [(id: UUID, name: String)] = []
        for item in snapshot.value.runs where seen.insert(item.testID).inserted { result.append((item.testID, item.testName)) }
        return result
    }
}

// MARK: Report sheet

/// Choose up to six saved runs and export one Markdown report. Defaults to the newest run of
/// each mode in the current test.
struct TestRunReportSheet: View {
    let diag: Diagnostics
    var preselected: Set<UUID> = []
    @StateObject private var snapshot: ObjectSlice<Diagnostics, TestRunsSnapshot>
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<UUID>()

    init(diag: Diagnostics, preselected: Set<UUID> = []) {
        self.diag = diag
        self.preselected = preselected
        _snapshot = StateObject(wrappedValue: ObjectSlice(diag) { TestRunsSnapshot.read($0) })
    }

    var body: some View {
        let s = snapshot.value
        NavigationStack {
            List {
                if s.runs.isEmpty {
                    EmptyState(title: "No saved runs", symbol: "checklist",
                               message: "Run each system for at least 30 seconds. Runs are saved automatically, or tap Save run.")
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(s.runs) { run in
                            Button {
                                if selection.contains(run.id) { selection.remove(run.id) }
                                else if selection.count < CombinedDiagnosticReport.maximumSessions { selection.insert(run.id) }
                            } label: {
                                HStack {
                                    TestRunRow(run: run)
                                    Spacer()
                                    Image(systemName: selection.contains(run.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selection.contains(run.id) ? Color.accentColor : Color.secondary)
                                        .accessibilityLabel(selection.contains(run.id) ? "Selected" : "Not selected")
                                }
                            }.buttonStyle(.plain)
                        }
                    } header: {
                        Text("\(selection.count) of \(CombinedDiagnosticReport.maximumSessions) selected")
                    } footer: {
                        Text("Metadata only: no subtitle, OCR or translated text.")
                    }
                }
                if !s.archive.isEmpty {
                    Section { Hint(s.archive) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Test report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { Task { await diag.exportTestReport(ids: orderedSelection) } }
                        .disabled(selection.isEmpty || s.exporting)
                }
            }
            .task {
                await diag.refreshRuns()
                selection = preselected.isEmpty ? Set(diag.defaultReportSelection) : Set(preselected.prefix(CombinedDiagnosticReport.maximumSessions))
            }
        }
    }

    private var orderedSelection: [UUID] {
        snapshot.value.runs.filter { selection.contains($0.id) }.map(\.id)
    }
}
