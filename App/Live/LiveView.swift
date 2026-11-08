// ScreenLingo – App – Live tab (2.0.0 build 90)
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
                VStack(spacing: Space.l) {
                    if setupState == "skipped" {
                        Banner(text: "Setup isn't finished. A short check makes sure translation works.", severity: .info,
                               actionTitle: "Finish setup") { onboarded = false }
                    }
                    LiveStage(engine: engine, capture: capture.value, openStatus: { router.present(.status) })
                    PairSection(engine: engine, pair: pair.value)
                    controls
                    testRow
                }
                .padding(.horizontal, Space.l).padding(.vertical, Space.m)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Live").navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { router.present(.more) } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("More options")
                }
            }
            .onChange(of: speed) { _, _ in engine.syncConfig() }
            .onChange(of: mode) { _, _ in engine.syncConfig() }
            .onChange(of: translationSystem) { _, _ in engine.translationSystemChanged() }
        }
    }

    private func modeNote(_ s: TranslationSystem) -> String {
        if s == .legacy { return "The proven original pipeline." }
        if s == .hybridRecovery { return "Apple Default translates early; Low Latency steps in when that guess is wrong or missing." }
        return "Low Latency translates both the early guess and the confirmed text."
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Translation mode")
            Picker("Translation system", selection: $translationSystem) {
                Text("Legacy").tag(TranslationSystem.legacy.rawValue)
                Text("Hybrid").tag(TranslationSystem.hybridRecovery.rawValue)
                Text("Low Latency").tag(TranslationSystem.lowLatency.rawValue)
            }
            .pickerStyle(.segmented)
            Text(modeNote(TranslationSystem(rawValue: translationSystem) ?? .legacy))
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if system.value.changePending {
                Banner(text: "Running \(system.value.active.title). \(system.value.pending.title) starts when the broadcast stops.", severity: .info)
            }
            Divider()
            HStack(spacing: Space.m) {
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
                    subtitle: test.value.recording ? "Recording this run" : "Run the same content through all three modes",
                    symbol: "checklist") {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain).infoCard()
    }
}

// MARK: - Stage
/// The preview, one big start button, and the three things you do next.
private struct LiveStage: View {
    let engine: TranslatorEngine
    let capture: CaptureSnapshot
    let openStatus: () -> Void
    @AppStorage("winSize") private var winSize = WindowSize.normal.rawValue

    private var previewRatio: CGFloat {
        let size = (WindowSize(rawValue: winSize) ?? .normal).size
        return size.width / size.height
    }

    var body: some View {
        VStack(spacing: Space.l) {
            ZStack(alignment: .topLeading) {
                PiPPreview(layer: engine.pip.displayLayer)
                    .aspectRatio(previewRatio, contentMode: .fit)
                    .frame(maxHeight: 190)
                    .frame(maxWidth: .infinity)
                    .background(Palette.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                    .overlay {
                        if !capture.hasOutput && !capture.alive {
                            Text("Your live translation appears here.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                .padding(Space.l).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .accessibilityLabel("Floating window preview")
                Button(action: openStatus) {
                    StatusPill(text: capture.status.title, symbol: capture.status.symbol, severity: capture.severity)
                }
                .buttonStyle(.plain).padding(Space.s).accessibilityHint("Opens status and session")
            }
            VStack(spacing: Space.s) {
                BroadcastPicker(onTap: { engine.captureRequested(); if !engine.pipActive { engine.startPiP() } })
                    .frame(width: 76, height: 76)
                    .background(Color.accentColor, in: Circle())
                    .accessibilityLabel(capture.alive ? "Open screen broadcast controls" : "Start screen capture")
                Text(capture.alive ? capture.headline : "Start live translation").font(.title3.weight(.semibold))
                Text(capture.alive ? Strings.switchApps : Strings.startHelp)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s) {
                action(capture.paused ? "play.fill" : "pause.fill", capture.paused ? "Resume" : "Pause", enabled: capture.alive) {
                    engine.paused.toggle()
                }
                action(capture.pipActive ? "pip.exit" : "pip.enter", capture.pipActive ? "Close window" : "Floating window") {
                    if capture.pipActive { engine.pip.stop() } else { engine.startPiP() }
                }
                action("list.bullet.rectangle", "Status", run: openStatus)
            }
        }.infoCard()
    }

    private func action(_ symbol: String, _ title: String, enabled: Bool = true, run: @escaping () -> Void) -> some View {
        Button { Feedback.tap(); run() } label: {
            VStack(spacing: Space.xs) {
                Image(systemName: symbol).font(.title3.weight(.semibold))
                Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Language pair
private struct PairSection: View {
    let engine: TranslatorEngine
    let pair: PairSnapshot
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            LanguagePairBar(
                source: Binding(get: { pair.source }, set: { engine.sourceCode = $0 }),
                target: Binding(get: { pair.target }, set: { engine.targetCode = $0 }),
                items: pair.languages, swapDisabled: pair.source == "auto"
            ) { engine.swapLanguages(); Feedback.tap() }
            HStack {
                Button { router.go(.languages) } label: {
                    StatusPill(text: pair.packState.title, symbol: pair.packState.symbol, severity: pair.packState.severity)
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
