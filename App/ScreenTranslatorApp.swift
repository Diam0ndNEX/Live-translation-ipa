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
        NavigationStack {
            List {
                appBuildSection
                translationSection
                floatingSection
                automationSection
                diagnosticsSection
                changelogSection
                privacySection
                resetSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .onChange(of: theme) { _, _ in engine.applyStyle() }
            .onChange(of: textSize) { _, _ in engine.applyStyle() }
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

    private var translationSection: some View {
            Section {
                Picker("Translation mode", selection: $mode) {
                    ForEach(TranslateMode.allCases) { item in
                        let title: String = item.title
                        let value: String = item.rawValue
                        Text(title).tag(value)
                    }
                }
                Picker("Text capture area", selection: $area) {
                    ForEach(OCRArea.allCases) { item in
                        let title: String = item.title
                        let value: String = item.rawValue
                        Text(title).tag(value)
                    }
                }
                Picker("Performance profile", selection: $speed) {
                    ForEach(SpeedPreset.allCases) { item in
                        let title: String = item.title
                        let value: String = item.rawValue
                        Text(title).tag(value)
                    }
                }
                Text(speedDescription)
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Language-aware OCR correction", isOn: $languageCorrection)
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

    private var floatingSection: some View {
            Section("Floating window") {
                Picker("Window size", selection: $winSize) {
                    ForEach(WindowSize.allCases) { item in
                        let title: String = item.title
                        let value: String = item.rawValue
                        Text(title).tag(value)
                    }
                }
                Picker("Appearance", selection: $theme) {
                    ForEach(PiPTheme.allCases) { item in
                        let title: String = item.title
                        let value: String = item.rawValue
                        Text(title).tag(value)
                    }
                }
                Picker("Text size", selection: $textSize) {
                    ForEach(PiPTextSize.allCases) { item in
                        let title: String = item.title
                        let value: String = item.rawValue
                        Text(title).tag(value)
                    }
                }
                Toggle("Show original above translation", isOn: $showOriginal)
                Toggle("Speak translations aloud", isOn: $speak)
            }
    }

    private var automationSection: some View {
            Section("Automation") {
                Toggle("Clear when text disappears", isOn: $autoClear)
                Toggle("Pause translation", isOn: $engine.paused)
            } footer: {
                Text("Pause keeps the broadcast connected but stops new translation work. Your selected options are saved on this device.")
            }
    }

    private var diagnosticsSection: some View {
            Section("Live diagnostics") {
                LabeledContent("Frames", value: "\(engine.frames)")
                LabeledContent("OCR updates", value: "\(engine.ocrCount)")
                LabeledContent("OCR time", value: "\(Int(engine.ocrMs)) ms")
                LabeledContent("Translation time", value: "\(Int(engine.translateMs)) ms")
                LabeledContent("Extension memory free", value: "\(Int(engine.extFreeMB)) MB")
                if !engine.lastRaw.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last OCR text").font(.caption).foregroundStyle(.secondary)
                        Text(engine.lastRaw).font(.footnote).textSelection(.enabled)
                    }
                }
                Button("Run translation test") { engine.runTest() }
                Button("Refresh language availability") {
                    Task { await engine.refreshStatus() }
                }
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
                    for key in ["source", "target", "mode", "area", "winSize", "showOriginal", "speed", "autoClear", "ocrConfidence", "languageCorrection", "theme", "textSize", "speak"] {
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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Saved on this device. Tap a translation to copy it, or use the row actions to copy either version.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(engine.history) { h in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(h.translated).font(.body.weight(.semibold)).textSelection(.enabled)
                        Text(h.original).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Text(h.date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = h.translated
                            } label: {
                                Label("Translation", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            Button {
                                UIPasteboard.general.string = h.original
                            } label: {
                                Label("Original", systemImage: "text.quote")
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) { engine.history.removeAll() }
                        .disabled(engine.history.isEmpty)
                }
            }
            .overlay {
                if engine.history.isEmpty {
                    ContentUnavailableView("No translations yet",
                                           systemImage: "text.bubble",
                                           description: Text("Start screen capture and your recent translations will appear here."))
                }
            }
        }
    }
}
