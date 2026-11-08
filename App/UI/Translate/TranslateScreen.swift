// ScreenLingo – App – Translate tab (2.1.0, spec §13.5.1)
// Idle, starting, live, paused and attention are states of this one screen. It observes one snapshot,
// so it redraws only when what it shows changes.
import SwiftUI

struct TranslateScreen: View {
    let engine: TranslatorEngine
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var feedback: FeedbackCenter
    @StateObject private var slice: EngineSlice<TranslateSnapshot>
    @StateObject private var test: ObjectSlice<Diagnostics, TestSnapshot>
    @AppStorage("mode") private var mode = TranslateMode.movie.rawValue
    @AppStorage("speed") private var speed = SpeedPreset.balanced.rawValue
    @AppStorage("translationSystem") private var translationSystem = TranslationSystem.legacy.rawValue
    @AppStorage("area") private var area = OCRArea.smart.rawValue
    @AppStorage("setupState") private var setupState = ""
    @AppStorage("onboarded") private var onboarded = true
    @AppStorage("showOriginal") private var showOriginal = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focus = false
    @State private var composing = false
    @Namespace private var morph

    init(engine: TranslatorEngine) {
        self.engine = engine
        _slice = StateObject(wrappedValue: EngineSlice(engine) { TranslateSnapshot.read($0) })
        _test = StateObject(wrappedValue: ObjectSlice(engine.diag) { TestSnapshot.read($0) })
    }

    private var snap: TranslateSnapshot {
        #if SCREENLINGO_FIXTURES
        if let fixture = UIFixture.translateFixture { return fixture }
        #endif
        return slice.value
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: KitSpace.group) {
                    if setupState == "skipped" { finishSetupRow }
                    if composing {
                        ComposeResult(engine: engine, translated: snap.translated, original: snap.original) { endCompose() }
                    } else if snap.phase.isSession {
                        liveContent
                    } else {
                        idleContent
                    }
                    RecentList(lines: snap.recent) { router.go(.library) }
                }
                .padding(.horizontal, KitSpace.margin)
                .padding(.top, KitSpace.tight)
                .padding(.bottom, KitSpace.group)
                .modifier(ReadableColumn())
                .animation(KitMotion.state(reduceMotion), value: snap.phase)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) {
                ComposeBar(engine: engine, composing: $composing)
            }
            .navigationTitle("Translate")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(AllowsLandscape())
            .toolbar { toolbar }
            .fullScreenCover(isPresented: $focus) { FocusMode(engine: engine) }
            .onChange(of: translationSystem) { _, _ in engine.translationSystemChanged() }
            .onChange(of: area) { _, _ in engine.syncConfig() }
            .onChange(of: snap.phase) { old, new in
                if case .attention = new, old != new { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
                if new == .live, old == .starting { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            }
        }
    }

    // MARK: Toolbar
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if snap.phase.isSession {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { engine.paused.toggle() } label: {
                    Label(snap.paused ? "Resume" : "Pause", systemImage: snap.paused ? "play.fill" : "pause.fill")
                }
                .help(snap.paused ? "Resume translating" : "Pause translating")
                Button { snap.pipActive ? engine.pip.stop() : engine.startPiP() } label: {
                    Label(snap.pipActive ? "Close window" : "Show window", systemImage: snap.pipActive ? "pip.exit" : "pip.enter")
                }
                .help(snap.pipActive ? "Close the floating window" : "Show the floating window")
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { router.present(.more) } label: { Label("Reading and window", systemImage: "slider.horizontal.3") }
                    Button { router.present(.status) } label: { Label("Session", systemImage: "timer") }
                    Button { focus = true } label: { Label("Focus mode", systemImage: "text.book.closed") }
                    Button { router.present(.test) } label: { Label("Test the three modes", systemImage: "checklist") }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: Idle
    @ViewBuilder private var idleContent: some View {
        pairTitle
        VStack(spacing: KitSpace.tight) {
            StartButton(live: false, onTap: startTapped)
                .modifier(MorphTarget(namespace: reduceMotion ? nil : morph))
            Text("Start translating").font(.title2.weight(.semibold))
            Text("Opens the system sheet: choose ScreenLingo Capture, then Start Broadcast.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        controls
        ScenesStrip(store: engine.presets)
        testRow
    }

    private var pairTitle: some View {
        let line = snap.packLine
        return LanguagePairTitle(source: snap.sourceName, target: snap.targetName, status: line.text,
                                 statusSymbol: line.symbol, statusTone: line.tone, canSwap: snap.canSwap,
                                 onSource: { router.languageSide = .source; router.present(.languages) },
                                 onTarget: { router.languageSide = .target; router.present(.languages) },
                                 onSwap: { engine.swapLanguages() })
    }

    private func modeNote(_ s: TranslationSystem) -> String {
        switch s {
        case .legacy: return "The proven original pipeline."
        case .hybridRecovery: return "Apple Default translates early; Low Latency steps in when that guess is wrong or missing."
        case .lowLatency: return "Low Latency translates both the early guess and the confirmed text."
        }
    }

    /// Translation system as a segmented control with a one-line note, then three compact menus.
    private var controls: some View {
        VStack(alignment: .leading, spacing: KitSpace.row) {
            Picker("Translation system", selection: $translationSystem) {
                Text("Legacy").tag(TranslationSystem.legacy.rawValue)
                Text("Hybrid").tag(TranslationSystem.hybridRecovery.rawValue)
                Text("Low Latency").tag(TranslationSystem.lowLatency.rawValue)
            }
            .pickerStyle(.segmented)
            Text(modeNote(TranslationSystem(rawValue: translationSystem) ?? .legacy))
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: KitSpace.group) { contentMenu; speedMenu; areaMenu; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 0) { contentMenu; speedMenu; areaMenu }
            }
        }
    }

    private var contentMenu: some View {
        Menu {
            Picker("Content", selection: $mode) { ForEach(TranslateMode.allCases) { Text($0.title).tag($0.rawValue) } }
        } label: {
            menuLabel("Content", (TranslateMode(rawValue: mode) ?? .movie).title)
        }
        .accessibilityLabel("Content type")
    }

    private var speedMenu: some View {
        Menu {
            Picker("Reading speed", selection: $speed) { ForEach(SpeedPreset.allCases) { Text($0.title).tag($0.rawValue) } }
        } label: {
            menuLabel("Speed", (SpeedPreset(rawValue: speed) ?? .balanced).title)
        }
        .accessibilityLabel("Reading speed")
    }

    private var areaMenu: some View {
        Menu {
            Picker("Area", selection: $area) {
                ForEach(OCRArea.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Button("Adjust the band…") { router.present(.captureArea) }
        } label: {
            menuLabel("Area", (OCRArea(rawValue: area) ?? .smart).title)
        }
        .accessibilityLabel("Area to read")
    }

    private func menuLabel(_ title: String, _ value: String) -> some View {
        HStack(spacing: KitSpace.unit) {
            Text(title).foregroundStyle(.secondary)
            Text(value).foregroundStyle(Color.accentColor)
            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Color.accentColor)
        }
        .font(.subheadline.weight(.medium))
        .frame(minHeight: 44)
    }

    /// The saved three-mode test, one tap from Translate.
    private var testRow: some View {
        Button { router.present(.test) } label: {
            HStack(spacing: KitSpace.row) {
                Image(systemName: "checklist").foregroundStyle(Color.accentColor).frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(test.value.name) · \(test.value.savedModes) of 3 modes saved").font(.subheadline.weight(.semibold))
                    Text(test.value.recording ? "Recording this run" : "Run the same content through all three modes")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: KitSpace.tight)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Live, starting, paused, attention
    @ViewBuilder private var liveContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            PhaseHeader(phase: snap.phase,
                        elapsed: snap.sessionStarted.map { context.date.timeIntervalSince($0) },
                        mode: snap.modeName, action: { router.present(.status) }, morph: morph)
        }
        if case .attention(let reason) = snap.phase { attentionAction(reason) }
        if snap.phase == .starting {
            Text("Choose ScreenLingo Capture in the system sheet, then Start Broadcast. Then switch to your video or app.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        LiveCaption(translated: snap.translated, original: snap.original, showOriginal: showOriginal,
                    stage: snap.stage, held: snap.held)
        actionRow
    }

    @ViewBuilder private func attentionAction(_ reason: AttentionReason) -> some View {
        switch reason {
        case .captureLost, .timedOut:
            HStack(spacing: KitSpace.row) {
                StartButton(live: false, onTap: startTapped).scaleEffect(0.5).frame(width: 88, height: 88)
                Text(reason.action).font(.headline)
            }
        case .packMissing:
            Button(reason.action) { router.present(.languages) }.buttonStyle(.borderedProminent).frame(minHeight: 44)
        case .windowClosed:
            Button(reason.action) { engine.startPiP() }.buttonStyle(.borderedProminent).frame(minHeight: 44)
        }
    }

    /// Four actions on one row; at large text sizes they fall back to two rows of two.
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: KitSpace.tight) { holdButton; copyButton; listenButton; focusButton }
            VStack(spacing: KitSpace.tight) {
                HStack(spacing: KitSpace.tight) { holdButton; copyButton }
                HStack(spacing: KitSpace.tight) { listenButton; focusButton }
            }
        }
        .buttonStyle(.bordered)
        .sensoryFeedback(.selection, trigger: snap.held)
    }
    private var holdButton: some View {
        action(snap.held ? "Release" : "Hold", snap.held ? "pin.slash" : "pin", enabled: snap.hasOutput) { engine.toggleFrozenOutput() }
    }
    private var copyButton: some View {
        action("Copy", "doc.on.doc", enabled: snap.hasOutput) {
            UIPasteboard.general.string = snap.translated
            feedback.show("Translation copied", severity: .success)
        }
    }
    private var listenButton: some View {
        action("Listen", "speaker.wave.2", enabled: snap.hasOutput) { engine.speak(snap.translated) }
    }
    private var focusButton: some View {
        action("Focus", "arrow.up.left.and.arrow.down.right", enabled: true) { focus = true }
    }

    private func action(_ title: String, _ symbol: String, enabled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(!enabled)
    }

    private var finishSetupRow: some View {
        Button { onboarded = false } label: {
            LensRow(title: "Finish setup", value: "Not finished", symbol: "checklist")
        }
        .buttonStyle(.plain)
    }

    private func startTapped() {
        engine.captureRequested()
        if !engine.pipActive { engine.startPiP() }
    }

    private func endCompose() {
        composing = false
        engine.endWorkspace()
    }
}

// MARK: - Recent
private struct RecentList: View {
    let lines: [RecentLine]
    var openLibrary: () -> Void

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent").font(.headline)
                    Spacer()
                    Button("See all", action: openLibrary).font(.subheadline).frame(minHeight: 44)
                }
                ForEach(lines) { line in
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.translated).font(.body).lineLimit(2)
                            Text(line.original).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: KitSpace.tight)
                        Text(line.date, style: .relative).font(.footnote).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, KitSpace.tight)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
