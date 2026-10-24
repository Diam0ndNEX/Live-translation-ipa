// Screen Translator – App – v0.11.0
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @Environment(\.selectTab) private var selectTab
    @AppStorage("mode") private var mode = TranslateMode.movie.rawValue
    @AppStorage("area") private var area = OCRArea.smart.rawValue
    @AppStorage("speed") private var speed = SpeedPreset.balanced.rawValue
    @AppStorage("winSize") private var winSize = WindowSize.normal.rawValue
    @AppStorage("showOriginal") private var showOriginal = false
    @AppStorage("autoClear") private var autoClear = true
    @AppStorage("speak") private var speak = false
    @AppStorage("autoCopy") private var autoCopy = false
    @AppStorage("homePresets") private var homePresets = true
    @AppStorage("homeTools") private var homeTools = true
    @AppStorage("homeQuick") private var homeQuick = true
    @AppStorage("homeStatus") private var homeStatus = true
    @AppStorage("homeRecent") private var homeRecent = true
    @State private var editor: PresetEditorMode?
    @State private var showReader = false

    private var previewRatio: CGFloat {
        let s = (WindowSize(rawValue: winSize) ?? .normal).size
        return s.width / s.height
    }

    private var state: (text: String, color: Color) {
        if !engine.captureAlive { return ("Idle", .gray) }
        if engine.paused { return ("Paused", .orange) }
        if engine.frozen { return ("Frozen", .blue) }
        return ("Live", .green)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    languageSection
                    hero
                    if homeTools { tools }
                    startSection
                    checklist
                    if homePresets {
                        PresetChips(store: engine.presets, onNew: { editor = .new }, onEdit: { editor = .edit($0) })
                    }
                    if homeQuick { quickSection }
                    if homeStatus { statusSection }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: speed) { _, _ in engine.syncConfig() }
            .onChange(of: area) { _, _ in engine.syncConfig() }
            .onChange(of: mode) { _, _ in engine.syncConfig() }
            .onChange(of: winSize) { _, _ in engine.applyWindowSize() }
            .onChange(of: showOriginal) { _, _ in engine.applyStyle() }
        }
        .sheet(item: $editor) { PresetEditor(store: engine.presets, mode: $0).environmentObject(engine) }
        .sheet(isPresented: $showReader) { ReaderView().environmentObject(engine) }
    }

    // MARK: Header
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Translator").font(.title.bold())
                Text("Offline · \(AppVersion.full)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { selectTab(3) } label: {
                HStack(spacing: 6) {
                    Circle().fill(state.color).frame(width: 8, height: 8)
                    Text(state.text).font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.card, in: Capsule())
                .foregroundStyle(.white)
            }
            .accessibilityLabel("Status \(state.text). Open diagnostics")
        }
        .padding(.top, 8)
    }

    // MARK: Languages
    private func shortName(_ code: String) -> String { code == "auto" ? "AUTO" : code.uppercased() }

    private var languageSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                LangMenu(code: $engine.sourceCode, items: engine.languages, allowAuto: true)
                Button { engine.swapLanguages(); engine.tap() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(Theme.card, in: Circle())
                }
                .foregroundStyle(.white)
                .accessibilityLabel("Swap languages")
                LangMenu(code: $engine.targetCode, items: engine.languages)
            }
            let current = "\(engine.sourceCode)>\(engine.targetCode)"
            let others = engine.recentPairs.filter { $0 != current }
            if (homeRecent && !others.isEmpty) || (engine.sourceCode == "auto" && engine.detectedLang != "–") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if engine.sourceCode == "auto" && engine.detectedLang != "–" {
                            Label("Detected \(shortName(engine.detectedLang))\(engine.lockedLang != nil ? " 🔒" : "")",
                                  systemImage: "sparkle.magnifyingglass")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Theme.accent.start.opacity(0.25), in: Capsule())
                        }
                        if homeRecent {
                            ForEach(others, id: \.self) { pair in
                                let p = pair.split(separator: ">").map(String.init)
                                Button { engine.applyPair(pair) } label: {
                                    Text(p.count == 2 ? "\(shortName(p[0])) → \(shortName(p[1]))" : pair)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Theme.card, in: Capsule())
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Live preview
    /// Doubles as a live preview AND keeps the PiP layer on screen (required for PiP to start).
    private var hero: some View {
        ZStack(alignment: .topLeading) {
            PiPPreview(layer: engine.pip.displayLayer)
                .aspectRatio(previewRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.1)))
            Text(state.text.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(state.color.opacity(0.9), in: Capsule())
                .foregroundStyle(.white)
                .padding(10)
        }
        .onTapGesture { showReader = true }
        .accessibilityLabel("Live preview. Tap for the full-screen reader")
    }

    // MARK: Tools under the preview
    private func tool(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(.white)
        }
    }

    private var tools: some View {
        HStack(spacing: 8) {
            tool("doc.on.doc", "Copy") {
                UIPasteboard.general.string = engine.translated
                engine.tap()
                engine.toast(engine.translated.isEmpty ? "Nothing to copy yet" : "Copied")
            }
            tool("arrow.clockwise", "Retry") {
                engine.retranslate()
                engine.tap()
                engine.toast("Retranslating…")
            }
            tool(engine.frozen ? "play.fill" : "pause.fill", engine.frozen ? "Resume" : "Freeze") {
                engine.frozen.toggle()
                engine.tap()
                engine.toast(engine.frozen ? "Floating window frozen" : "Live again")
            }
            tool("square.and.arrow.up", "Image") {
                Sharer.shareImage(engine.snapshotImage())
            }
            tool("text.magnifyingglass", "Read") { showReader = true }
        }
    }

    // MARK: Start
    private var startSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    if engine.pipActive { engine.pip.stop() } else { engine.startPiP() }
                    engine.tap()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: engine.pipActive ? "rectangle.badge.minus" : "rectangle.on.rectangle").font(.title2)
                        Text(engine.pipActive ? "Close window" : "Floating window").font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                VStack(spacing: 2) {
                    BroadcastPicker(onTap: { engine.startPiP() }).frame(width: 60, height: 60)
                    Text(engine.captureAlive ? "Capture running" : "Start capture")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 96)
                .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if !engine.captureAlive {
                Text("Tap the broadcast icon, choose Translator Capture, then Start Broadcast. The floating window opens with it.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    // MARK: Setup checklist (until everything runs)
    private var packReady: Bool {
        engine.sourceCode == "auto"
            ? engine.langStatus.values.contains(.installed)
            : engine.langStatus[engine.sourceCode] == .installed
    }

    private func checkRow(_ title: String, ok: Bool, action: (() -> Void)? = nil) -> some View {
        Button { action?() } label: {
            HStack(spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(ok ? Color.green : Color.secondary)
                Text(title).font(.footnote).foregroundStyle(.white)
                Spacer()
                if !ok && action != nil { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var checklist: some View {
        if !(packReady && engine.pipActive && engine.captureAlive) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Setup").font(.caption.bold()).foregroundStyle(.secondary)
                checkRow("Language pack downloaded", ok: packReady) { selectTab(1) }
                checkRow("Floating window open", ok: engine.pipActive) { engine.startPiP() }
                checkRow("Screen capture running", ok: engine.captureAlive)
            }
            .card()
        }
    }

    // MARK: Quick settings
    private func tile<P: View>(_ icon: String, _ tint: Color, _ title: String, _ value: String,
                               @ViewBuilder picker: () -> P) -> some View {
        Menu {
            picker()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption2).foregroundStyle(.secondary)
                    Text(value).font(.footnote.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func chipToggle(_ icon: String, _ title: String, _ isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle(); engine.tap() } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(isOn.wrappedValue ? Color.white : Color.secondary)
                .background(isOn.wrappedValue ? Theme.accent.start.opacity(0.85) : Theme.card, in: Capsule())
        }
    }

    private var quickSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                tile("film", .blue, "Mode", TranslateMode(rawValue: mode)?.title ?? mode) {
                    Picker("Mode", selection: $mode) {
                        ForEach(TranslateMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                tile("viewfinder", .purple, "Reads", OCRArea(rawValue: area)?.title ?? area) {
                    Picker("Area", selection: $area) {
                        ForEach(OCRArea.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
            }
            HStack(spacing: 10) {
                tile("speedometer", .green, "Speed", SpeedPreset(rawValue: speed)?.title ?? speed) {
                    Picker("Speed", selection: $speed) {
                        ForEach(SpeedPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                tile("rectangle.expand.vertical", .orange, "Window", WindowSize(rawValue: winSize)?.title ?? winSize) {
                    Picker("Window", selection: $winSize) {
                        ForEach(WindowSize.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chipToggle("text.quote", "Original", $showOriginal)
                    chipToggle("eraser", "Auto-clear", $autoClear)
                    chipToggle("speaker.wave.2", "Speak", $speak)
                    chipToggle("doc.on.clipboard", "Auto-copy", $autoCopy)
                }
            }
        }
    }

    // MARK: Status
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(engine.captureAlive ? Color.green : Color.red).frame(width: 9, height: 9)
                Text(engine.captureAlive ? "Capture connected" : "Capture not connected")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Details") { selectTab(3) }.font(.caption.weight(.bold))
            }
            if engine.captureAlive {
                Text("\(engine.frames) frames · \(engine.ocrCount) updates · read \(Int(engine.ocrMs)) ms · translate \(Int(engine.translateMs)) ms")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(engine.status).font(.footnote).foregroundStyle(.secondary)
            if !engine.lastRaw.isEmpty {
                Text("OCR sees: \(engine.lastRaw)").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if engine.extensionVersion != "–" && engine.extensionVersion != AppVersion.version {
                Text("⚠️ Capture extension is v\(engine.extensionVersion), app is v\(AppVersion.version). Reinstall the IPA.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Toggle("Pause translating", isOn: $engine.paused).font(.footnote)
                Button { engine.runTest(); engine.toast("Testing translation…") } label: {
                    Label("Test", systemImage: "checkmark.seal").font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .card()
    }
}
