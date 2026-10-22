// ScreenLingo – App UI – v0.7.0
import SwiftUI
import ReplayKit
import Translation

@main
struct ScreenLingoApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}

// MARK: - Theme
enum Theme {
    static let bg = Color(red: 0.025, green: 0.035, blue: 0.065)
    static let card = Color.white.opacity(0.07)
    static let gradient = LinearGradient(
        colors: [Color(red: 0.12, green: 0.82, blue: 0.72), Color(red: 0.22, green: 0.48, blue: 1)],
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
        .tint(Color(red: 0.12, green: 0.82, blue: 0.72))
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
                preview
                settings
                startButton
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

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ScreenLingo").font(.title.bold())
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
                    ForEach(TranslateMode.allCases) { item in
                            let title: String = item.title
                            let value: String = item.rawValue
                            Text(title).tag(value)
                        }
                }.pickerStyle(.menu).labelsHidden().tint(.secondary)
            }
            Divider().overlay(Color.white.opacity(0.06))
            SettingRow(icon: "viewfinder", tint: .purple, title: "OCR area") {
                Picker("", selection: $area) {
                    ForEach(OCRArea.allCases) { item in
                            let title: String = item.title
                            let value: String = item.rawValue
                            Text(title).tag(value)
                        }
                }.pickerStyle(.menu).labelsHidden().tint(.secondary)
            }
            Divider().overlay(Color.white.opacity(0.06))
            SettingRow(icon: "rectangle.expand.vertical", tint: .orange, title: "Window size") {
                Picker("", selection: $winSize) {
                    ForEach(WindowSize.allCases) { item in
                            let title: String = item.title
                            let value: String = item.rawValue
                            Text(title).tag(value)
                        }
                }
                .pickerStyle(.menu).labelsHidden().tint(.secondary)
                .onChange(of: winSize) { _, _ in engine.applyWindowSize() }
            }
            Divider().overlay(Color.white.opacity(0.06))
            SettingRow(icon: "speedometer", tint: .green, title: "Speed") {
                Picker("", selection: $speed) {
                    ForEach(SpeedPreset.allCases) { item in
                            let title: String = item.title
                            let value: String = item.rawValue
                            Text(title).tag(value)
                        }
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
                    // Do not launch PiP on the broadcast-picker tap. iOS must first
                    // present its broadcast sheet and start the extension; starting PiP
                    // at the same moment can compete with/interrupt that transition.
                    // TranslatorEngine starts PiP after it receives the extension's first packet.
                    BroadcastPicker().frame(width: 60, height: 60)
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
            HStack(spacing: 8) {
                Button {
                    UIPasteboard.general.string = engine.translated
                    engine.status = "Translation copied"
                } label: {
                    Label("Copy result", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(engine.translated.isEmpty)
                Button {
                    UIPasteboard.general.string = engine.original
                    engine.status = "Original text copied"
                } label: {
                    Label("Copy original", systemImage: "text.quote")
                }
                .buttonStyle(.bordered)
                .disabled(engine.original.isEmpty)
                if !engine.translated.isEmpty {
                    ShareLink(item: engine.translated) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    engine.retranslateLast()
                } label: {
                    Label("Re-translate", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(engine.original.isEmpty)
                Button {
                    engine.clearCurrentTranslation()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(engine.translated.isEmpty)
                Button {
                    engine.retranslateLastFresh()
                } label: {
                    Label("Retry fresh", systemImage: "arrow.trianglehead.2.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(engine.original.isEmpty)
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)
            Toggle("Pause translating", isOn: $engine.paused).font(.footnote)
            if engine.captureAlive {
                Text("OCR \(Int(engine.ocrMs)) ms · translate \(Int(engine.translateMs)) ms · extension memory left \(Int(engine.extFreeMB)) MB")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !engine.lastRaw.isEmpty {
                Text("OCR sees: \(engine.lastRaw)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Button {
                    UIPasteboard.general.string = engine.lastRaw
                    engine.status = "Raw OCR text copied"
                } label: {
                    Label("Copy raw OCR", systemImage: "doc.text")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if engine.lastOutputQuality.hasPrefix("Review") || engine.lastOutputQuality.hasPrefix("Suspicious") {
                Label(engine.lastOutputQuality, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
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
    private func translationModeOption(_ item: TranslateMode) -> some View {
        Text(item.title).tag(item.rawValue)
    }

    private func ocrAreaOption(_ item: OCRArea) -> some View {
        Text(item.title).tag(item.rawValue)
    }

    private func windowSizeOption(_ item: WindowSize) -> some View {
        Text(item.title).tag(item.rawValue)
    }

    private func themeOption(_ item: PiPTheme) -> some View {
        Text(item.title).tag(item.rawValue)
    }

    private func speedPresetOption(_ item: SpeedPreset) -> some View {
        Text(item.title).tag(item.rawValue)
    }

    private func textSizeOption(_ item: PiPTextSize) -> some View {
        Text(item.title).tag(item.rawValue)
    }


    private var confidencePercentage: String { String(Int(ocrConfidence * 100)) + "%" }

    @EnvironmentObject var engine: TranslatorEngine
    @AppStorage("includeDiagnosticText") private var includeDiagnosticText = true
    @State private var diagnosticExportURL: URL?
    @State private var showingDiagnosticExport = false
    @State private var newProfileName = ""
    @State private var showingProfileNamePrompt = false
    @State private var showingImportResult = false
    @State private var importResultMessage = ""
    @AppStorage("theme") private var theme = PiPTheme.dark.rawValue
    @AppStorage("textSize") private var textSize = PiPTextSize.auto.rawValue
    @AppStorage("speak") private var speak = false
    @AppStorage("mode") private var mode = TranslateMode.movie.rawValue
    @AppStorage("area") private var area = OCRArea.smart.rawValue
    @AppStorage("winSize") private var winSize = WindowSize.normal.rawValue
    @AppStorage("showOriginal") private var showOriginal = false
    @AppStorage("speed") private var speed = SpeedPreset.balanced.rawValue
    @AppStorage("autoClear") private var autoClear = true
    @AppStorage("textHoldDuration") private var textHoldDuration: Double = 2.0
    @AppStorage("ocrConfidence") private var ocrConfidence: Double = 0.30
    @AppStorage("languageCorrection") private var languageCorrection = true
    @AppStorage("rightToLeftReading") private var rightToLeftReading = false
    @AppStorage("cleanOCR") private var cleanOCR = true
    @AppStorage("slang") private var slang = true
    @AppStorage("speakerDetect") private var speakerDetect = true
    @AppStorage("langLock") private var langLock = true
    @AppStorage("neverTranslate") private var neverTranslate = ""
    @AppStorage("sourceFixes") private var sourceFixes = ""
    @AppStorage("glossary") private var glossary = ""
    @AppStorage("pipFont") private var pipFont = PiPFont.standard.rawValue
    @AppStorage("highlightNames") private var highlightNames = true

    var body: some View {
        NavigationStack {
            List {
                appBuildSection
                translationPerformanceSection
                textIntelligenceSection
                profilesBackupSection
                floatingWindowSection
                automationSection
                diagnosticsSection
                changelogSection
                privacySection
                resetSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .sheet(isPresented: $showingDiagnosticExport) {
                NavigationStack {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text").font(.largeTitle)
                        Text("Diagnostic report ready").font(.headline)
                        Text("Share or save the full report as a .txt file. It follows your recognized-text privacy setting.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if let diagnosticExportURL {
                            ShareLink(item: diagnosticExportURL) {
                                Label("Share / Save .txt", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent)
                        }
                        Spacer()
                    }.padding()
                    .navigationTitle("Export diagnostics")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showingDiagnosticExport = false } } }
                }.presentationDetents([.medium])
            }
            .alert("Save settings profile", isPresented: $showingProfileNamePrompt) {
                TextField("Profile name", text: $newProfileName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    engine.saveProfile(newProfileName)
                    newProfileName = ""
                }
            } message: {
                Text("Save the current translation, OCR and floating-window settings.")
            }
            .alert("Settings import", isPresented: $showingImportResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importResultMessage)
            }
            .onChange(of: theme) { _, _ in engine.applyStyle() }
            .onChange(of: textSize) { _, _ in engine.applyStyle() }
            .onChange(of: pipFont) { _, _ in engine.applyStyle() }
            .onChange(of: highlightNames) { _, _ in engine.applyStyle() }
            .onChange(of: winSize) { _, _ in engine.applyWindowSize() }
            .onChange(of: speed) { _, _ in engine.syncConfig() }
            .onChange(of: area) { _, _ in engine.syncConfig() }
            .onChange(of: mode) { _, _ in engine.syncConfig() }
            .onChange(of: ocrConfidence) { _, _ in engine.syncConfig() }
            .onChange(of: languageCorrection) { _, _ in engine.syncConfig() }
        }
    }

    private var appBuildSection: some View {
            Section("App & build") {
                LabeledContent("App", value: "ScreenLingo")
                LabeledContent("Version", value: AppVersion.full)
                LabeledContent("Bundle ID", value: "com.diam0ndnex.screenlingo")
                LabeledContent("Capture extension",
                               value: engine.extensionVersion == "–" ? "Not connected" : "v\(engine.extensionVersion)")
                LabeledContent("Capture", value: engine.captureAlive ? "Connected" : "Idle")
            }
    }

    private var translationPerformanceSection: some View {
            Section {
                Picker("Translation mode", selection: $mode) {
                    ForEach(TranslateMode.allCases) { item in
                        translationModeOption(item)
                    }
                }
                Picker("Text capture area", selection: $area) {
                    ForEach(OCRArea.allCases) { item in
                        ocrAreaOption(item)
                    }
                }
                Picker("Performance profile", selection: $speed) {
                    ForEach(SpeedPreset.allCases) { item in
                        speedPresetOption(item)
                    }
                }
                Text(speedDescription)
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Language-aware OCR correction", isOn: $languageCorrection)
                Toggle("Right-to-left manga reading", isOn: $rightToLeftReading)
                Text("Use this for Japanese manga layouts that read right-to-left. Leave it off for subtitles, games, and left-to-right comics.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Minimum OCR confidence")
                        Spacer()
                        Text(confidencePercentage).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $ocrConfidence, in: 0.15...0.75, step: 0.05)
                    Text("Lower values catch faint or stylized text but may include more mistakes. Higher values are stricter and can miss difficult text.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Translation & performance")
            } footer: {
                Text("Fast reduces OCR work for lower latency. Sharp processes larger frames for small text but may use more memory and battery.")
            }
    }

    private var textIntelligenceSection: some View {
        Section {
            Toggle("Clean up OCR mistakes", isOn: $cleanOCR)
            Toggle("Expand chat slang", isOn: $slang)
            Toggle("Preserve speaker names", isOn: $speakerDetect)
            Toggle("Lock detected language", isOn: $langLock)
            VStack(alignment: .leading, spacing: 6) {
                Text("Never translate").font(.subheadline.weight(.medium))
                TextEditor(text: $neverTranslate)
                    .frame(minHeight: 58, maxHeight: 110)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                Text("Names or terms separated by commas or new lines.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Fix OCR source text").font(.subheadline.weight(.medium))
                TextEditor(text: $sourceFixes)
                    .frame(minHeight: 58, maxHeight: 110)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                Text("One correction per line: wrong=right.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Translation glossary").font(.subheadline.weight(.medium))
                TextEditor(text: $glossary)
                    .frame(minHeight: 58, maxHeight: 110)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                Text("One replacement per line: translated term=preferred term.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Text intelligence")
        } footer: {
            Text("These rules run on recognized content before or after translation. They do not change what the screen recorder captures.")
        }
    }

    private var profilesBackupSection: some View {
        Section {
            Button { showingProfileNamePrompt = true } label: {
                Label("Save current settings as profile", systemImage: "square.and.arrow.down")
            }
            if engine.profileNames.isEmpty {
                Text("No saved profiles yet.").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(engine.profileNames, id: \.self) { profile in
                    HStack {
                        Button(profile) { engine.applyProfile(profile) }
                        Spacer()
                        Button(role: .destructive) { engine.deleteProfile(profile) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            ShareLink(item: engine.exportSettings()) {
                Label("Export settings backup", systemImage: "square.and.arrow.up")
            }
            Button {
                let clipboard = UIPasteboard.general.string ?? ""
                let success = engine.importSettings(clipboard)
                importResultMessage = success ? "Settings imported successfully." : "No valid ScreenLingo settings backup was found on the clipboard."
                showingImportResult = true
            } label: {
                Label("Import backup from clipboard", systemImage: "doc.on.clipboard")
            }
        } header: {
            Text("Profiles & backup")
        } footer: {
            Text("Backups contain preferences and saved profiles, not translation history or screen content.")
        }
    }

    private var floatingWindowSection: some View {
            Section("Floating window") {
                Picker("Window size", selection: $winSize) {
                    ForEach(WindowSize.allCases) { item in
                        windowSizeOption(item)
                    }
                }
                Picker("Appearance", selection: $theme) {
                    ForEach(PiPTheme.allCases) { item in
                        themeOption(item)
                    }
                }
                Picker("Text size", selection: $textSize) {
                    ForEach(PiPTextSize.allCases) { item in
                        textSizeOption(item)
                    }
                }
                Picker("Translation font", selection: $pipFont) {
                    ForEach(PiPFont.allCases) { font in Text(font.title).tag(font.rawValue) }
                }
                Toggle("Highlight speaker names", isOn: $highlightNames)
                Toggle("Show original above translation", isOn: $showOriginal)
                Toggle("Speak translations aloud", isOn: $speak)
            }
    }

    private var automationSection: some View {
        Section {
            Toggle("Clear when text disappears", isOn: $autoClear)
            if autoClear {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Keep text visible after it disappears")
                        Spacer()
                        Text(textHoldDuration == 0 ? "Immediately" : String(format: "%.1f s", textHoldDuration))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $textHoldDuration, in: 0...10, step: 0.5)
                    Text("Keeps the last translation on screen briefly after the source text vanishes. New text cancels the countdown.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Pause translation", isOn: $engine.paused)
        } header: {
            Text("Automation")
        } footer: {
            Text("Pause keeps the broadcast connected but stops new translation work. Your selected options are saved on this device.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            LabeledContent("Pipeline phase", value: engine.capturePhase)
            LabeledContent("App UDP listener", value: engine.serverReady ? "Ready" : "Not ready")
            LabeledContent("Capture extension", value: engine.captureAlive ? "Connected" : "No packets")
            LabeledContent("PiP state", value: engine.pipActive ? "Active" : "Inactive")
            LabeledContent("Extension version", value: engine.extensionVersion)
            LabeledContent("Last packet kind", value: engine.lastPacketKind)
            LabeledContent("Last packet", value: engine.lastPacketSummary)
            LabeledContent("Last packet age", value: engine.lastPacketAge < 0 ? "Never" : String(format: "%.2f s", engine.lastPacketAge))
            LabeledContent("Packets received", value: "\(engine.totalPackets)")
            LabeledContent("Ping / OCR / clear", value: "\(engine.pingPackets) / \(engine.ocrPackets) / \(engine.clearPackets)")
            LabeledContent("Frames reported", value: "\(engine.frames)")
            LabeledContent("OCR passes", value: "\(engine.ocrCount)")
            LabeledContent("Raw OCR lines", value: "\(engine.lastOCRLineCount)")
            LabeledContent("OCR latency", value: String(format: "%.1f ms", engine.ocrMs))
            LabeledContent("Translation latency", value: String(format: "%.1f ms", engine.translateMs))
            LabeledContent("Extension free memory", value: String(format: "%.1f MB", engine.extFreeMB))
            LabeledContent("Source language", value: engine.lastDetectedLanguage)
            LabeledContent("Target language", value: engine.targetCode)
            LabeledContent("Selected blocks", value: "\(engine.selectedBlockCount)")
            LabeledContent("OCR filter counts", value: engine.lastFilterSummary)
            LabeledContent("Accepted inputs", value: "\(engine.acceptedInputCount)")
            LabeledContent("Waiting for stabilization", value: "\(engine.stabilizationWaitCount)")
            LabeledContent("Stale results discarded", value: "\(engine.discardedStaleCount)")
            LabeledContent("Translation cache hits", value: "\(engine.cacheHits)")
            LabeledContent("Translation failures", value: "\(engine.translationFailures)")
            LabeledContent("Output quality", value: engine.lastOutputQuality)
            LabeledContent("Last translation error", value: engine.lastTranslationError)
            LabeledContent("Current status", value: engine.status)

            DisclosureGroup("Last raw OCR text") {
                Text(engine.lastRaw.isEmpty ? "No OCR received yet." : engine.lastRaw)
                    .font(.footnote).textSelection(.enabled)
            }
            DisclosureGroup("Latest candidate text") {
                Text(engine.lastCandidateText.isEmpty ? "No candidate yet." : engine.lastCandidateText)
                    .font(.footnote).textSelection(.enabled)
            }
            DisclosureGroup("Selected blocks / reading order") {
                Text(engine.lastSelectedBlocks.isEmpty ? "No blocks selected." : engine.lastSelectedBlocks)
                    .font(.footnote).textSelection(.enabled)
            }
            DisclosureGroup("Translation input") {
                Text(engine.lastTranslationInput.isEmpty ? "No translation input yet." : engine.lastTranslationInput)
                    .font(.footnote).textSelection(.enabled)
            }
            DisclosureGroup("Current original") {
                Text(engine.original.isEmpty ? "No original text yet." : engine.original)
                    .font(.footnote).textSelection(.enabled)
            }
            DisclosureGroup("Current translation") {
                Text(engine.translated.isEmpty ? "No translation yet." : engine.translated)
                    .font(.footnote).textSelection(.enabled)
            }
            DisclosureGroup("Processing trace — last 60 seconds") {
                Text(engine.processingTrace.isEmpty ? "No processing trace yet. Start capture and wait for text to appear." : engine.processingTrace.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("Recent diagnostic events (latest first)") {
                if engine.diagnosticEvents.isEmpty {
                    Text("No diagnostic events yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(engine.diagnosticEvents.reversed().enumerated()), id: \.offset) { item in
                        Text(item.element).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).padding(.vertical, 2)
                    }
                }
            }

            Button("Run translation test") { engine.runTest() }
            Button("Refresh language availability") {
                Task { await engine.refreshStatus() }
            }
            Button("Clear translation cache") { engine.clearTranslationCache() }
            Button("Clear diagnostic event log", role: .destructive) { engine.clearDiagnosticEvents() }
            Toggle("Include recognized text in reports", isOn: $includeDiagnosticText)
            Text(includeDiagnosticText
                 ? "Reports include actual OCR, source dialogue, and translated text. Check before sharing."
                 : "Text content is redacted. Coordinates, timestamps, block geometry, filter decisions, and language scores remain available.")
                .font(.footnote).foregroundStyle(.secondary)
            Button {
                let report = engine.copyDetailedDiagnosticReport(
                    includeRecognizedText: includeDiagnosticText,
                    compact: true
                )
                let chatPrompt = """
                Please diagnose this ScreenLingo live-translation issue using the report below. Base conclusions on evidence in the trace; do not assume a fix worked unless the report verifies it.

                Focus on:
                1. OCR reading ScreenLingo UI/PiP output (for example Home, Settings, History, or "pt → en") instead of only the video.
                2. Duplicate subtitle copies at different positions producing overlapping blocks sent for translation.
                3. PiP/self-output feedback filtering that appears ineffective.
                4. In movie mode, suppress interface text and choose one clearest, most complete source-language subtitle block.
                5. Concrete fixes at the correct pipeline stage and diagnostics to verify them, without regressing games, manga, or other OCR modes.

                DIAGNOSTIC REPORT
                ----------------
                \(report)
                """
                UIPasteboard.general.string = chatPrompt
                engine.status = "ChatGPT-ready diagnostic report copied"
            } label: {
                Label("Copy report for ChatGPT", systemImage: "text.bubble")
            }
            Button("Copy compact report (last 60 seconds)") {
                UIPasteboard.general.string = engine.copyDetailedDiagnosticReport(includeRecognizedText: includeDiagnosticText, compact: true)
                engine.status = "Compact diagnostic report copied"
            }
            Button("Export full diagnostic report (.txt)") {
                let report = engine.copyDetailedDiagnosticReport(includeRecognizedText: includeDiagnosticText, compact: false)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenLingo-Diagnostics-\(stamp).txt")
                do {
                    try Data(report.utf8).write(to: url, options: .atomic)
                    diagnosticExportURL = url
                    showingDiagnosticExport = true
                    engine.status = "Full diagnostic report ready to share"
                } catch {
                    engine.status = "Could not export report: \(error.localizedDescription)"
                }
            }
        } header: {
            Text("Live diagnostics")
        } footer: {
            Text("Compact reports include only the last 60 seconds and are capped at 15,000 characters. Export the fuller trace history as a .txt file for deeper debugging. The recognized-text toggle applies to both exports.")
        }
    }

    private var changelogSection: some View {
            Section("Changelog") {
                ForEach(AppVersion.changelog, id: \.0) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("v\(v.0)").bold()
                        Text(v.1).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
    }

    private var privacySection: some View {
            Section("Privacy") {
                Label("On-device translation", systemImage: "iphone")
                Text("ScreenLingo uses Apple's on-device Translation framework and stores translation history in local app preferences. This project does not upload your recognized text to a translation server.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
    }

    private var resetSection: some View {
            Section("Reset") {
                Button("Reset all settings", role: .destructive) {
                    for key in ["source", "target", "mode", "area", "winSize", "showOriginal", "speed", "autoClear", "ocrConfidence", "languageCorrection", "rightToLeftReading", "theme", "textSize", "speak"] {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                    engine.sourceCode = "auto"
                    engine.targetCode = "en"
                    mode = TranslateMode.movie.rawValue
                    area = OCRArea.smart.rawValue
                    winSize = WindowSize.normal.rawValue
                    showOriginal = false
                    speed = SpeedPreset.balanced.rawValue
                    autoClear = true
                    theme = PiPTheme.dark.rawValue
                    textSize = PiPTextSize.auto.rawValue
                    speak = false
                    engine.paused = false
                    engine.syncConfig()
                    engine.applyWindowSize()
                    engine.applyStyle()
                }
            }
    }
    private var speedDescription: String {
        switch SpeedPreset(rawValue: speed) ?? .balanced {
        case .fast: "Lowest latency and lighter CPU use; best for fast dialogue."
        case .balanced: "Recommended balance between text detail, responsiveness, and battery."
        case .sharp: "Higher OCR resolution for small subtitles and dense game text; more demanding."
        }
    }
}

// MARK: - History
struct HistoryView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @State private var query = ""
    @State private var showingClearConfirmation = false

    private var filteredHistory: [HistoryItem] {
        guard !query.isEmpty else { return engine.history }
        return engine.history.filter {
            $0.original.localizedCaseInsensitiveContains(query) ||
            $0.translated.localizedCaseInsensitiveContains(query)
        }
    }

    private var exportText: String {
        engine.history.map {
            "[\($0.date.formatted(date: .abbreviated, time: .shortened))]\nOriginal: \($0.original)\nTranslation: \($0.translated)"
        }.joined(separator: "\n\n──────────\n\n")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Saved locally on this device. Search by source or translation, copy either version, or export the full history.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !engine.history.isEmpty {
                        Text("\(filteredHistory.count) of \(engine.history.count) entries")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(filteredHistory) { h in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(h.translated).font(.body.weight(.semibold)).textSelection(.enabled)
                        Text(h.original).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Text(h.date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = h.translated
                            } label: { Label("Translation", systemImage: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            Button {
                                UIPasteboard.general.string = h.original
                            } label: { Label("Original", systemImage: "text.quote") }
                            .buttonStyle(.borderless)
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .searchable(text: $query, prompt: "Search original or translation")
            .navigationTitle("History")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !engine.history.isEmpty {
                        ShareLink(item: exportText) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Button("Clear", role: .destructive) { showingClearConfirmation = true }
                    }
                }
            }
            .confirmationDialog("Delete all translation history?", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
                Button("Delete all history", role: .destructive) { engine.history.removeAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
            .overlay {
                if engine.history.isEmpty {
                    ContentUnavailableView("No translations yet",
                                           systemImage: "text.bubble",
                                           description: Text("Start screen capture and your recent translations will appear here."))
                } else if filteredHistory.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }
}
