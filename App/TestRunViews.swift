import SwiftUI

// Test Runs UI (v2.0.0 build 84, spec §11.6): Test card, Test Runs list and detail, report sheet.

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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: TestRunText.modeIcon(run.mode)).frame(width: 24).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(TestRunText.modeTitle(run.mode) + (run.label.isEmpty ? "" : " · " + run.label))
                    .font(.subheadline.weight(.semibold))
                Text("\(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(TestRunText.duration(run.durationSeconds)) · \(run.captions) captions")
                    .font(.caption).foregroundStyle(.secondary)
                Text("OCR→PiP median \(TestRunText.ms(run.enqueueP50Ms)) · P95 \(TestRunText.ms(run.enqueueP95Ms)) · thermal \(run.thermal)")
                    .font(.caption2).foregroundStyle(.secondary)
                RunBadges(run: run)
            }
        }
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
    @ObservedObject var diag: Diagnostics
    let engine: TranslatorEngine
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
        _memory = StateObject(wrappedValue: EngineSlice(engine) { TestMemorySnapshot.read($0) })
    }

    private var currentRuns: [TestRunMeta] { diag.testRuns.filter { $0.testID == diag.currentTestID } }
    private func saved(_ mode: String) -> TestRunMeta? {
        currentRuns.filter { $0.mode == mode }.max { $0.endedAt < $1.endedAt }
    }
    private var nextMode: String? { TestRunText.modes.first { saved($0) == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Button { testNameDraft = diag.currentTestName; renameTest = true } label: {
                    Label(diag.currentTestName, systemImage: "pencil").font(.headline).frame(minHeight: 44)
                }.buttonStyle(.plain)
                Spacer()
                Button("New test") { diag.startNewTest(); Feedback.tap() }.frame(minHeight: 44)
            }
            if privateSession {
                Banner(text: "Private session: runs are not saved.", severity: .warning)
            } else if saving == "off" {
                Banner(text: "Saving test runs is off. Turn it on in Settings > Diagnostics & tests.", severity: .warning)
            }
            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader(title: "Three systems, same content")
                ForEach(TestRunText.modes, id: \.self) { mode in
                    HStack {
                        Image(systemName: saved(mode) != nil ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(saved(mode) != nil ? Palette.success : Color.secondary)
                            .accessibilityLabel(saved(mode) != nil ? "Saved" : "Not saved yet")
                        Text(TestRunText.modeTitle(mode)).font(.body)
                        Spacer()
                        if let run = saved(mode) {
                            Text("\(TestRunText.duration(run.durationSeconds)) · \(TestRunText.ms(run.enqueueP50Ms))")
                                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }.frame(minHeight: 36)
                }
                if let next = nextMode {
                    Text("Next: \(TestRunText.modeTitle(next))").font(.footnote).foregroundStyle(.secondary)
                }
            }.infoCard()

            if let run = diag.activeRun {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    StatusPill(text: "Recording \(TestRunText.modeTitle(run.mode)) · \(TestRunText.duration(context.date.timeIntervalSince(run.startedAt))) · \(diag.s.enqueuedCandidateFrames) captions",
                               symbol: "record.circle", severity: .error)
                }
            } else if let banner = diag.lastRunBanner {
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

// MARK: Diagnostics page (compact)

struct TestRunsPage: View {
    @ObservedObject var diag: Diagnostics
    @Binding var showReport: Bool
    @Binding var confirmDeleteUnpinned: Bool
    @State private var showRuns = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test: \(diag.currentTestName)").font(.subheadline.weight(.semibold))
            Text("A run is one broadcast in one translation system. Saved runs are metadata only: no screen images, recognized text or translations. Private sessions are never saved.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { showRuns = true } label: { Label("Open test runs", systemImage: "list.bullet") }
                Button { Task { await diag.saveRunNow() } } label: { Label("Save run", systemImage: "tray.and.arrow.down") }
            }.buttonStyle(.bordered)
            Button { showReport = true } label: { Label("Export test report", systemImage: "doc.text") }
            Text(diag.archiveStatus).font(.caption).foregroundStyle(.secondary)
            ForEach(diag.testRuns.prefix(5)) { run in TestRunRow(run: run) }
            if let note = diag.runPruneNote { Text(note).font(.caption2).foregroundStyle(.secondary) }
            Button("Delete all unpinned runs", role: .destructive) { confirmDeleteUnpinned = true }
        }
        .task { await diag.refreshRuns() }
        .sheet(isPresented: $showRuns) { TestRunsScreen(diag: diag) }
    }
}

// MARK: Test Runs list

struct TestRunsScreen: View {
    @ObservedObject var diag: Diagnostics
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<UUID>()
    @State private var editing = false
    @State private var detail: TestRunMeta?
    @State private var showReport = false
    @State private var confirmDelete = false

    private var groups: [(id: UUID, name: String, runs: [TestRunMeta])] {
        let byTest = Dictionary(grouping: diag.testRuns, by: \.testID)
        return byTest.map { (id: $0.key, name: $0.value.first?.testName ?? "Test", runs: $0.value.sorted { $0.endedAt > $1.endedAt }) }
            .sorted { ($0.runs.first?.endedAt ?? .distantPast) > ($1.runs.first?.endedAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                if diag.testRuns.isEmpty {
                    EmptyState(title: "No saved runs yet", symbol: "checklist",
                               message: "Start a broadcast. A run of 30 seconds or more is saved automatically when it ends.")
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
                Section {
                    let bytes = diag.testRuns.reduce(0) { $0 + $1.bytes }
                    Text("Storage: \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) of 100 MB · newest 40 unpinned runs kept")
                        .font(.caption).foregroundStyle(.secondary)
                    if let note = diag.runPruneNote { Text(note).font(.caption).foregroundStyle(.orange) }
                }
            }
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
            .confirmationDialog("Delete \(selection.count) selected run(s)? Settings, translation memory and history are not changed.",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete runs", role: .destructive) {
                    let ids = Array(selection); selection.removeAll(); editing = false
                    Task { await diag.deleteRuns(ids) }
                }
            }
            .task { await diag.refreshRuns() }
        }
    }
}

// MARK: Run detail

struct TestRunDetailView: View {
    @ObservedObject var diag: Diagnostics
    let run: TestRunMeta
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: DiagnosticSessionExport?
    @State private var others: [DiagnosticSessionExport] = []
    @State private var loadFailed = false
    @State private var label = ""
    @State private var renaming = false
    @State private var confirmDelete = false

    private var current: TestRunMeta { diag.testRuns.first { $0.id == run.id } ?? run }

    private static let comparedSettings = ["speed", "mode", "translationTestMode", "hybridSwitchGuard", "pixelConfirmation",
        "eventDrivenOCR", "fastOCR", "legacySharedSession", "effectiveRapidTextTracking", "effectiveJoinAdjacentText",
        "effectiveActiveTextFocus", "temporaryMemoryTest"]

    private var differing: [String] {
        guard let snapshot else { return [] }
        return Self.comparedSettings.compactMap { key in
            let mine = snapshot.settings[key] ?? "–"
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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TestRunRow(run: current)
                    LabeledContent("Test", value: current.testName)
                    LabeledContent("Ended", value: current.endReason)
                    LabeledContent("Completeness", value: current.completeness)
                    LabeledContent("Device", value: "\(current.hardwareModel) · iOS \(current.systemVersion)")
                    LabeledContent("Language pair", value: current.languagePair)
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(current.bytes), countStyle: .file))
                    if current.mixedMode {
                        Label("Mode may be mixed in this run. Do not use it for a mode comparison.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    if current.startingRAMEntries > 0 {
                        Label("Memory held \(current.startingRAMEntries) entries at start; the run is not a cold-start measurement.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if !current.trimmed.isEmpty {
                        Label("Trimmed to fit: " + current.trimmed.joined(separator: ", "), systemImage: "scissors")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } header: { Text("Summary") }

                if !differing.isEmpty {
                    Section("Settings that differ from other runs in this test") {
                        ForEach(differing, id: \.self) { Text($0).font(.caption) }
                    }
                }

                if let snapshot {
                    let findings = DiagnosticIssueDetector.assess(snapshot)
                    Section("Evidence-based issues") {
                        if findings.isEmpty {
                            Text("None detected in this run.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(findings) { finding in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(finding.code.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption.weight(.semibold))
                                Text(finding.classification.capitalized + " · " + String(finding.occurrences) + " recorded")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(finding.explanation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("Suspected issues are heuristics, not verified translation errors.").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let baseline = others.filter({ $0.translationModes?.active == snapshot.translationModes?.active && $0.endedAt < snapshot.endedAt })
                        .max(by: { $0.endedAt < $1.endedAt }) {
                        let result = DiagnosticPerformanceComparison(baseline: baseline, current: snapshot)
                        Section("Compared with the previous run of this mode") {
                            if result.comparable {
                                ForEach(result.p95Changes.keys.sorted(), id: \.self) { metric in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(metric).font(.caption.weight(.semibold))
                                        Text(comparison(result, metric: metric)).font(.caption).monospacedDigit()
                                    }
                                }
                                Text("Indicative only: different subtitle workloads can change latency.").font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text(result.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if loadFailed {
                    Section { Text("This run could not be read from storage.").foregroundStyle(.orange) }
                } else {
                    Section { ProgressView() }
                }

                Section("Actions") {
                    Button { Task { await diag.exportTestReport(ids: [run.id]) } } label: { Label("Export report (this run)", systemImage: "doc.text") }
                        .disabled(diag.exportInProgress)
                    Button { Task { await diag.exportRunZIP(run.id) } } label: { Label("Export ZIP", systemImage: "archivebox") }
                        .disabled(diag.exportInProgress)
                    Button { label = current.label; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Button { Task { await diag.setRunPinned(run.id, !current.pinned) } } label: {
                        Label(current.pinned ? "Unpin" : "Pin", systemImage: "pin")
                    }
                    Menu {
                        Button("Current test (\(diag.currentTestName))") {
                            Task { await diag.moveRun(run.id, toTest: diag.currentTestID, name: diag.currentTestName) }
                        }
                        ForEach(otherTests, id: \.id) { test in
                            Button(test.name) { Task { await diag.moveRun(run.id, toTest: test.id, name: test.name) } }
                        }
                    } label: { Label("Move to test", systemImage: "folder") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    Text(diag.archiveStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(TestRunText.modeTitle(current.mode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .alert("Run label", isPresented: $renaming) {
                TextField("e.g. Video A", text: $label)
                Button("Save") { Task { await diag.renameRun(run.id, label: label) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this run? Settings, translation memory and history are not changed.",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete run", role: .destructive) { Task { await diag.deleteRuns([run.id]); dismiss() } }
            }
            .task {
                if let loaded = try? await diag.runStore.load(id: run.id) { snapshot = loaded.1 } else { loadFailed = true }
                let siblings = diag.testRuns.filter { $0.testID == run.testID && $0.id != run.id }.map(\.id)
                others = await diag.runStore.loadSnapshots(ids: siblings)
            }
        }
    }

    private var otherTests: [(id: UUID, name: String)] {
        var seen = Set<UUID>([diag.currentTestID]), result: [(id: UUID, name: String)] = []
        for item in diag.testRuns where seen.insert(item.testID).inserted { result.append((item.testID, item.testName)) }
        return result
    }
}

// MARK: Report sheet

/// Choose up to six saved runs and export one Markdown report. Defaults to the newest run of
/// each mode in the current test.
struct TestRunReportSheet: View {
    @ObservedObject var diag: Diagnostics
    var preselected: Set<UUID> = []
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<UUID>()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if diag.testRuns.isEmpty {
                        Text("No saved runs. Run each mode for at least 30 seconds; runs are saved automatically (or tap Save run).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(diag.testRuns) { run in
                        Button {
                            if selection.contains(run.id) { selection.remove(run.id) }
                            else if selection.count < CombinedDiagnosticReport.maximumSessions { selection.insert(run.id) }
                        } label: {
                            HStack {
                                TestRunRow(run: run)
                                Spacer()
                                Image(systemName: selection.contains(run.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection.contains(run.id) ? Color.accentColor : Color.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                } footer: {
                    Text("Up to \(CombinedDiagnosticReport.maximumSessions) runs. Metadata only: no subtitle, OCR or translated text.")
                }
                if !diag.archiveStatus.isEmpty {
                    Section { Text(diag.archiveStatus).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Test report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { Task { await diag.exportTestReport(ids: orderedSelection) } }
                        .disabled(selection.isEmpty || diag.exportInProgress)
                }
            }
            .task {
                await diag.refreshRuns()
                selection = preselected.isEmpty ? Set(diag.defaultReportSelection) : Set(preselected.prefix(CombinedDiagnosticReport.maximumSessions))
            }
        }
    }

    private var orderedSelection: [UUID] {
        diag.testRuns.filter { selection.contains($0.id) }.map(\.id)
    }
}
