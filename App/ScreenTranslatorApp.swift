// Screen Translator – App UI – v0.7.0
import SwiftUI
import ReplayKit
import Translation

@main
struct ScreenTranslatorApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}

// MARK: - Theme
enum Theme {
    static let bg = Color(red: 0.04, green: 0.05, blue: 0.09)
    static let card = Color.white.opacity(0.07)
    static let gradient = LinearGradient(
        colors: [Color(red: 0.25, green: 0.52, blue: 1), Color(red: 0.45, green: 0.42, blue: 0.98)],
        startPoint: .leading, endPoint: .trailing)
}

extension View {
    func card() -> some View {
        self.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Root
struct RootView: View {
    @StateObject private var engine = TranslatorEngine()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }
            LanguagesView().tabItem { Label("Languages", systemImage: "globe") }
            HistoryView().tabItem { Label("History", systemImage: "clock") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .environmentObject(engine)
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.35, green: 0.55, blue: 1))
        .translationTask(engine.legacyConfig) { session in await engine.runLegacy(session) }
        .translationTask(engine.downloadConfig) { session in await engine.runDownload(session) }
        .task { await engine.loadLanguages() }
        .onChange(of: phase) { _, p in if p == .active { engine.server.start() } }
    }
}

// MARK: - Broadcast picker
struct BroadcastPicker: UIViewRepresentable {
    var onTap: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        v.preferredExtension = Self.extensionID()
        v.showsMicrophoneButton = false
        v.tintColor = .white
        context.coordinator.onTap = onTap
        context.coordinator.attach(to: v)
        return v
    }
    func updateUIView(_ v: RPSystemBroadcastPickerView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.attach(to: v)
    }

    /// Also listens to the picker's real button, so one genuine tap starts both PiP and capture.
    final class Coordinator: NSObject {
        var onTap: () -> Void = {}
        private weak var attached: UIControl?

        func attach(to v: UIView) {
            guard let c = Self.findControl(in: v), c !== attached else { return }
            c.addTarget(self, action: #selector(tapped), for: .touchUpInside)
            attached = c
        }
        @objc private func tapped() { onTap() }
        private static func findControl(in v: UIView) -> UIControl? {
            for s in v.subviews {
                if let c = s as? UIControl { return c }
                if let c = findControl(in: s) { return c }
            }
            return nil
        }
    }

    /// Finds the bundled .appex so it works even if a sideloader renames bundle IDs.
    static func extensionID() -> String? {
        guard let dir = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        for u in items where u.pathExtension == "appex" {
            if let id = Bundle(url: u)?.bundleIdentifier { return id }
        }
        return nil
    }
}

// MARK: - Components
struct LangMenu: View {
    @Binding var code: String
    let items: [LangItem]
    var allowAuto = false

    var label: String {
        code == "auto" ? "Auto-detect" : (items.first { $0.code == code }?.name ?? code)
    }
    var body: some View {
        Menu {
            if allowAuto { Button("Auto-detect") { code = "auto" } }
            ForEach(items) { i in Button(i.name) { code = i.code } }
        } label: {
            HStack(spacing: 4) {
                Text(label).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

struct SettingRow<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(title).font(.subheadline)
            Spacer(minLength: 8)
            content()
        }
    }
}

// MARK: - Home
struct HomeView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @AppStorage("mode") private var mode = TranslateMode.movie.rawValue
    @AppStorage("area") private var area = OCRArea.smart.rawValue
    @AppStorage("winSize") private var winSize = WindowSize.normal.rawValue
    @AppStorage("showOriginal") private var showOriginal = false
    @AppStorage("speed") private var speed = SpeedPreset.balanced.rawValue
    @AppStorage("autoClear") private var autoClear = true

    private var previewRatio: CGFloat {
        let s = (WindowSize(rawValue: winSize) ?? .normal).size
        return s.width / s.height
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                languageBar
                presetRow
                preview
                settings
                startButton
                checklist
                statusCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .onChange(of: speed) { _, _ in engine.syncConfig() }
        .onChange(of: area) { _, _ in engine.syncConfig() }
        .onChange(of: mode) { _, _ in engine.syncConfig() }
        .background(Theme.bg.ignoresSafeArea())
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach([("movie", "film", "Movie"), ("game", "gamecontroller", "Game"), ("comic", "book", "Comic")], id: \.0) { item in
                Button { engine.applyPreset(item.0) } label: {
                    Label(item.2, systemImage: item.1)
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.card, in: Capsule())
                }
                .foregroundStyle(.white)
            }
        }
    }

    private var packReady: Bool {
        engine.sourceCode == "auto"
            ? engine.langStatus.values.contains(.installed)
            : engine.langStatus[engine.sourceCode] == .installed
    }

    private func checkRow(_ title: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(title).font(.footnote)
            Spacer()
        }
    }

    /// Only shown until everything is up and running.
    @ViewBuilder private var checklist: some View {
        if !(packReady && engine.pipActive && engine.captureAlive) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Setup").font(.caption.bold()).foregroundStyle(.secondary)
                checkRow("Language pack downloaded (Languages tab)", ok: packReady)
                checkRow("Floating window open", ok: engine.pipActive)
                checkRow("Screen capture running", ok: engine.captureAlive)
            }
            .card()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Translator").font(.title.bold())
                Text("Offline · \(AppVersion.full)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(engine.captureAlive ? Color.green : Color.gray).frame(width: 8, height: 8)
                Text(engine.captureAlive ? "Capturing" : "Idle").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.card, in: Capsule())
        }
        .padding(.top, 8)
    }

    private var languageBar: some View {
        HStack(spacing: 8) {
            LangMenu(code: $engine.sourceCode, items: engine.languages, allowAuto: true)
            Button { engine.swapLanguages() } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Theme.card, in: Circle())
            }
            .foregroundStyle(.white)
            LangMenu(code: $engine.targetCode, items: engine.languages)
        }
    }

    /// Doubles as a live preview AND keeps the PiP layer on screen (required for PiP to start).
    private var preview: some View {
        VStack(spacing: 6) {
            PiPPreview(layer: engine.pip.displayLayer)
                .aspectRatio(previewRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08)))
            Text("Live preview of the floating window").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var settings: some View {
        VStack(spacing: 12) {
            SettingRow(icon: "film", tint: .blue, title: "Mode") {
                Picker("", selection: $mode) {
                    ForEach(TranslateMode.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.menu).labelsHidden().tint(.secondary)
            }
            Divider().overlay(Color.white.opacity(0.06))
            SettingRow(icon: "viewfinder", tint: .purple, title: "OCR area") {
                Picker("", selection: $area) {
                    ForEach(OCRArea.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.menu).labelsHidden().tint(.secondary)
            }
            Divider().overlay(Color.white.opacity(0.06))
            SettingRow(icon: "rectangle.expand.vertical", tint: .orange, title: "Window size") {
                Picker("", selection: $winSize) {
                    ForEach(WindowSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.menu).labelsHidden().tint(.secondary)
                .onChange(of: winSize) { _, _ in engine.applyWindowSize() }
            }
            Divider().overlay(Color.white.opacity(0.06))
            SettingRow(icon: "speedometer", tint: .green, title: "Speed") {
                Picker("", selection: $speed) {
                    ForEach(SpeedPreset.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.menu).labelsHidden().tint(.secondary)
            }
            Divider().overlay(Color.white.opacity(0.06))
            SettingRow(icon: "text.quote", tint: .teal, title: "Show original text") {
                Toggle("", isOn: $showOriginal).labelsHidden()
            }
            Divider().overlay(Color.white.opacity(0.06))
            SettingRow(icon: "eraser", tint: .pink, title: "Clear when text ends") {
                Toggle("", isOn: $autoClear).labelsHidden()
            }
        }
        .card()
    }

    private var startButton: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { engine.startPiP() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "rectangle.on.rectangle").font(.title2)
                        Text("Floating window").font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                VStack(spacing: 2) {
                    BroadcastPicker(onTap: { engine.startPiP() }).frame(width: 60, height: 60)
                    Text("Start capture").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 96)
                .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if engine.pipActive {
                Button("Close floating window") { engine.pip.stop() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            } else {
                Text("Tap the broadcast icon, choose Translator Capture, then Start Broadcast. The floating window opens with it.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.captureAlive ? "Capture connected" : "Capture not connected")
                        .font(.subheadline.weight(.semibold))
                    if engine.captureAlive {
                        Text("\(engine.frames) frames · \(engine.ocrCount) text updates")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            Text(engine.status).font(.footnote).foregroundStyle(.secondary)
            Toggle("Pause translating", isOn: $engine.paused).font(.footnote)
            if engine.captureAlive {
                Text("OCR \(Int(engine.ocrMs)) ms · translate \(Int(engine.translateMs)) ms · extension memory left \(Int(engine.extFreeMB)) MB")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !engine.lastRaw.isEmpty {
                Text("OCR sees: \(engine.lastRaw)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if engine.extensionVersion != "–" && engine.extensionVersion != AppVersion.version {
                Text("⚠️ Capture extension is v\(engine.extensionVersion), app is v\(AppVersion.version). Reinstall the IPA.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Button { engine.runTest() } label: {
                Label("Test translation", systemImage: "checkmark.seal")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .card()
    }
}

// MARK: - Languages
struct LanguagesView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @State private var query = ""

    private var filtered: [LangItem] {
        engine.languages.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var ready: [LangItem] { filtered.filter { engine.langStatus[$0.code] == .installed } }
    private var available: [LangItem] { filtered.filter { engine.langStatus[$0.code] == .supported } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Translation runs fully on your phone using Apple's language packs. Packs are stored by iOS (not in this app). Status is shown for translating into your target language.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if engine.langStatus.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                if !ready.isEmpty {
                    Section("Ready · works offline") {
                        ForEach(ready) { l in
                            HStack {
                                Text(l.name)
                                Spacer()
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                }
                if !available.isEmpty {
                    Section("Available to download") {
                        ForEach(available) { l in
                            HStack {
                                Text(l.name)
                                Spacer()
                                Button("Get") { engine.download(l.code) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .searchable(text: $query, prompt: "Search languages")
            .navigationTitle("Languages")
            .toolbar { Button("Refresh") { Task { await engine.refreshStatus() } } }
        }
    }
}

// MARK: - Settings
struct SettingsView: View {
    @EnvironmentObject var engine: TranslatorEngine
    // Reading
    @AppStorage("mode") private var mode = TranslateMode.movie.rawValue
    @AppStorage("area") private var area = OCRArea.smart.rawValue
    @AppStorage("customY0") private var customY0 = 0.0
    @AppStorage("customY1") private var customY1 = 0.5
    @AppStorage("speed") private var speed = SpeedPreset.balanced.rawValue
    @AppStorage("stability") private var stability = 2
    @AppStorage("minTextH") private var minTextH = 0.0
    @AppStorage("ignoreList") private var ignoreList = ""
    // Floating window
    @AppStorage("winSize") private var winSize = WindowSize.normal.rawValue
    @AppStorage("theme") private var theme = PiPTheme.dark.rawValue
    @AppStorage("textSize") private var textSize = PiPTextSize.auto.rawValue
    @AppStorage("pipFont") private var pipFont = PiPFont.standard.rawValue
    @AppStorage("showOriginal") private var showOriginal = false
    @AppStorage("autoClear") private var autoClear = true
    @AppStorage("clearHold") private var clearHold = 1.0
    @AppStorage("autoOpenPiP") private var autoOpenPiP = true
    // Speech + glossary
    @AppStorage("speak") private var speak = false
    @AppStorage("glossary") private var glossary = ""

    private var readingKey: String { "\(mode)|\(area)|\(customY0)|\(customY1)|\(speed)|\(stability)" }
    private var styleKey: String { "\(theme)|\(textSize)|\(pipFont)" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(TranslateMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("OCR area", selection: $area) {
                        ForEach(OCRArea.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    if area == OCRArea.custom.rawValue {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("From \(Int(customY0 * 100))% to \(Int(customY1 * 100))% of the screen height (0% = bottom)")
                                .font(.footnote).foregroundStyle(.secondary)
                            Slider(value: $customY0, in: 0...0.9)
                            Slider(value: $customY1, in: 0.1...1)
                        }
                    }
                    Picker("Speed", selection: $speed) {
                        ForEach(SpeedPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Wait for stable text", selection: $stability) {
                        Text("Instant").tag(1)
                        Text("Normal").tag(2)
                        Text("Careful").tag(3)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ignore text smaller than \(Int(minTextH * 100))% of the screen").font(.subheadline)
                        Slider(value: $minTextH, in: 0...0.08)
                    }
                    TextField("Ignore text containing… (comma separated)", text: $ignoreList, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Reading")
                } footer: {
                    Text("Instant is fastest but may translate half-faded text. Ignore words hide watermarks and usernames, e.g. \"subscribe, @channel\".")
                }

                Section("Floating window") {
                    Picker("Window size", selection: $winSize) {
                        ForEach(WindowSize.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Appearance", selection: $theme) {
                        ForEach(PiPTheme.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Text size", selection: $textSize) {
                        ForEach(PiPTextSize.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Font", selection: $pipFont) {
                        ForEach(PiPFont.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Toggle("Show original text", isOn: $showOriginal)
                    Toggle("Open automatically when capture starts", isOn: $autoOpenPiP)
                    Toggle("Clear when text ends", isOn: $autoClear)
                    if autoClear {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Keep the translation \(String(format: "%.1f", clearHold)) s after the text ends")
                                .font(.subheadline)
                            Slider(value: $clearHold, in: 0...5, step: 0.5)
                        }
                    }
                }

                Section("Speech") {
                    Toggle("Speak translation aloud", isOn: $speak)
                }

                Section {
                    TextEditor(text: $glossary)
                        .frame(minHeight: 90)
                        .font(.system(.footnote, design: .monospaced))
                        .scrollContentBackground(.hidden)
                } header: {
                    Text("Glossary")
                } footer: {
                    Text("One per line, written as word=replacement. Applied to the finished translation, e.g. Lord Subaru=Subaru")
                }

                Section("Version") {
                    LabeledContent("App", value: AppVersion.full)
                    LabeledContent("Capture extension",
                                   value: engine.extensionVersion == "–" ? "not seen yet" : "v\(engine.extensionVersion)")
                }
                Section("Changelog") {
                    ForEach(AppVersion.changelog, id: \.0) { v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("v\(v.0)").bold()
                            Text(v.1).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("How to use") {
                    Text("1. Languages tab → download your source and target packs.\n2. Home → Start. Allow the floating window, then Start Broadcast.\n3. Switch to your app. If nothing shows, use Test translation.")
                        .font(.footnote)
                }
                Section {
                    Button("Reset all settings", role: .destructive) {
                        for k in ["source", "target", "mode", "area", "customY0", "customY1", "speed", "stability",
                                  "minTextH", "ignoreList", "winSize", "theme", "textSize", "pipFont", "showOriginal",
                                  "autoClear", "clearHold", "autoOpenPiP", "speak", "glossary"] {
                            UserDefaults.standard.removeObject(forKey: k)
                        }
                        engine.sourceCode = "auto"; engine.targetCode = "en"
                        engine.syncConfig(); engine.applyStyle(); engine.applyWindowSize()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .onChange(of: readingKey) { _, _ in engine.syncConfig() }
            .onChange(of: styleKey) { _, _ in engine.applyStyle() }
            .onChange(of: winSize) { _, _ in engine.applyWindowSize() }
        }
    }
}

// MARK: - History
struct HistoryView: View {
    @EnvironmentObject var engine: TranslatorEngine

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Everything that was translated, newest first. Tap a line to copy its translation.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(engine.history) { h in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(h.translated).font(.body.weight(.semibold))
                        Text(h.original).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { UIPasteboard.general.string = h.translated }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: engine.history.map { "\($0.original)\n→ \($0.translated)" }.joined(separator: "\n\n"))
                        .disabled(engine.history.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { engine.history.removeAll() }
                }
            }
        }
    }
}
