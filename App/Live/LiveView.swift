// ScreenLingo – App – Live tab (2.0.0 build 85)
import SwiftUI

/// Capture, language pair and the three controls that matter. Everything else is in More and Status.
/// Observes small snapshots, not the engine, so live captions do not redraw this screen.
struct LiveView: View {
    let engine: TranslatorEngine
    @EnvironmentObject private var router: AppRouter
    @StateObject private var capture: EngineSlice<CaptureSnapshot>
    @StateObject private var pair: EngineSlice<PairSnapshot>
    @StateObject private var system: EngineSlice<SystemSnapshot>
    @StateObject private var test: ObjectSlice<Diagnostics, TestSnapshot>
    @AppStorage("mode") private var mode = TranslateMode.movie.rawValue
    @AppStorage("speed") private var speed = SpeedPreset.balanced.rawValue
    /// Same key as Settings → Translation; both pickers edit one value.
    @AppStorage("translationSystem") private var translationSystem = TranslationSystem.legacy.rawValue
    @AppStorage("setupState") private var setupState = ""
    @AppStorage("onboarded") private var onboarded = true

    init(engine: TranslatorEngine) {
        self.engine = engine
        _capture = StateObject(wrappedValue: EngineSlice(engine) { CaptureSnapshot.read($0) })
        _pair = StateObject(wrappedValue: EngineSlice(engine) { PairSnapshot.read($0) })
        _system = StateObject(wrappedValue: EngineSlice(engine) { SystemSnapshot.read($0) })
        _test = StateObject(wrappedValue: ObjectSlice(engine.diag) { TestSnapshot.read($0) })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.m) {
                    if setupState == "skipped" {
                        Banner(text: "Setup isn't finished. A short check makes sure translation works.", severity: .info,
                               actionTitle: "Finish setup") { onboarded = false }
                    }
                    LiveHero(engine: engine, capture: capture.value, openStatus: { router.present(.status) })
                    PairSection(engine: engine, pair: pair.value)
                    controls
                    testRow
                }
                .padding(.horizontal, Space.l).padding(.vertical, Space.s)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("ScreenLingo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { router.present(.status) } label: { Image(systemName: "waveform.path.ecg") }
                        .accessibilityLabel("Status and session")
                    Button { router.present(.more) } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("More options")
                }
            }
            .onChange(of: speed) { _, _ in engine.syncConfig() }
            .onChange(of: mode) { _, _ in engine.syncConfig() }
            .onChange(of: translationSystem) { _, _ in engine.translationSystemChanged() }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Picker("Translation system", selection: $translationSystem) {
                Text("Legacy").tag(TranslationSystem.legacy.rawValue)
                Text("Hybrid").tag(TranslationSystem.hybridRecovery.rawValue)
                Text("Low Latency").tag(TranslationSystem.lowLatency.rawValue)
            }
            .pickerStyle(.segmented)
            Text(system.value.changePending
                 ? "Running: \(system.value.active.title). \(system.value.pending.title) starts when the broadcast stops."
                 : "Running: \(system.value.active.title)")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s) {
                menuPicker("Content", selection: $mode) { ForEach(TranslateMode.allCases) { Text($0.title).tag($0.rawValue) } }
                menuPicker("Reading speed", selection: $speed) { ForEach(SpeedPreset.allCases) { Text($0.title).tag($0.rawValue) } }
            }
        }.infoCard()
    }

    private func menuPicker<C: View>(_ title: String, selection: Binding<String>, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: selection, content: content).pickerStyle(.menu).labelsHidden()
                .frame(minHeight: 44, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var testRow: some View {
        Button { router.present(.test) } label: {
            ListRow(title: "\(test.value.name) · \(test.value.savedModes) of 3 modes saved",
                    subtitle: test.value.recording ? "Recording this run" : "Compare the three systems on the same content",
                    symbol: "checklist") {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain).infoCard()
    }
}

// MARK: - Hero
private struct LiveHero: View {
    let engine: TranslatorEngine
    let capture: CaptureSnapshot
    let openStatus: () -> Void
    @AppStorage("winSize") private var winSize = WindowSize.normal.rawValue

    private var previewRatio: CGFloat {
        let size = (WindowSize(rawValue: winSize) ?? .normal).size
        return size.width / size.height
    }

    var body: some View {
        VStack(spacing: Space.m) {
            HStack {
                Button(action: openStatus) {
                    StatusPill(text: capture.status.title, symbol: capture.status.symbol, severity: capture.severity)
                }.buttonStyle(.plain).accessibilityHint("Opens status and session")
                Spacer()
            }
            PiPPreview(layer: engine.pip.displayLayer)
                .aspectRatio(previewRatio, contentMode: .fit)
                .frame(maxHeight: 170)
                .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay {
                    if !capture.hasOutput && !capture.alive {
                        Text("Your live translation appears here.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .padding(Space.l).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    }
                }
                .accessibilityLabel("Floating window preview")
            HStack(spacing: Space.l) {
                BroadcastPicker(onTap: { engine.captureRequested(); if !engine.pipActive { engine.startPiP() } })
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor, in: Circle())
                    .accessibilityLabel(capture.alive ? "Open screen broadcast controls" : "Start screen capture")
                VStack(alignment: .leading, spacing: 2) {
                    Text(capture.alive ? capture.headline : "Start live translation").font(.headline)
                    Text(capture.alive ? "Switch to your video or app." : "Tap the round button, choose ScreenLingo Capture, then Start Broadcast.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                IconButton(symbol: capture.alive ? (capture.paused ? "play.fill" : "pause.fill") : "pip.enter",
                           label: capture.alive ? (capture.paused ? "Resume translation" : "Pause translation") : "Open or close floating window") {
                    if capture.alive { engine.paused.toggle() }
                    else if capture.pipActive { engine.pip.stop() }
                    else { engine.startPiP() }
                    Feedback.tap()
                }
            }
        }.infoCard()
    }
}

// MARK: - Language pair
private struct PairSection: View {
    let engine: TranslatorEngine
    let pair: PairSnapshot
    @EnvironmentObject private var router: AppRouter

    private var pill: (text: String, symbol: String, severity: Severity) {
        if pair.checking { return ("Checking language packs", "arrow.triangle.2.circlepath", .info) }
        if pair.source == "auto", pair.detected == "–" { return ("Auto-detect", "sparkle.magnifyingglass", .info) }
        return pair.packReady ? ("Ready offline", "checkmark.shield.fill", .success) : ("Needs download", "arrow.down.circle.fill", .warning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            LanguagePairBar(
                source: Binding(get: { pair.source }, set: { engine.sourceCode = $0 }),
                target: Binding(get: { pair.target }, set: { engine.targetCode = $0 }),
                items: pair.languages, swapDisabled: pair.source == "auto"
            ) { engine.swapLanguages(); Feedback.tap() }
            HStack {
                Button { router.go(.languages) } label: {
                    StatusPill(text: pill.text, symbol: pill.symbol, severity: pill.severity)
                }.buttonStyle(.plain).accessibilityHint("Opens Languages")
                Spacer()
                if !pair.recent.isEmpty {
                    Menu {
                        ForEach(pair.recent, id: \.self) { p in
                            Button(p.replacingOccurrences(of: ">", with: " → ").uppercased()) { engine.applyPair(p) }
                        }
                    } label: { Label("Recent", systemImage: "clock.arrow.circlepath").font(.footnote.weight(.semibold)).frame(minHeight: 44) }
                }
            }
            if pair.source == "auto", pair.detected != "–" {
                Text("Detected \(pair.detected.uppercased())\(pair.locked ? " · locked" : "")")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.infoCard()
    }
}
