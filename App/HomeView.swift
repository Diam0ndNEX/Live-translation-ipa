import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @Environment(\.selectTab) private var selectTab
    @AppStorage("mode") private var mode = TranslateMode.movie.rawValue
    @AppStorage("area") private var area = OCRArea.smart.rawValue
    @AppStorage("speed") private var speed = SpeedPreset.balanced.rawValue
    @AppStorage("winSize") private var winSize = WindowSize.normal.rawValue
    @AppStorage("showOriginal") private var showOriginal = false
    @AppStorage("autoClear") private var autoClear = true
    @AppStorage("homePresets") private var homePresets = true
    @AppStorage("homeTools") private var homeTools = true
    @AppStorage("homeQuick") private var homeQuick = true
    @AppStorage("homeStatus") private var homeStatus = true
    @AppStorage("homeRecent") private var homeRecent = true
    @State private var destination: HomeDestination?
    @State private var editor: PresetEditorMode?
    @AppStorage("homeDetailsExpanded") private var showDetails = false
    @AppStorage("homeQuickExpanded") private var showQuick = false
    @AppStorage("homeMetrics") private var homeMetrics = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: String {
        if !engine.captureAlive { return "Ready when you are" }
        if engine.paused { return "Translation paused" }
        if engine.frozen { return "Holding this translation" }
        if engine.waitingToDisplay { return "Holding for readability" }
        return engine.isTranslating ? "Translating…" : "Reading your screen"
    }
    private var liveStateDescription: String {
        engine.captureAlive ? state + (engine.outputModelLabel.isEmpty ? "" : " · " + engine.outputModelLabel)
            : "Use the broadcast button below to start or restart"
    }
    private var captureColor: Color {
        switch engine.captureStatus {
        case .active: return .green
        case .waiting, .connected: return .orange
        case .lost: return .red
        case .idle, .stopped: return .secondary
        }
    }
    private var packReady: Bool {
        engine.sourceCode == "auto" ? engine.langStatus.values.contains(.installed) : engine.langStatus[engine.sourceCode] == .installed
    }
    private var previewRatio: CGFloat {
        let size = (WindowSize(rawValue: winSize) ?? .normal).size
        return size.width / size.height
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    languageCard
                    liveCard
                    warmupCard
                    if homeTools { outputTools }
                    if homeStatus && homeMetrics { LatencyReadout(monitor: engine.latency) }
                    if !engine.captureAlive { readiness }
                    toolsSection
                    if homePresets {
                        PresetChips(store: engine.presets, onNew: { editor = .new }, onEdit: { editor = .edit($0) })
                    }
                    if homeQuick { quickControls }
                    if homeRecent && !engine.recentPairs.isEmpty { recentPairs }
                    if homeStatus { details }
                }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 28)
            }
            .background(Theme.background.ignoresSafeArea())
            .scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: speed) { _, _ in engine.syncConfig() }
            .onChange(of: area) { _, _ in engine.syncConfig() }
            .onChange(of: mode) { _, _ in engine.syncConfig() }
            .onChange(of: winSize) { _, _ in engine.applyWindowSize() }
            .onChange(of: showOriginal) { _, _ in engine.applyStyle() }
        }
        .sheet(item: $destination) { destination in
            switch destination {
            case .workspace: TranslationWorkspace().environmentObject(engine)
            case .reader: ReaderView().environmentObject(engine)
            case .area: CaptureAreaEditor().environmentObject(engine)
            case .session: SessionControls().environmentObject(engine)
            }
        }
        .sheet(item: $editor) { PresetEditor(store: engine.presets, mode: $0).environmentObject(engine) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandMark().frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 1) {
                Text("ScreenLingo").font(.system(.title2, design: .rounded, weight: .bold))
                Text("UNDERSTAND EVERY MOMENT").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { destination = .session } label: {
                Image(systemName: "slider.horizontal.3").font(.headline)
                    .frame(width: 44, height: 44).background(Theme.card, in: Circle())
            }.accessibilityLabel("Session controls")
        }
    }

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TRANSLATE").font(.caption2.bold()).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                Button { selectTab(1) } label: {
                    Label(packReady ? "Offline ready" : "Get language packs", systemImage: packReady ? "checkmark.shield" : "arrow.down.circle")
                        .font(.caption.weight(.medium)).foregroundStyle(packReady ? Color.mint : Theme.accent.start)
                }.buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                LangMenu(code: $engine.sourceCode, items: engine.languages, allowAuto: true)
                Button { engine.swapLanguages(); engine.tap() } label: {
                    Image(systemName: "arrow.left.arrow.right").frame(width: 44, height: 44)
                        .background(Theme.cardStrong, in: Circle())
                }.accessibilityLabel("Swap source and target languages")
                    .disabled(engine.sourceCode == "auto")
                LangMenu(code: $engine.targetCode, items: engine.languages)
            }
            if engine.sourceCode == "auto", engine.detectedLang != "–" {
                Label("Detected \(engine.detectedLang.uppercased())\(engine.lockedLang != nil ? " · locked" : "")", systemImage: "sparkle.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.card()
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: engine.captureStatus.symbol)
                        .font(.title3.weight(.semibold)).foregroundStyle(captureColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(engine.captureStatus.title).font(.subheadline.weight(.semibold))
                            .foregroundStyle(captureColor)
                        Text(liveStateDescription)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(engine.captureStatus.title). \(liveStateDescription)")
                Spacer()
                Button { destination = .reader } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
                }.accessibilityLabel("Open focus reader")
            }.padding(.leading, 18).padding(.trailing, 6)
            PiPPreview(layer: engine.pip.displayLayer)
                .aspectRatio(previewRatio, contentMode: .fit)
                .overlay {
                    if engine.translated.isEmpty && !engine.captureAlive {
                        VStack(spacing: 10) {
                            Image(systemName: "captions.bubble").font(.system(size: 32, weight: .light)).foregroundStyle(.mint)
                            Text("A little window. A whole new language.")
                                .font(.system(.headline, design: .rounded)).multilineTextAlignment(.center)
                            Text("Your live translation will appear here.").font(.footnote).foregroundStyle(.secondary)
                        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.surface)
                    }
                }
            Divider().overlay(Color.white.opacity(0.06))
            captureBar.padding(14)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28))
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    private var captureBar: some View {
        HStack(spacing: 14) {
            BroadcastPicker(onTap: { engine.captureRequested(); if !engine.pipActive { engine.startPiP() } }).frame(width: 50, height: 50)
                .background(Theme.gradient, in: Circle())
                .accessibilityLabel(engine.captureAlive ? "Open screen broadcast controls" : "Start screen capture")
            VStack(alignment: .leading, spacing: 3) {
                Text(engine.captureAlive ? "Broadcast controls" : "Start live translation").font(.subheadline.bold())
                Text(engine.captureAlive ? "Switch to your video or app" : "Tap the broadcast button to begin").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                if engine.captureAlive { engine.paused.toggle() }
                else if engine.pipActive { engine.pip.stop() }
                else { engine.startPiP() }
                engine.tap()
            } label: {
                Image(systemName: engine.captureAlive ? (engine.paused ? "play.fill" : "pause.fill") : "pip.enter")
                    .frame(width: 44, height: 44).background(Theme.cardStrong, in: Circle())
            }.accessibilityLabel(engine.captureAlive ? (engine.paused ? "Resume translation" : "Pause translation") : "Open or close floating window")
        }
    }

    private var outputTools: some View {
        HStack(spacing: 10) {
            action("doc.on.doc", "Copy", enabled: !engine.translated.isEmpty) {
                UIPasteboard.general.string = engine.translated; engine.toast("Translation copied")
            }
            action(engine.frozen ? "play.fill" : "pause.rectangle", engine.frozen ? "Unfreeze" : "Freeze", enabled: !engine.translated.isEmpty) { engine.toggleFrozenOutput() }
            action("arrow.clockwise", "Retry", enabled: !engine.original.isEmpty) { engine.retranslate() }
            action("square.and.arrow.up", "Share", enabled: !engine.translated.isEmpty) { Sharer.shareImage(engine.snapshotImage()) }
        }
    }
    private func action(_ symbol: String, _ title: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button { engine.tap(); perform() } label: {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.body.weight(.medium))
                Text(title).font(.caption.weight(.medium))
            }.frame(maxWidth: .infinity, minHeight: 68).background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }

    private var readiness: some View {
        Button { selectTab(packReady ? 0 : 1) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: packReady ? "info.circle" : "arrow.down.circle.fill").foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(packReady ? "Ready for your next video" : "One download. Then offline.").font(.subheadline.bold())
                    Text(packReady ? "Tap Broadcast, choose ScreenLingo Capture, then Start Broadcast. Open your video when the floating window is ready." : "Download your language pair in Languages. Translation stays on your phone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.card()
        }.buttonStyle(.plain)
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Beyond live capture").font(.system(.title3, design: .rounded, weight: .bold))
            HStack(spacing: 12) {
                HomeToolTile(symbol: "text.viewfinder", title: "Text & photos", subtitle: "Paste · import · translate", tint: .mint) { destination = .workspace }
                HomeToolTile(symbol: "viewfinder", title: "Capture area", subtitle: "Choose where to read", tint: .purple) { destination = .area }
            }
        }
    }

    private var quickControls: some View {
        DisclosureGroup(isExpanded: $showQuick) {
            VStack(spacing: 14) {
                Picker("Content", selection: $mode) { ForEach(TranslateMode.allCases) { Text($0.title).tag($0.rawValue) } }
                Picker("OCR area", selection: $area) { ForEach(OCRArea.allCases) { Text($0.title).tag($0.rawValue) } }
                Picker("Reading profile", selection: $speed) { ForEach(SpeedPreset.allCases) { Text($0.title).tag($0.rawValue) } }
                Picker("Window", selection: $winSize) { ForEach(WindowSize.allCases) { Text($0.title).tag($0.rawValue) } }
                Toggle("Show original text", isOn: $showOriginal)
                Toggle("Clear when text ends", isOn: $autoClear)
            }.font(.subheadline).padding(.top, 14)
        } label: {
            HStack {
                Label("Quick settings", systemImage: "slider.horizontal.3").font(.subheadline.weight(.semibold))
                Spacer()
                Text(SpeedPreset(rawValue: speed)?.title ?? "Balanced").font(.caption).foregroundStyle(.secondary)
            }
        }.card()
    }

    private var warmupCard: some View {
        HStack(spacing: 10) {
            Image(systemName: engine.warmupStatus == "Ready" ?
                "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle")
                .foregroundStyle(engine.warmupStatus == "Ready" ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Translation model").font(.caption2).foregroundStyle(.secondary)
                Text(engine.warmupStatus).font(.subheadline.weight(.medium))
            }
            Spacer()
        }.accessibilityElement(children: .combine).card()
    }

    private var recentPairs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECENT LANGUAGES").font(.caption2.bold()).tracking(1.4).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(engine.recentPairs, id: \.self) { pair in
                        Button { engine.applyPair(pair) } label: {
                            Text(pair.replacingOccurrences(of: ">", with: " → ").uppercased())
                                .font(.caption.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 12)
                                .background(Theme.card, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var details: some View {
        DisclosureGroup(isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 12) {
                Text(engine.status).font(.footnote).textSelection(.enabled)
                if !engine.lastRaw.isEmpty { Text("OCR · \(engine.lastRaw)").font(.caption).foregroundStyle(.secondary) }
                Button("Open activity & diagnostics") { selectTab(3) }.font(.subheadline)
                Button("Test language pair") { engine.runTest() }.font(.subheadline)
            }.padding(.top, 12)
        } label: { Label("Status & troubleshooting", systemImage: "waveform.path.ecg").font(.subheadline.weight(.medium)) }.card()
    }
}

private enum HomeDestination: String, Identifiable {
    case workspace, reader, area, session
    var id: String { rawValue }
}

private struct HomeToolTile: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol).font(.title2).foregroundStyle(tint)
                    .frame(width: 44, height: 44).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.bold())
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(17)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain)
    }
}
