// ScreenLingo – App – Translate tab (2.1.0, spec §13.5.1)
// Idle, starting, live, paused and attention are states of this one screen. It observes one snapshot,
// so it redraws only when what it shows changes.
import SwiftUI

struct TranslateScreen: View {
    let engine: TranslatorEngine
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var feedback: FeedbackCenter
    @StateObject private var slice: EngineSlice<TranslateSnapshot>
    @AppStorage("translationSystem") private var translationSystem = TranslationSystem.legacy.rawValue
    @AppStorage("area") private var area = OCRArea.smart.rawValue
    @AppStorage("setupState") private var setupState = ""
    @AppStorage("onboarded") private var onboarded = true
    @AppStorage("showOriginal") private var showOriginal = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focus = false
    @State private var composing = false

    init(engine: TranslatorEngine) {
        self.engine = engine
        _slice = StateObject(wrappedValue: EngineSlice(engine) { TranslateSnapshot.read($0) })
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
                .animation(KitMotion.state(reduceMotion), value: snap.phase)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) {
                ComposeBar(engine: engine, composing: $composing)
            }
            .navigationTitle("Translate")
            .navigationBarTitleDisplayMode(.inline)
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
            Text("Start translating").font(.title2.weight(.semibold))
            Text("Opens the system sheet: choose ScreenLingo Capture, then Start Broadcast.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        systemAndArea
        ScenesStrip(store: engine.presets)
    }

    private var pairTitle: some View {
        let line = snap.packLine
        return LanguagePairTitle(source: snap.sourceName, target: snap.targetName, status: line.text,
                                 statusSymbol: line.symbol, statusTone: line.tone, canSwap: snap.canSwap,
                                 onSource: { router.languageSide = .source; router.present(.languages) },
                                 onTarget: { router.languageSide = .target; router.present(.languages) },
                                 onSwap: { engine.swapLanguages() })
    }

    /// Two menus on one line: System and Area.
    private var systemAndArea: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: KitSpace.group) { systemMenu; areaMenu; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: KitSpace.tight) { systemMenu; areaMenu }
        }
    }

    private var systemMenu: some View {
        Menu {
            Picker("System", selection: $translationSystem) {
                ForEach(TranslationSystem.allCases, id: \.rawValue) { Text($0.shortName).tag($0.rawValue) }
            }
        } label: {
            menuLabel("System", (TranslationSystem(rawValue: translationSystem) ?? .legacy).shortName)
        }
        .accessibilityLabel("Translation system")
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
            Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(Color.accentColor)
        }
        .font(.subheadline.weight(.medium))
        .frame(minHeight: 44)
    }

    // MARK: Live, starting, paused, attention
    @ViewBuilder private var liveContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            PhaseHeader(phase: snap.phase,
                        elapsed: snap.sessionStarted.map { context.date.timeIntervalSince($0) },
                        mode: snap.modeName) { router.present(.status) }
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

    private var actionRow: some View {
        HStack(spacing: KitSpace.tight) {
            action(snap.held ? "Release" : "Hold", snap.held ? "pin.slash" : "pin", enabled: snap.hasOutput) { engine.toggleFrozenOutput() }
            action("Copy", "doc.on.doc", enabled: snap.hasOutput) {
                UIPasteboard.general.string = snap.translated
                feedback.show("Translation copied", severity: .success)
            }
            action("Listen", "speaker.wave.2", enabled: snap.hasOutput) { engine.speak(snap.translated) }
            action("Focus", "arrow.up.left.and.arrow.down.right", enabled: true) { focus = true }
        }
        .buttonStyle(.bordered)
        .sensoryFeedback(.selection, trigger: snap.held)
    }

    private func action(_ title: String, _ symbol: String, enabled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
