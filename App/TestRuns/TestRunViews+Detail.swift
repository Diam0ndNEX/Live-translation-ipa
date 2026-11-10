import SwiftUI

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

    // 2.2.1 (D3): the same list the comparison uses, so the screen and the report agree on what "comparable" means.
    private static let comparedSettings = DiagnosticPerformanceComparison.cohortKeys

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

    var body: some View {
        let s = snapshot.value
        NavigationStack {
            List {
                // One answer first: the run's typical delay, then its slow tail and caption count (§13.5.8).
                Section {
                    StatLine(value: current.enqueueP50Ms.map { "\(Int($0)) ms" },
                             caption: "Typical delay · \(TestRunText.modeTitle(current.mode))",
                             secondary: [current.enqueueP95Ms.map { "P95 \(Int($0)) ms" } ?? "P95 –",
                                         "\(current.captions) captions",
                                         TestRunText.duration(current.durationSeconds)],
                             emptyCaption: "No complete captions in this run")
                    TestRunRow(run: current)
                    if current.mixedMode {
                        Label("Mode may be mixed in this run. Don't use it for a mode comparison.", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red).font(.subheadline)
                    }
                    if current.startingRAMEntries > 0 {
                        Label("Memory held \(current.startingRAMEntries) entries at start; not a cold-start measurement.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.subheadline)
                    }
                    if !current.trimmed.isEmpty {
                        Label("Trimmed to fit: " + current.trimmed.joined(separator: ", "), systemImage: "scissors")
                            .foregroundStyle(.orange).font(.subheadline)
                    }
                }

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
            .settingsPage(TestRunText.modeTitle(current.mode))
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
            .settingsPage("Test report")
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
