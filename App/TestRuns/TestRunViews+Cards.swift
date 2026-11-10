import SwiftUI

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
        VStack(alignment: .leading, spacing: KitSpace.row) {
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
                Banner(text: "Saving test runs is off. Turn it on in Settings > Diagnostics settings.", severity: .warning)
            }
            // Mode · Median · P95 · Captions, newest run per mode (§13.5.4).
            VStack(alignment: .leading, spacing: KitSpace.tight) {
                Text("Three systems, same content").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: KitSpace.row, verticalSpacing: KitSpace.tight) {
                    GridRow {
                        Text("Mode"); Text("Median"); Text("P95"); Text("Captions")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(TestRunText.modes, id: \.self) { mode in
                        let run = saved(mode)
                        GridRow {
                            Label(TestRunText.modeTitle(mode), systemImage: run != nil ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(run != nil ? Color.primary : Color.secondary)
                            Text(run.map { TestRunText.ms($0.enqueueP50Ms) } ?? "–")
                            Text(run.map { TestRunText.ms($0.enqueueP95Ms) } ?? "–")
                            Text(run.map { "\($0.captions)" } ?? "–")
                        }
                        .font(.subheadline.monospacedDigit())
                        .accessibilityElement(children: .combine)
                    }
                }
                if let next = nextMode {
                    Text("Next: run \(TestRunText.modeTitle(next)) on the same content.").font(.footnote).foregroundStyle(.secondary)
                }
            }

            if runsSlice.value.activeStarted != nil, let run = diag.activeRun {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    StatusPill(text: "\(diag.isRunPaused ? "Paused" : "Recording") \(TestRunText.modeTitle(run.mode)) · \(TestRunText.duration(Swift.max(0, context.date.timeIntervalSince(run.startedAt) - diag.pausedSeconds))) · \(runsSlice.value.captionCount) captions",
                               symbol: diag.isRunPaused ? "pause.circle" : "record.circle", severity: diag.isRunPaused ? .warning : .error)
                }
            }
            // 2.2.1 (U1): the result of a Save stays visible while a run is recording (it used to be hidden then).
            if runsSlice.value.bannerID != nil, let banner = diag.lastRunBanner {
                bannerView(banner)
            }

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    Task {
                        let result = await diag.saveRunNow()
                        let message = TestRunText.saveMessage(result)
                        feedback.show(message.0, severity: message.1)
                    }
                    Feedback.tap()
                } label: { LensRow(title: "Save this run", symbol: "tray.and.arrow.down") }
                Divider()
                Button { confirmClear = true } label: { LensRow(title: "Clear test memory", symbol: "eraser") }
                    .disabled(memory.value.captureAlive)
                Divider()
                Button { showReport = true } label: { LensRow(title: "Export report", symbol: "doc.text") }
                Divider()
                Button { showRuns = true } label: { LensRow(title: "All test runs", symbol: "list.bullet") }
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
            VStack(alignment: .leading, spacing: KitSpace.tight) {
                StatusPill(text: "Run saved · \(TestRunText.modeTitle(meta.mode)) · \(TestRunText.duration(meta.durationSeconds))",
                           symbol: "checkmark.seal", severity: .success)
                if !meta.trimmed.isEmpty {
                    Hint("Trimmed to fit: " + meta.trimmed.joined(separator: ", "))
                }
                HStack(spacing: KitSpace.tight) {
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
    // 2.2.1 (D1): a run without timing has no median, so it never stands in for a system's latest result.
    private func latest(_ mode: String) -> TestRunMeta? { runs.filter { $0.mode == mode && !$0.noTiming }.max { $0.endedAt < $1.endedAt } }
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
