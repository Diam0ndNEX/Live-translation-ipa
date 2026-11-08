// ScreenLingo – App – Translate: Session sheet (2.1.0, spec §13.5.1; replaces the Status sheet)
// State sentence, timer, counts, pause, window, private session, pause after, clear, test pair, copy report.
// Technical timing lives in Diagnostics only.
import SwiftUI

struct SessionSheet: View {
    let engine: TranslatorEngine
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var feedback: FeedbackCenter
    @Environment(\.dismiss) private var dismiss
    @StateObject private var slice: EngineSlice<SessionFacts>
    @AppStorage("sessionLimit") private var limit = 0
    @AppStorage("privateSession") private var privateSession = false
    @State private var confirmClear = false

    init(engine: TranslatorEngine) {
        self.engine = engine
        _slice = StateObject(wrappedValue: EngineSlice(engine) { SessionFacts.read($0) })
    }

    private var facts: SessionFacts { slice.value }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: KitSpace.tight) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            PhaseHeader(phase: facts.phase,
                                        elapsed: facts.started.map { context.date.timeIntervalSince($0) },
                                        mode: facts.modeName)
                        }
                        Text(facts.sentence).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, KitSpace.unit)
                    if facts.phase.isSession {
                        HStack(spacing: KitSpace.row) {
                            StartButton(live: true).scaleEffect(0.5).frame(width: 88, height: 88)
                            Text("Stop the broadcast").font(.body)
                        }
                    }
                }
                Section("This session") {
                    LabeledContent("Translations", value: "\(facts.translations)")
                    LabeledContent("Characters", value: "\(facts.characters)")
                    Toggle("Pause translating", isOn: Binding(get: { facts.paused }, set: { engine.paused = $0 }))
                    Button(facts.pipActive ? "Close floating window" : "Show floating window") {
                        facts.pipActive ? engine.pip.stop() : engine.startPiP()
                    }
                    Toggle(isOn: $privateSession) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Private session")
                            Text("Nothing is added to history or saved memory.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Pause after", selection: $limit) {
                        Text("Never").tag(0); Text("15 minutes").tag(15); Text("30 minutes").tag(30); Text("1 hour").tag(60)
                    }
                    Button("Restart session timer") { engine.resetSession() }
                }
                Section("If something is wrong") {
                    Button("Test the language pair") { engine.runTest() }
                    Button("Refresh language packs") { Task { await engine.refreshStatus() } }
                    Button("Copy a report") {
                        UIPasteboard.general.string = engine.diag.report(engine: engine)
                        feedback.show("Report copied", severity: .success)
                    }
                    Button("Clear the current caption", role: .destructive) { confirmClear = true }
                        .confirmationDialog("Clear the current caption?", isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("Clear caption", role: .destructive) { engine.clearOutput() }
                        }
                }
                Section {
                    Button { router.present(.test) } label: { LensRow(title: "Test the three modes", symbol: "checklist") }
                    Button { router.go(.diagnostics) } label: { LensRow(title: "Open Diagnostics", symbol: "waveform.path.ecg") }
                }
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct SessionFacts: Equatable {
    var phase: SessionPhase
    var started: Date?
    var modeName: String
    var translations: Int
    var characters: Int
    var paused: Bool
    var pipActive: Bool
    var captureTitle: String

    /// One plain sentence about the state.
    var sentence: String {
        switch phase {
        case .idle: return "Nothing is being captured. Start from the Translate tab."
        case .starting: return "Waiting for the first frame from the broadcast."
        case .live: return "Reading your screen and translating."
        case .paused: return "Capture continues; translation is paused."
        case .attention(let reason): return "\(reason.message). \(captureTitle)."
        }
    }

    @MainActor static func read(_ e: TranslatorEngine) -> SessionFacts {
        let pair = PairSnapshot.read(e)
        return SessionFacts(
            phase: SessionPhase.derive(capture: e.captureStatus, alive: e.captureAlive, paused: e.paused, pipActive: e.pipActive,
                                       packReady: pair.packState != .needsDownload && pair.packState != .unsupported),
            started: e.sessionStarted, modeName: e.activeTranslationSystem.shortName,
            translations: e.sessionTranslations, characters: e.sessionCharacters,
            paused: e.paused, pipActive: e.pipActive, captureTitle: e.captureStatus.title)
    }
}

/// The §11 test card in its own sheet (same TestCard and engine calls as before).
struct TestSheet: View {
    let engine: TranslatorEngine
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { TestCard(diag: engine.diag, engine: engine).padding(KitSpace.margin) }
                .navigationTitle("Test the three modes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
