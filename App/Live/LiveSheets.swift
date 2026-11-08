// ScreenLingo – App – Live sheets: More, Status (with session), Test (2.0.0 build 90)
import SwiftUI

// MARK: - More
struct MoreSheet: View {
    let engine: TranslatorEngine
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var feedback: FeedbackCenter
    @StateObject private var capture: EngineSlice<CaptureSnapshot>
    @AppStorage("area") private var area = OCRArea.smart.rawValue
    @AppStorage("winSize") private var winSize = WindowSize.normal.rawValue
    @AppStorage("showOriginal") private var showOriginal = false
    @AppStorage("autoClear") private var autoClear = true
    @State private var editor: PresetEditorMode?

    init(engine: TranslatorEngine) {
        self.engine = engine
        _capture = StateObject(wrappedValue: EngineSlice(engine) { CaptureSnapshot.read($0) })
    }

    var body: some View {
        SheetScaffold(title: "More") {
            List {
                Section {
                    HStack(spacing: Space.s) {
                        tool("doc.on.doc", "Copy", enabled: capture.value.hasOutput) {
                            UIPasteboard.general.string = engine.translated; feedback.show("Translation copied", severity: .success)
                        }
                        tool(capture.value.frozen ? "play.fill" : "pause.rectangle", capture.value.frozen ? "Unfreeze" : "Freeze", enabled: capture.value.hasOutput) { engine.toggleFrozenOutput() }
                        tool("arrow.clockwise", "Retry", enabled: capture.value.hasOriginal) { engine.retranslate() }
                        tool("square.and.arrow.up", "Share", enabled: capture.value.hasOutput) { Sharer.shareImage(engine.snapshotImage()) }
                    }.listRowInsets(EdgeInsets(top: Space.s, leading: Space.m, bottom: Space.s, trailing: Space.m))
                        .listRowBackground(Color.clear)
                } header: { Text("Current translation") } footer: {
                    Text(capture.value.hasOutput ? "Acts on the translation on screen right now." : "Available once something has been translated.")
                }
                Section("Reading") {
                    Picker("Area to read", selection: $area) { ForEach(OCRArea.allCases) { Text($0.title).tag($0.rawValue) } }
                    Button { router.present(.captureArea) } label: { ListRow(title: "Choose capture area", symbol: "viewfinder") { chevron } }
                    Picker("Floating window size", selection: $winSize) { ForEach(WindowSize.allCases) { Text($0.title).tag($0.rawValue) } }
                    LabeledToggleRow(title: "Show original text", detail: "Shows the source line under the translation.", isOn: $showOriginal)
                    LabeledToggleRow(title: "Clear when text ends", detail: "Removes the caption when the screen text goes away.", isOn: $autoClear)
                }
                Section("Presets") {
                    PresetChips(store: engine.presets, onNew: { editor = .new }, onEdit: { editor = .edit($0) })
                }
                Section("Open") {
                    Button { router.present(.reader) } label: { ListRow(title: "Focus reader", subtitle: "Large, distraction-free text", symbol: "text.book.closed") { chevron } }
                    Button { router.present(.workspace) } label: { ListRow(title: "Text & photos", subtitle: "Translate typed text, photos and files", symbol: "text.viewfinder") { chevron } }
                    Button { router.go(.diagnostics) } label: { ListRow(title: "Diagnostics", subtitle: "Live dashboard, test runs, exports", symbol: "waveform.path.ecg") { chevron } }
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: area) { _, _ in engine.syncConfig() }
            .onChange(of: winSize) { _, _ in engine.applyWindowSize() }
            .onChange(of: showOriginal) { _, _ in engine.applyStyle() }
            .sheet(item: $editor) { PresetEditor(store: engine.presets, mode: $0).environmentObject(engine) }
        }
    }

    private var chevron: some View { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }

    private func tool(_ symbol: String, _ title: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button { Feedback.tap(); perform() } label: {
            VStack(spacing: Space.xs) {
                Image(systemName: symbol).font(.body.weight(.medium))
                Text(title).font(.caption.weight(.medium))
            }.frame(maxWidth: .infinity, minHeight: 64)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Status and session (replaces the old Session screen and the Home troubleshooting section)
struct StatusSheet: View {
    let engine: TranslatorEngine
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var feedback: FeedbackCenter
    @StateObject private var capture: EngineSlice<CaptureSnapshot>
    @StateObject private var system: EngineSlice<SystemSnapshot>
    @StateObject private var session: EngineSlice<SessionSnapshot>
    @AppStorage("sessionLimit") private var limit = 0
    @AppStorage("privateSession") private var privateSession = false
    @AppStorage("homeMetrics") private var showTiming = true
    @State private var confirmClear = false

    init(engine: TranslatorEngine) {
        self.engine = engine
        _capture = StateObject(wrappedValue: EngineSlice(engine) { CaptureSnapshot.read($0) })
        _system = StateObject(wrappedValue: EngineSlice(engine) { SystemSnapshot.read($0) })
        _session = StateObject(wrappedValue: EngineSlice(engine) { SessionSnapshot.read($0) })
    }

    private func quick(_ symbol: String, _ title: String, perform: @escaping () -> Void) -> some View {
        Button { Feedback.tap(); perform() } label: {
            VStack(spacing: Space.xs) {
                Image(systemName: symbol).font(.body.weight(.semibold))
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        }.buttonStyle(.plain)
    }

    var body: some View {
        SheetScaffold(title: "Status") {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Space.m) {
                        Text(capture.value.headline).font(.title2.bold())
                        StatusPill(text: capture.value.status.title, symbol: capture.value.status.symbol, severity: capture.value.severity)
                        Text(system.value.status).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                        if !system.value.lastRaw.isEmpty {
                            Text("Last text read: \(system.value.lastRaw)").font(.footnote).foregroundStyle(.tertiary).lineLimit(3)
                        }
                    }.padding(.vertical, Space.xs)
                    TranslationActivityView()
                }
                Section {
                    HStack(spacing: Space.s) {
                        quick(capture.value.paused ? "play.fill" : "pause.fill", capture.value.paused ? "Resume" : "Pause") { engine.paused = !capture.value.paused }
                        quick("pip", "Window") { engine.startPiP() }
                        quick("checkmark.circle", "Test pair") { engine.runTest() }
                        quick("doc.on.clipboard", "Report") {
                            UIPasteboard.general.string = engine.diag.report(engine: engine); feedback.show("Report copied", severity: .success)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: Space.s, leading: Space.m, bottom: Space.s, trailing: Space.m))
                    .listRowBackground(Color.clear)
                }
                if showTiming { LatencyDetail(monitor: engine.latency) }
                Section("This session") {
                    if let started = session.value.started { LabeledContent("Started", value: started.formatted(date: .omitted, time: .shortened)) }
                    LabeledContent("Translations", value: "\(session.value.translations)")
                    LabeledContent("Characters", value: "\(session.value.characters)")
                    Toggle("Pause live translation", isOn: Binding(get: { capture.value.paused }, set: { engine.paused = $0 }))
                    LabeledToggleRow(title: "Private session", detail: "No new history entries and no translation memory written to disk.", isOn: $privateSession)
                    Picker("Pause session after", selection: $limit) {
                        Text("No limit").tag(0); Text("15 minutes").tag(15); Text("30 minutes").tag(30); Text("1 hour").tag(60)
                    }
                    Button("Restart session timer") { engine.resetSession() }
                    Button("Clear current output", role: .destructive) { confirmClear = true }
                }
                Section("If something is wrong") {
                    Button("Refresh language readiness") { Task { await engine.refreshStatus() } }
                    Button("Open Diagnostics") { router.go(.diagnostics) }
                }
            }
            .scrollContentBackground(.hidden)
            .confirmDestructive("Clear the current output?", isPresented: $confirmClear, button: "Clear output") { engine.clearOutput() }
        }
    }
}

struct SessionSnapshot: Equatable {
    var started: Date?
    var translations: Int
    var characters: Int
    @MainActor static func read(_ e: TranslatorEngine) -> SessionSnapshot {
        SessionSnapshot(started: e.sessionStarted, translations: e.sessionTranslations, characters: e.sessionCharacters)
    }
}

// MARK: - Test sheet (the §11 test card; same engine calls as before)
struct TestSheet: View {
    let engine: TranslatorEngine
    var body: some View {
        SheetScaffold(title: "Test") {
            ScrollView {
                TestCard(diag: engine.diag, engine: engine).padding(Space.l)
            }
        }
    }
}
