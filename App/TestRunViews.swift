// ScreenLingo – App – Test Runs (2.1.0)
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
    /// 2.2.1 (U1): the sentence and severity shown after every Save, whichever screen it came from.
    static func saveMessage(_ result: TestRunSaveResult) -> (String, Severity) {
        switch result {
        case .saved(let meta):
            return (meta.noTiming ? "Run saved, but without timing (Detailed collection was off)"
                                  : "Run saved · \(modeTitle(meta.mode)) · \(duration(meta.durationSeconds))",
                    meta.noTiming ? .warning : .success)
        case .skipped(_, let detail): return (detail, .warning)
        case .failed(let reason): return ("Run not saved: \(Self.reason(reason))", .error)
        }
    }
    static func modeTitle(_ mode: String) -> String {
        switch mode {
        case "legacy": return "Legacy"
        case "lowLatency": return "Low Latency"
        default: return "Unknown mode"
        }
    }
    static func modeIcon(_ mode: String) -> String {
        switch mode {
        case "legacy": return "clock.arrow.circlepath"
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
    /// 2.5.0: the modes a test compares.
    static let modes = ["legacy", "lowLatency"]
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
        if run.noTiming { items.append(("No timing", .orange)) }
        if let warm = run.thermalRangeLabel { items.append((warm, .orange)) }
        return items
    }

    var body: some View {
        if !items.isEmpty {
            HStack(spacing: 4) {
                ForEach(items, id: \.0) { item in
                    Text(item.0).font(.caption.weight(.semibold))
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
        HStack(alignment: .top, spacing: KitSpace.row) {
            Image(systemName: TestRunText.modeIcon(run.mode)).font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: KitRadius.small, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: KitSpace.unit) {
                HStack(alignment: .firstTextBaseline) {
                    Text(TestRunText.modeTitle(run.mode) + (run.label.isEmpty ? "" : " · " + run.label)).font(.headline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(TestRunText.ms(run.enqueueP50Ms)).font(.headline.monospacedDigit())
                        Text("median").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("\(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(TestRunText.duration(run.durationSeconds)) · \(run.captions) captions")
                    .font(.caption).foregroundStyle(.secondary)
                Text("P95 \(TestRunText.ms(run.enqueueP95Ms)) · thermal \(run.thermal)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                RunBadges(run: run)
            }
        }.padding(.vertical, KitSpace.unit)
    }
}

// MARK: Test card (shown in the Live Test sheet)


// MARK: Diagnostics page (compact)

struct TestRunsPage: View {
    let diag: Diagnostics
    @Binding var showReport: Bool
    @Binding var confirmDeleteUnpinned: Bool
    @StateObject private var snapshot: ObjectSlice<Diagnostics, TestRunsSnapshot>
    @EnvironmentObject private var feedback: FeedbackCenter
    @State private var showRuns = false

    init(diag: Diagnostics, showReport: Binding<Bool>, confirmDeleteUnpinned: Binding<Bool>) {
        self.diag = diag
        _showReport = showReport
        _confirmDeleteUnpinned = confirmDeleteUnpinned
        _snapshot = StateObject(wrappedValue: ObjectSlice(diag) { TestRunsSnapshot.read($0) })
    }

    var body: some View {
        let s = snapshot.value
        VStack(alignment: .leading, spacing: KitSpace.row) {
            Text("Test: \(s.currentName)").font(.headline)
            Text("A run is one broadcast in one translation system. Saved runs are metadata only: no screen images, recognized text or translations. Private sessions are never saved.")
                .font(.footnote).foregroundStyle(.secondary)
            LatestPerSystem(runs: s.runs.filter { $0.testID == s.currentID })
            HStack(spacing: KitSpace.tight) {
                SecondaryButton(title: "Open test runs", symbol: "list.bullet") { showRuns = true }
                SecondaryButton(title: "Save run", symbol: "tray.and.arrow.down") {
                    Task {
                        let result = await diag.saveRunNow()
                        let message = TestRunText.saveMessage(result)
                        feedback.show(message.0, severity: message.1)
                    }
                }
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
                    LabeledContent("Used", value: "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                    Hint("Runs are kept until you delete them. Pinned runs are never removed by Delete all unpinned.")
                    if let note = s.pruneNote { Banner(text: note, severity: .warning) }
                }
            }
            .settingsPage("Test runs")
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

