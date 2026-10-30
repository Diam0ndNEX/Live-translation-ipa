import SwiftUI

/// Existing settings keys are used unchanged. Moving a setting here is an
/// information-architecture change, not a migration or a change of defaults.
struct TranslationSettings: View {
    @EnvironmentObject private var engine: TranslatorEngine
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
                Text((TranslationSystem(rawValue: translationSystem) ?? .legacy).explanation)
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Active system", value: engine.activeTranslationSystem.title)
                if engine.activeTranslationSystem != engine.pendingTranslationSystem {
                    LabeledContent("Next capture session", value: engine.pendingTranslationSystem.title)
                    Text("Stop and restart capture to apply the selected system.").font(.footnote)
                }
            } header: { Text("Translation system") }

            Section {
                Toggle("Translate ahead", isOn: $translateAhead)
                Text("Starts translating a promising first reading before OCR confirms it; shows results only after confirmation.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Keep the translator warm", isOn: $keepWarm)
                Text("Hybrid initially exercises Apple default and low latency; Low Latency exercises only low latency. Successful warm-ups are reused per pair and strategy this launch. Interrupted attempts may retry after a short cooldown. No periodic sample loop; live capture has priority.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Predict the language for warm-up", isOn: $predictiveWarmup)
                Text("Prepares a recently confirmed source language when Automatic hasn't resolved one yet. Live translation always has priority.")
                    .font(.footnote).foregroundStyle(.secondary)
                TranslationActivityView()
                if let ms = engine.warmupLastDurationMs {
                    LabeledContent("Last warm-up", value: "\(Int(ms)) ms")
                }
            } header: { Text("Model readiness") }

            Section {
                Toggle("Selective early translation", isOn: $selectiveSpeculation)
                Text("Skip uncertain early candidates instead of wasting model work. Confirmed subtitles always remain eligible.")
                    .font(.footnote).foregroundStyle(.secondary)
                if selectiveSpeculation {
                    VStack(alignment: .leading, spacing: 5) {
                        LabeledContent("Early OCR confidence", value: "\(Int(speculationConfidence * 100))%")
                        Slider(value: $speculationConfidence, in: 0.65...0.98, step: 0.01)
                    }
                }
                Toggle("Adapt early translation to usefulness", isOn: $adaptiveSpeculation)
                Text("Reduces early model work when predictions are not useful. Hybrid also temporarily switches to direct Low Latency recovery when Apple Default speculation repeatedly wastes resources.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Translation scheduling") }

            Section {
                Toggle("Remember translations", isOn: $remember)
                LabeledContent("Remembered units", value: "\(engine.memoryCount)")
                NavigationLink("Manage translation memory") { MemoryManagementView() }
                Text("Reuses compatible translations across sessions. Managing memory does not delete existing entries automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Reuse & memory") }

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
    @EnvironmentObject private var engine: TranslatorEngine
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
                Picker("Maximum history entries", selection: $historyCapacity) {
                    Text("100").tag(100)
                    Text("250").tag(250)
                    Text("500").tag(500)
                    Text("1,000").tag(1000)
                }
                .disabled(!saveHistory)
            } header: { Text("Translation history") } footer: {
                Text("History is separate from remembered translations. Changing history retention does not clear Translation Memory.")
            }

            Section {
                NavigationLink {
                    MemoryManagementView()
                } label: {
                    Label("Translation memory", systemImage: "externaldrive")
                }
                LabeledContent("Remembered units", value: "\(engine.memoryCount)")
                NavigationLink {
                    BackupSettings()
                } label: {
                    Label("Settings backup & restore", systemImage: "square.and.arrow.up")
                }
            } header: { Text("Stored data") }

            Section {
                Button("Delete translation history", role: .destructive) { confirmClear = true }
            } header: { Text("Erase") } footer: {
                Text("Deletes saved History entries, not the translation memory database.")
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
        .confirmationDialog("Delete every translation in History?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete history", role: .destructive) {
                engine.eraseHistory()
                engine.toast("History cleared")
            }
        }
    }
}

struct DiagnosticsSettings: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @Environment(\.selectTab) private var selectTab
    @AppStorage("diagSamples") private var samples = 600
    @AppStorage("persistDiagnosticSessions") private var persistSessions = false
    @AppStorage("freshTranslationTest") private var freshTranslationTest = false
    @AppStorage("temporaryMemoryTest") private var temporaryMemoryTest = false

    var body: some View {
        List {
            Section {
                LabeledContent("Session started", value: engine.diag.started.formatted(date: .abbreviated, time: .shortened))
                Button {
                    selectTab(3)
                } label: {
                    Label("Open live diagnostics dashboard", systemImage: "chart.xyaxis.line")
                }
                Button {
                    Task { await engine.diag.exportZIP() }
                } label: {
                    Label(engine.diag.exportInProgress ? "Preparing diagnostic ZIP…" : "Export complete diagnostic ZIP",
                          systemImage: "archivebox")
                }
                .disabled(engine.diag.exportInProgress)
                Text("ZIP v3 includes a readable summary, full-session counters, timed intervals, latency percentiles, a privacy-safe event timeline and experiment settings. Nothing is uploaded automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(engine.diag.archiveStatus).font(.caption).foregroundStyle(.secondary)
            } header: { Text("Review & export") }
            Section {
                DiagnosticsCollectionControls()
                Toggle("Keep diagnostic sessions between launches", isOn: $persistSessions)
                Text("Controls how much numeric performance evidence is retained; detailed collection can use extra memory and CPU.")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("Samples per chart", selection: $samples) {
                    Text("300").tag(300)
                    Text("600").tag(600)
                    Text("1,200").tag(1200)
                }
            } header: { Text("Diagnostics collection") }

            Section {
                Toggle("Fresh requests only", isOn: Binding(get: { freshTranslationTest }, set: { enabled in
                    freshTranslationTest = enabled
                    if enabled { temporaryMemoryTest = false }
                    engine.testModeSettingsChanged()
                }))
                Text("For controlled comparisons, bypasses translation-memory reuse and pre-translation without deleting saved results. Turn off after testing.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Temporary-memory test", isOn: Binding(get: { temporaryMemoryTest }, set: { enabled in
                    temporaryMemoryTest = enabled
                    if enabled { freshTranslationTest = false }
                    engine.testModeSettingsChanged()
                }))
                Text("Uses an isolated RAM cache and your speculation settings. Saved translations and history are untouched. The cache survives app switches and toggle changes, and is lost when the app process terminates.")
                    .font(.footnote).foregroundStyle(.secondary)
                if temporaryMemoryTest {
                    LabeledContent("Temporary entries", value: "\(engine.temporaryMemoryEntries)")
                }
                Text("Changing test mode starts a new diagnostic session so results are not mixed.")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink {
                    PipelineSimulatorView()
                } label: {
                    Label("Pipeline simulator", systemImage: "point.3.connected.trianglepath.dotted")
                }
                Text("Simulates settings and timing assumptions without using the real on-device translation model.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Testing tools") }

            Section {
                Button("Reset diagnostic counters") {
                    engine.resetDiagnostics()
                    engine.toast("Counters reset")
                }
            }
            ResetSection(keys: ["diagSamples", "persistDiagnosticSessions", "freshTranslationTest", "temporaryMemoryTest"])
        }
        .settingsPage("Diagnostics & tests")
        .onChange(of: persistSessions) { _, _ in engine.diagnosticsSettingsChanged() }
        .onChange(of: samples) { _, _ in engine.applyStorageSettings() }
    }
}
