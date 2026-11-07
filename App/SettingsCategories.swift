import SwiftUI

/// Existing settings keys are used unchanged. Moving a setting here is an
/// information-architecture change, not a migration or a change of defaults.
struct TranslationFacts: Equatable {
    var active: TranslationSystem
    var pending: TranslationSystem
    var memoryCount: Int
    var warmupMs: Double?
    @MainActor static func read(_ e: TranslatorEngine) -> TranslationFacts {
        TranslationFacts(active: e.activeTranslationSystem, pending: e.pendingTranslationSystem, memoryCount: e.memoryCount, warmupMs: e.warmupLastDurationMs)
    }
}

struct TranslationSettings: View {
    @EngineHandle private var engine
    @EngineFacts(TranslationFacts.read) private var facts
    @AppStorage("translationSystem") private var translationSystem = TranslationSystem.legacy.rawValue
    @AppStorage("translateAhead") private var translateAhead = true
    @AppStorage("keepWarm") private var keepWarm = true
    @AppStorage("predictiveWarmup") private var predictiveWarmup = true
    @AppStorage("remember") private var remember = true
    @AppStorage("selectiveSpeculation") private var selectiveSpeculation = true
    @AppStorage("adaptiveSpeculation") private var adaptiveSpeculation = true
    @AppStorage("speculationConfidence") private var speculationConfidence = 0.85

    private var policySignature: String {
        "\(selectiveSpeculation)|\(adaptiveSpeculation)|\(speculationConfidence)|\(predictiveWarmup)"
    }

    var body: some View {
        List {
            Section {
                Picker("Translation system", selection: $translationSystem) {
                    ForEach(TranslationSystem.allCases, id: \.rawValue) { system in
                        Text(system.title).tag(system.rawValue)
                    }
                }
                Hint((TranslationSystem(rawValue: translationSystem) ?? .legacy).explanation)
                LabeledContent("Running now", value: facts.active.title)
                if facts.active != facts.pending {
                    LabeledContent("Starts next time", value: facts.pending.title)
                    Hint("Stop the broadcast and start it again to switch.")
                }
            } header: { Text("How translation runs") }

            Section {
                Toggle("Translate ahead", isOn: $translateAhead)
                Hint("Starts translating a promising first reading early. It only appears on screen once the text is confirmed, so captions show sooner.")
                Toggle("Remember translations", isOn: $remember)
                Hint("Reuses earlier translations of the same text, even in later sessions. \(facts.memoryCount) remembered so far.")
                NavigationLink("Manage translation memory") { MemoryManagementView() }
            } header: { Text("Speed and reuse") }

            Section {
                TranslationActivityView()
                if let ms = facts.warmupMs {
                    LabeledContent("Last warm-up", value: "\(Int(ms)) ms")
                }
            } header: { Text("Readiness") }

            AdvancedSection(title: "Warm-up", footer: "Warm-up prepares the translator before the first caption. Live translation always has priority.") {
                Toggle("Keep the translator warm", isOn: $keepWarm)
                Hint("Hybrid prepares both models, Low Latency only its own. A successful warm-up is reused for the same languages during this launch.")
                Toggle("Predict the language for warm-up", isOn: $predictiveWarmup)
                Hint("Prepares a recently confirmed language when Automatic has not decided yet.")
            }
            AdvancedSection(title: "Early translation") {
                Toggle("Selective early translation", isOn: $selectiveSpeculation)
                Hint("Skips uncertain early readings instead of wasting work. Confirmed subtitles are always translated.")
                if selectiveSpeculation {
                    VStack(alignment: .leading, spacing: 5) {
                        LabeledContent("Minimum confidence for early translation", value: "\(Int(speculationConfidence * 100))%")
                        Slider(value: $speculationConfidence, in: 0.65...0.98, step: 0.01).accessibilityLabel("Minimum confidence for early translation")
                    }
                }
                Toggle("Adapt early translation to how useful it is", isOn: $adaptiveSpeculation)
                Hint("Does less early work when predictions are not paying off. Hybrid may also switch to Low Latency recovery when Apple Default early work keeps being wasted.")
            }
            AdvancedSwitchSection()
            ResetSection(keys: [
                "translationSystem", "translateAhead", "keepWarm", "predictiveWarmup", "remember",
                "selectiveSpeculation", "adaptiveSpeculation", "speculationConfidence"
            ])
        }
        .settingsPage("Translation & memory")
        .onChange(of: translationSystem) { _, _ in engine.translationSystemChanged() }
        .onChange(of: translateAhead) { _, _ in engine.syncConfig() }
        .onChange(of: keepWarm) { _, _ in engine.powerPolicyChanged() }
        .onChange(of: policySignature) { _, _ in engine.pipelineSettingsChanged() }
    }
}

struct HistoryStorageSettings: View {
    @EngineHandle private var engine
    @EngineFacts({ $0.memoryCount }) private var memoryCount
    @AppStorage("saveHistory") private var saveHistory = true
    @AppStorage("historyRetentionDays") private var retentionDays = 0
    @AppStorage("historyCapacity") private var historyCapacity = 500
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                Toggle("Save translation history", isOn: $saveHistory)
                Picker("Keep unstarred entries", selection: $retentionDays) {
                    Text("Forever").tag(0)
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .disabled(!saveHistory)
                Picker("Keep at most", selection: $historyCapacity) {
                    Text("100").tag(100)
                    Text("250").tag(250)
                    Text("500").tag(500)
                    Text("1,000").tag(1000)
                }
                .disabled(!saveHistory)
            } header: { Text("Library history") } footer: {
                Text("Your Library is separate from remembered translations. Changing how long it is kept does not clear translation memory.")
            }

            Section {
                NavigationLink {
                    MemoryManagementView()
                } label: {
                    Label("Translation memory", systemImage: "externaldrive")
                }
                LabeledContent("Remembered units", value: "\(memoryCount)")
                NavigationLink {
                    BackupSettings()
                } label: {
                    Label("Settings backup & restore", systemImage: "square.and.arrow.up")
                }
            } header: { Text("Stored data") }

            Section {
                Button("Delete translation history", role: .destructive) { confirmClear = true }
            } header: { Text("Erase") } footer: {
                Text("Deletes everything in your Library. Translation memory stays.")
            }
            ResetSection(keys: ["saveHistory", "historyRetentionDays", "historyCapacity"])
        }
        .settingsPage("History & storage")
        .onChange(of: saveHistory) { _, enabled in
            if !enabled {
                UserDefaults.standard.removeObject(forKey: "historyData")
                UserDefaults.standard.removeObject(forKey: "screenlingo.history.v1")
            }
        }
        .onChange(of: retentionDays) { _, _ in engine.applyHistoryRetention() }
        .onChange(of: historyCapacity) { _, _ in engine.applyStorageSettings() }
        .confirmDestructive("Delete every translation in your Library?", message: "This cannot be undone.", isPresented: $confirmClear, button: "Delete Library") {
            engine.eraseHistory()
            engine.toast("History cleared")
        }
    }
}

struct DiagnosticsSettings: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @EnvironmentObject private var router: AppRouter
    @AppStorage("diagSamples") private var samples = 600
    @AppStorage("testRunSaving") private var testRunSaving = "automatic"
    @State private var confirmDeleteRuns = false
    @AppStorage("freshTranslationTest") private var freshTranslationTest = false
    @AppStorage("temporaryMemoryTest") private var temporaryMemoryTest = false

    var body: some View {
        List {
            Section {
                Button { router.present(.diagnostics) } label: {
                    Label("Open the live dashboard", systemImage: "chart.xyaxis.line")
                }.frame(minHeight: 44)
                Button { router.present(.testRuns) } label: {
                    Label("Open test runs", systemImage: "checklist")
                }.frame(minHeight: 44)
                Button {
                    Task { await engine.diag.exportZIP() }
                } label: {
                    Label(engine.diag.exportInProgress ? "Preparing the export…" : "Export everything as a ZIP",
                          systemImage: "archivebox")
                }
                .disabled(engine.diag.exportInProgress).frame(minHeight: 44)
                Hint("The ZIP has a readable summary, counters, timings and a timeline without screen text. Nothing is uploaded.")
                Text(engine.diag.archiveStatus).font(.caption).foregroundStyle(.secondary)
            } header: { Text("Review and export") }

            Section {
                Picker("Save test runs", selection: $testRunSaving) {
                    Text("Automatically").tag("automatic")
                    Text("Only when I tap Save").tag("manual")
                    Text("Off").tag("off")
                }
                Hint("A run is one broadcast in one translation system. Automatic saves runs of 30 seconds or more when they end. Only numbers are saved, never screen text. Private sessions are never saved.")
                let storage = engine.diag.testRuns.reduce(0) { $0 + $1.bytes }
                LabeledContent("Saved runs", value: "\(engine.diag.testRuns.count) · \(ByteCountFormatter.string(fromByteCount: Int64(storage), countStyle: .file))")
                Button("Delete all unpinned runs", role: .destructive) { confirmDeleteRuns = true }
                    .disabled(engine.diag.testRuns.allSatisfy { $0.pinned }).frame(minHeight: 44)
                    .confirmDestructive("Delete all unpinned test runs?", message: "Pinned runs, translation memory, Library and settings are not changed.",
                                        isPresented: $confirmDeleteRuns, button: "Delete unpinned runs") {
                        Task { await engine.diag.deleteAllUnpinnedRuns() }
                    }
            } header: { Text("Test runs") }

            AdvancedSection(title: "Collection", footer: "Detailed collection can use extra memory and processing.") {
                DiagnosticsCollectionControls()
                Picker("Samples per chart", selection: $samples) {
                    Text("300").tag(300)
                    Text("600").tag(600)
                    Text("1,200").tag(1200)
                }
            }
            AdvancedSection(title: "Controlled comparisons", footer: "Changing a test mode starts a new diagnostic session so results are not mixed. Turn these off after testing.") {
                Toggle("Fresh requests only", isOn: Binding(get: { freshTranslationTest }, set: { enabled in
                    freshTranslationTest = enabled
                    if enabled { temporaryMemoryTest = false }
                    engine.testModeSettingsChanged()
                }))
                Hint("Ignores remembered translations and early translation so every request is new. Saved results are not deleted.")
                Toggle("Temporary-memory test", isOn: Binding(get: { temporaryMemoryTest }, set: { enabled in
                    temporaryMemoryTest = enabled
                    if enabled { freshTranslationTest = false }
                    engine.testModeSettingsChanged()
                }))
                Hint("Uses a throwaway cache in memory. Saved translations and your Library are untouched. It is lost when the app closes.")
                if temporaryMemoryTest {
                    LabeledContent("Temporary entries", value: "\(engine.temporaryMemoryEntries)")
                }
                NavigationLink {
                    PipelineSimulatorView()
                } label: {
                    Label("Pipeline simulator", systemImage: "point.3.connected.trianglepath.dotted")
                }
                Hint("Plays out settings and timing on paper. It does not use the real translation model.")
                Button("Reset diagnostic counters") {
                    engine.resetDiagnostics()
                    engine.toast("Counters reset")
                }
            }
            AdvancedSwitchSection()
            ResetSection(keys: ["diagSamples", "testRunSaving", "freshTranslationTest", "temporaryMemoryTest"])
        }
        .settingsPage("Diagnostics & tests")
        .task { await engine.diag.refreshRuns() }
        .onChange(of: samples) { _, _ in engine.applyStorageSettings() }
    }
}
