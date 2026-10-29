// Screen Translator – App – v0.11.0
import SwiftUI

extension View {
    func settingsPage(_ title: String) -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct ResetSection: View {
    @EnvironmentObject var engine: TranslatorEngine
    let keys: [String]
    @State private var confirm = false
    var body: some View {
        Section {
            Button("Reset this page to defaults", role: .destructive) { confirm = true }
        }
        .confirmationDialog("Reset every setting on this page?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { engine.resetKeys(keys) }
        }
    }
}

private struct PresetsLinkRow: View {
    @ObservedObject var store: PresetStore
    var body: some View {
        NavigationLink { PresetManagerView(store: store) } label: {
            HStack {
                Label("Presets", systemImage: "square.stack.3d.up.fill")
                Spacer()
                if let a = store.active {
                    Text(store.isModified ? "\(a.name) · modified" : a.name).font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("\(store.all.count) available").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Settings home
private struct SettingsNavRow<Destination: View>: View {
    let title: String
    let detail: String
    let symbol: String
    let destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 3)
            }
            .contentShape(Rectangle())
        }
    }
}

/// Settings are organized around tasks, not the order features were developed.
/// Search includes previous page names so navigation remains discoverable.
struct SettingsView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @State private var query = ""

    private func matches(_ title: String, _ keywords: String) -> Bool {
        query.isEmpty || (title + " " + keywords).localizedCaseInsensitiveContains(query)
    }

    private var translateMatches: Bool {
        matches("Reading & OCR", "capture movie subtitles frames recognition tracking confirmation")
        || matches("Languages & text rules", "understanding glossary slang protect names source fixes automatic recovery")
        || matches("Translation & memory", "translate ahead pretranslation warm up cache remember SQLite speculative model high fidelity low latency hybrid fast preview refine language packs")
        || matches("Presets", "profiles saved configurations")
    }
    private var subtitleMatches: Bool {
        matches("Floating subtitles", "picture in picture PiP font size theme appearance window")
        || matches("Subtitle timing", "min display clear heartbeat steady captions handoff responsive")
        || matches("Feedback & sharing", "haptics speak copy clipboard voice vibration")
    }
    private var personalizeMatches: Bool {
        matches("App appearance", "interface accent home layout customize cards")
        || matches("Reader & photos", "workspace photo OCR reading")
        || matches("History & storage", "saved translations retention limit delete memory library")
    }
    private var advancedMatches: Bool {
        matches("Performance & battery", "speed cool power thermal idle awake energy")
        || matches("Experimental Features", "smart pipeline beta lyrics incremental PiP advanced rotation")
        || matches("Diagnostics & tests", "metrics benchmark export sessions simulator validation fresh translation")
    }
    private var supportMatches: Bool {
        matches("Privacy", "private session text diagnostic speaker")
        || matches("Backup & restore", "export import reset settings")
        || matches("About & help", "version changelog guide")
    }
    private var anyMatch: Bool {
        translateMatches || subtitleMatches || personalizeMatches || advancedMatches || supportMatches
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        HStack(spacing: 14) {
                            BrandMark().frame(width: 54, height: 54)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Your ScreenLingo").font(.title3.weight(.semibold))
                                Text("Find the settings you need, all in one place.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }

                if translateMatches {
                    Section("Read & translate") {
                        if matches("Reading & OCR", "capture movie subtitles frames recognition tracking confirmation") {
                            SettingsNavRow(title: "Reading & OCR", detail: "Screen area, recognition speed and text tracking",
                                           symbol: "viewfinder", destination: ReadingSettings())
                        }
                        if matches("Languages & text rules", "understanding glossary slang protect names source fixes automatic recovery") {
                            SettingsNavRow(title: "Languages & text rules", detail: "Detection, corrections, glossary and protected names",
                                           symbol: "character.book.closed", destination: IntelligenceSettings())
                        }
                        if matches("Translation & memory", "translate ahead pretranslation warm up cache remember SQLite speculative model high fidelity low latency hybrid fast preview refine language packs") {
                            SettingsNavRow(title: "Translation & memory", detail: "Translation models, fast previews and remembered text",
                                           symbol: "translate", destination: TranslationSettings())
                        }
                        if matches("Presets", "profiles saved configurations") {
                            PresetsLinkRow(store: engine.presets)
                        }
                    }
                }

                if subtitleMatches {
                    Section("Subtitles & output") {
                        if matches("Floating subtitles", "picture in picture PiP font size theme appearance window") {
                            SettingsNavRow(title: "Floating subtitles", detail: "PiP window, typography and subtitle appearance",
                                           symbol: "rectangle.on.rectangle", destination: WindowSettings())
                        }
                        if matches("Subtitle timing", "min display clear heartbeat steady captions handoff responsive") {
                            SettingsNavRow(title: "Subtitle timing", detail: "When captions appear and how they transition",
                                           symbol: "timer", destination: ResponsivenessSettings())
                        }
                        if matches("Feedback & sharing", "haptics speak copy clipboard voice vibration") {
                            SettingsNavRow(title: "Feedback & sharing", detail: "Speech, copying and vibration",
                                           symbol: "speaker.wave.2", destination: FeedbackStorageSettings())
                        }
                    }
                }

                if personalizeMatches {
                    Section("Personalize & library") {
                        if matches("App appearance", "interface accent home layout customize cards") {
                            SettingsNavRow(title: "App appearance", detail: "Colors and Home screen sections",
                                           symbol: "paintpalette", destination: InterfaceSettings())
                        }
                        if matches("Reader & photos", "workspace photo OCR reading") {
                            SettingsNavRow(title: "Reader & photos", detail: "Reading layout and photo translation",
                                           symbol: "text.book.closed", destination: ReaderWorkspaceSettings())
                        }
                        if matches("History & storage", "saved translations retention limit delete memory library") {
                            SettingsNavRow(title: "History & storage", detail: "History retention, memory and storage limits",
                                           symbol: "clock.arrow.circlepath", destination: HistoryStorageSettings())
                        }
                    }
                }

                if advancedMatches {
                    Section("Performance & advanced") {
                        if matches("Performance & battery", "speed cool power thermal idle awake energy") {
                            SettingsNavRow(title: "Performance & battery", detail: "Adaptive performance, heat and idle power",
                                           symbol: "bolt", destination: PerformanceSettings())
                        }
                        if matches("Experimental Features", "smart pipeline beta lyrics incremental PiP advanced rotation") {
                            SettingsNavRow(title: "Experimental Features", detail: "Opt-in features that still need device testing",
                                           symbol: "flask", destination: ExperimentalFeaturesView())
                        }
                        if matches("Diagnostics & tests", "metrics benchmark export sessions simulator validation fresh translation") {
                            SettingsNavRow(title: "Diagnostics & tests", detail: "Collection, controlled comparisons and simulator",
                                           symbol: "waveform.path.ecg", destination: DiagnosticsSettings())
                        }
                    }
                }

                if supportMatches {
                    Section("Privacy & support") {
                        if matches("Privacy", "private session text diagnostic speaker") {
                            SettingsNavRow(title: "Privacy", detail: "Private sessions and diagnostic content",
                                           symbol: "hand.raised", destination: PrivacySettings())
                        }
                        if matches("Backup & restore", "export import reset settings") {
                            SettingsNavRow(title: "Backup & restore", detail: "Export, import and reset settings",
                                           symbol: "square.and.arrow.up", destination: BackupSettings())
                        }
                        if matches("About & help", "version changelog guide") {
                            SettingsNavRow(title: "About & help", detail: "Version, changelog and how to use ScreenLingo",
                                           symbol: "info.circle", destination: AboutSettings())
                        }
                    }
                }
                if query.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            Text(AppVersion.full).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            .overlay { if !anyMatch { ContentUnavailableView.search(text: query) } }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .searchable(text: $query, prompt: "Search settings and features")
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Reading & OCR
struct ReadingSettings: View {
    @EnvironmentObject var engine: TranslatorEngine
    @AppStorage("mode") private var mode = TranslateMode.movie.rawValue
    @AppStorage("area") private var area = OCRArea.smart.rawValue
    @AppStorage("customY0") private var customY0 = 0.0
    @AppStorage("customY1") private var customY1 = 0.5
    @AppStorage("frameRot") private var frameRot = "auto"
    @AppStorage("speed") private var speed = SpeedPreset.balanced.rawValue
    @AppStorage("stability") private var stability = 2
    @AppStorage("minTextH") private var minTextH = 0.0
    @AppStorage("ignoreList") private var ignoreList = ""
    @AppStorage("dropNoise") private var dropNoise = true
    @AppStorage("boost") private var boost = 1
    @AppStorage("skipUnchanged") private var skipUnchanged = true
    @AppStorage("ocrConfidence") private var confidence = 0.3
    @AppStorage("ocrCorrection") private var correction = true
    @AppStorage("adaptiveOCR") private var adaptiveOCR = true
    @AppStorage("subtitleTracking") private var subtitleTracking = true
    @AppStorage("deduplicateCopies") private var deduplicateCopies = true
    @State private var showAreaEditor = false

    private var key: String { "\(mode)|\(area)|\(customY0)|\(customY1)|\(speed)|\(stability)|\(boost)|\(skipUnchanged)|\(confidence)|\(correction)" }
    private var recognitionPolicy: String { "\(adaptiveOCR)|\(subtitleTracking)|\(deduplicateCopies)" }

    var body: some View {
        List {
            Section("What to read") {
                Picker("Mode", selection: $mode) {
                    ForEach(TranslateMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("OCR area", selection: $area) {
                    ForEach(OCRArea.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Button("Visual capture-area editor") { showAreaEditor = true }
                if area == OCRArea.custom.rawValue {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("From \(Int(customY0 * 100))% to \(Int(customY1 * 100))% of the screen height (0% = bottom)")
                            .font(.footnote).foregroundStyle(.secondary)
                        Slider(value: $customY0, in: 0...0.9)
                        Slider(value: $customY1, in: 0.1...1)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ignore text smaller than \(Int(minTextH * 100))% of the screen").font(.subheadline)
                    Slider(value: $minTextH, in: 0...0.08)
                }
                TextField("Ignore text containing… (comma separated)", text: $ignoreList, axis: .vertical)
                    .lineLimit(1...3)
                Toggle("Ignore numbers and symbols", isOn: $dropNoise)
            }

            Section {
                Picker("Frame rotation", selection: $frameRot) {
                    Text("Automatic").tag("auto")
                    Text("None").tag("0")
                    Text("90° clockwise").tag("90")
                    Text("180° (upside down)").tag("180")
                    Text("270° clockwise").tag("270")
                }
            } header: {
                Text("Sentence order")
            } footer: {
                Text("If sentences come out in the wrong order, the capture is probably rotated. Automatic detects this by checking which direction the lines read naturally. Pick a fixed rotation to force it.")
            }

            Section {
                Picker("Speed", selection: $speed) {
                    ForEach(SpeedPreset.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Wait for stable text", selection: $stability) {
                    Text("Instant").tag(1)
                    Text("Normal").tag(2)
                    Text("Careful").tag(3)
                }
                Picker("Contrast boost", selection: $boost) {
                    Text("Off").tag(0)
                    Text("Only when text is hard to find").tag(1)
                    Text("Always").tag(2)
                }
                Toggle("Skip unchanged frames", isOn: $skipUnchanged)
                Toggle("OCR language correction", isOn: $correction)
                VStack(alignment: .leading) {
                    Text("Minimum OCR confidence · \(Int(confidence * 100))%")
                    Slider(value: $confidence, in: 0.1...0.9, step: 0.05)
                }
            } header: {
                Text("Speed & quality")
            } footer: {
                Text("Instant is fastest but may translate half-faded text. Always boosting contrast helps thin or outlined fonts but is slower.")
            }

            Section {
                Toggle("Adaptive detail in Balanced", isOn: $adaptiveOCR)
                Text("Adjusts OCR resolution for small or uncertain subtitles without reducing the base accuracy setting.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Track subtitle position and lifetime", isOn: $subtitleTracking)
                Text("Keeps moving and multi-line subtitles associated across nearby frames.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Merge duplicate OCR copies", isOn: $deduplicateCopies)
                Text("Removes shadow or overlapping copies of the same subtitle, but preserves genuine repeated lyrics.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Recognition intelligence") }
            ResetSection(keys: ["mode", "area", "customY0", "customY1", "frameRot", "speed", "stability",
                                "minTextH", "ignoreList", "dropNoise", "boost", "skipUnchanged", "ocrConfidence", "ocrCorrection",
                                "adaptiveOCR", "subtitleTracking", "deduplicateCopies"])
        }
        .settingsPage("Reading & OCR")
        .sheet(isPresented: $showAreaEditor) { CaptureAreaEditor().environmentObject(engine) }
        .onChange(of: key) { _, _ in engine.syncConfig() }
        .onChange(of: frameRot) { _, _ in engine.rotationSettingChanged() }
        .onChange(of: recognitionPolicy) { _, _ in engine.pipelineSettingsChanged() }
    }
}

// MARK: - Understanding & rules
struct IntelligenceSettings: View {
    @EnvironmentObject var engine: TranslatorEngine
    @AppStorage("cleanOCR") private var cleanOCR = true
    @AppStorage("slang") private var slang = true
    @AppStorage("speakerDetect") private var speakerDetect = true
    @AppStorage("langLock") private var langLock = true
    @AppStorage("neverTranslate") private var neverTranslate = ""
    @AppStorage("sourceFixes") private var sourceFixes = ""
    @AppStorage("glossary") private var glossary = ""
    @AppStorage("contextualLanguage") private var contextualLanguage = true
    @AppStorage("languageRecovery") private var languageRecovery = true

    private func editor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .frame(minHeight: 80)
            .font(.system(.footnote, design: .monospaced))
            .scrollContentBackground(.hidden)
    }

    var body: some View {
        List {
            Section {
                Toggle("Clean up OCR mistakes", isOn: $cleanOCR)
                Toggle("Expand chat slang (pq, vc, tbm, idk…)", isOn: $slang)
                Toggle("Recognize speakers (\"Name: text\")", isOn: $speakerDetect)
                Toggle("Lock detected language", isOn: $langLock)
                Toggle("Use recent context for ambiguous languages", isOn: $contextualLanguage)
                Text("Recent confirmed subtitles can help Automatic recognize a short, ambiguous phrase.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Recover Automatic after repeated failures", isOn: $languageRecovery)
                Text("Rechecks the source language if translation fails repeatedly.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Understanding")
            } footer: {
                Text("Speaker names stay untranslated and each speaker gets their own line. Slang is spelled out before translating so it isn't misread. The language lock stops Automatic from flip-flopping between languages.")
            }
            Section {
                editor($neverTranslate)
            } header: {
                Text("Never translate")
            } footer: {
                Text("Words or names to keep exactly as written, separated by commas or new lines. Example: Subaru, Emilia")
            }
            Section {
                editor($sourceFixes)
            } header: {
                Text("Fix the original text (before translating)")
            } footer: {
                Text("One per line: wrong=right. Example: Rern=Rem")
            }
            Section {
                editor($glossary)
            } header: {
                Text("Fix the translation (after translating)")
            } footer: {
                Text("One per line: word=replacement. Example: Lord Subaru=Subaru")
            }
            ResetSection(keys: ["cleanOCR", "slang", "speakerDetect", "langLock", "contextualLanguage", "languageRecovery",
                                "neverTranslate", "sourceFixes", "glossary"])
        }
        .settingsPage("Languages & text rules")
        .onChange(of: contextualLanguage) { _, _ in engine.pipelineSettingsChanged() }
        .onChange(of: languageRecovery) { _, _ in engine.pipelineSettingsChanged() }
        .onDisappear { engine.reloadSettings() }
    }
}

// MARK: - Floating window
struct WindowSettings: View {
    @EnvironmentObject var engine: TranslatorEngine
    @AppStorage("winSize") private var winSize = WindowSize.normal.rawValue
    @AppStorage("theme") private var theme = PiPTheme.dark.rawValue
    @AppStorage("textSize") private var textSize = PiPTextSize.auto.rawValue
    @AppStorage("pipFont") private var pipFont = PiPFont.standard.rawValue
    @AppStorage("highlightNames") private var highlightNames = true
    @AppStorage("showOriginal") private var showOriginal = false
    @AppStorage("autoOpenPiP") private var autoOpenPiP = true
    @AppStorage("autoClear") private var autoClear = true
    @AppStorage("clearHold") private var clearHold = 1.0

    private var styleKey: String { "\(theme)|\(textSize)|\(pipFont)|\(highlightNames)" }
    private var previewImage: UIImage {
        var style = PiPStyle.make(theme: PiPTheme(rawValue: theme) ?? .dark,
                                  size: PiPTextSize(rawValue: textSize) ?? .auto,
                                  font: PiPFont(rawValue: pipFont) ?? .standard)
        style.highlightNames = highlightNames
        return PiPRenderer.image(original: "Rem: O-o Subaru é filho de um Deus?",
                                 translated: "Rem: W-wait, is Subaru the son of a God? Why didn't he ever tell us?",
                                 showOriginal: showOriginal,
                                 size: (WindowSize(rawValue: winSize) ?? .normal).size, style: style)
    }

    var body: some View {
        List {
            Section("Live preview") {
                Image(uiImage: previewImage)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .listRowInsets(EdgeInsets())
            }
            Section("Appearance") {
                Picker("Window size", selection: $winSize) {
                    ForEach(WindowSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Theme", selection: $theme) {
                    ForEach(PiPTheme.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Text size", selection: $textSize) {
                    ForEach(PiPTextSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Font", selection: $pipFont) {
                    ForEach(PiPFont.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Colour speaker names", isOn: $highlightNames)
                Toggle("Show original text", isOn: $showOriginal)
                NavigationLink {
                    CaptionAppearanceSettings()
                } label: {
                    Label("Advanced typography & layout", systemImage: "textformat.size")
                }
            }
            Section {
                Toggle("Open PiP when capture starts", isOn: $autoOpenPiP)
                Toggle("Clear subtitle when text ends", isOn: $autoClear)
                if autoClear {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keep text after it disappears · \(String(format: "%.1f", clearHold)) s")
                            .font(.subheadline)
                        Slider(value: $clearHold, in: 0...5, step: 0.5)
                    }
                }
            } header: { Text("Floating window behavior") } footer: {
                Text("Subtitle timing and transitions are under Subtitle timing; speech, clipboard and vibration are under Feedback & sharing.")
            }
            ResetSection(keys: [
                "winSize", "theme", "textSize", "pipFont", "highlightNames",
                "showOriginal", "autoOpenPiP", "autoClear", "clearHold"
            ])
        }
        .settingsPage("Floating subtitles")
        .onChange(of: styleKey) { _, _ in engine.applyStyle() }
        .onChange(of: showOriginal) { _, _ in engine.applyStyle() }
        .onChange(of: winSize) { _, _ in engine.applyWindowSize() }
    }
}

// MARK: - Interface
struct InterfaceSettings: View {
    @EnvironmentObject var engine: TranslatorEngine
    @AppStorage("accent") private var accent = AccentChoice.blue.rawValue
    @AppStorage("homePresets") private var homePresets = true
    @AppStorage("homeTools") private var homeTools = true
    @AppStorage("homeQuick") private var homeQuick = true
    @AppStorage("homeStatus") private var homeStatus = true
    @AppStorage("homeRecent") private var homeRecent = true
    @AppStorage("homeMetrics") private var homeMetrics = true
    @AppStorage("homeQuickExpanded") private var homeQuickExpanded = false
    @AppStorage("homeDetailsExpanded") private var homeDetailsExpanded = false
    @AppStorage("uiHaptics") private var uiHaptics = true

    var body: some View {
        List {
            Section("Accent color") {
                HStack(spacing: 14) {
                    ForEach(AccentChoice.allCases) { color in
                        Circle()
                            .fill(LinearGradient(colors: [color.start, color.end],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 34, height: 34)
                            .overlay(Circle().stroke(Color.white, lineWidth: accent == color.rawValue ? 3 : 0))
                            .onTapGesture { accent = color.rawValue; engine.tap() }
                            .accessibilityLabel(color.title)
                    }
                }.padding(.vertical, 4)
            }
            Section {
                Toggle("Presets", isOn: $homePresets)
                Toggle("Tools under preview", isOn: $homeTools)
                Toggle("Quick settings", isOn: $homeQuick)
                Toggle("Recent language pairs", isOn: $homeRecent)
                Toggle("Status & diagnostics summary", isOn: $homeStatus)
                Toggle("Show timing cards", isOn: $homeMetrics)
            } header: { Text("Home screen sections") } footer: {
                Text("Hide sections you rarely use for a simpler Home screen.")
            }
            Section {
                Toggle("Keep quick settings expanded", isOn: $homeQuickExpanded)
                    .disabled(!homeQuick)
                Toggle("Keep troubleshooting expanded", isOn: $homeDetailsExpanded)
            } header: { Text("Default layout") }
            Section("App interactions") {
                Toggle("Haptic feedback for taps", isOn: $uiHaptics)
            }
            ResetSection(keys: [
                "accent", "homePresets", "homeTools", "homeQuick", "homeStatus",
                "homeRecent", "homeMetrics", "homeQuickExpanded", "homeDetailsExpanded", "uiHaptics"
            ])
        }
        .settingsPage("App appearance")
    }
}

// MARK: - Performance
struct PerformanceSettings: View {
    @EnvironmentObject var engine: TranslatorEngine
    @AppStorage("suppressOwnInterface") private var suppressOwnInterface = true
    @AppStorage("coolMode") private var coolMode = false
    @AppStorage("smartCool") private var smartCool = true
    @AppStorage("adaptive") private var adaptive = true
    @AppStorage("idleMinutes") private var idleMinutes = 0
    @AppStorage("idleBackoff") private var idleBackoff = true
    @AppStorage("keepAwake") private var keepAwake = true

    var body: some View {
        List {
            Section {
                Toggle("Adapt to device conditions", isOn: $adaptive)
                Text("Reduces work when thermal pressure rises, memory is scarce or Low Power Mode is enabled.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Cool mode", isOn: $coolMode)
                Toggle("Smart Cool controller", isOn: $smartCool)
                    .disabled(!coolMode)
                Text("Smart Cool adapts OCR intervals to measured workload. Fixed Cool uses conservative timing instead. Both can delay very brief subtitles.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Heat & battery") }

            Section {
                Toggle("Reduce OCR when no text is visible", isOn: $idleBackoff)
                Picker("Pause after no text", selection: $idleMinutes) {
                    Text("Never").tag(0)
                    Text("1 minute").tag(1)
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("30 minutes").tag(30)
                }
                Toggle("Keep screen awake during capture", isOn: $keepAwake)
                Toggle("Pause screen reading inside ScreenLingo", isOn: $suppressOwnInterface)
                Text("Avoids translating this app's interface. Turn off to read a video floating over ScreenLingo. Text and photo translation still work.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Idle & screen") } footer: {
                Text("Pausing and reducing OCR during idle periods save power, but can delay the next text detection.")
            }
            ResetSection(keys: ["suppressOwnInterface", "coolMode", "smartCool", "adaptive", "idleMinutes", "idleBackoff", "keepAwake"])
        }
        .settingsPage("Performance & battery")
        .onChange(of: suppressOwnInterface) { _, _ in engine.pipelineSettingsChanged() }
        .onChange(of: adaptive) { _, _ in engine.syncConfig() }
        .onChange(of: idleBackoff) { _, _ in engine.syncConfig() }
        .onChange(of: smartCool) { _, _ in engine.pipelineSettingsChanged() }
        .onChange(of: coolMode) { _, _ in engine.powerPolicyChanged() }
    }
}

// MARK: - Backup & reset
struct BackupSettings: View {
    @EnvironmentObject var engine: TranslatorEngine
    @State private var message = ""
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                Button { Sharer.shareFile(text: engine.exportSettings(), name: "screen-translator-settings.json") } label: {
                    Label("Share all settings", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = engine.exportSettings()
                    message = "Settings copied to the clipboard."
                } label: { Label("Copy all settings", systemImage: "doc.on.doc") }
                Button {
                    message = engine.importSettings(UIPasteboard.general.string ?? "")
                        ? "Settings imported from the clipboard."
                        : "The clipboard doesn't contain exported settings."
                } label: { Label("Import settings from clipboard", systemImage: "square.and.arrow.down") }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Settings backup")
            } footer: {
                Text("Export, copy the text somewhere safe, and import it again to restore. Presets have their own export on the Presets page.")
            }
            Section {
                Button("Reset every setting", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Presets and history are kept.")
            }
        }
        .settingsPage("Backup & reset")
        .confirmationDialog("Reset every setting to its default?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset every setting", role: .destructive) { engine.resetAllSettings() }
        }
    }
}

// MARK: - About
struct AboutSettings: View {
    @EnvironmentObject var engine: TranslatorEngine
    @AppStorage("onboarded") private var onboarded = true

    var body: some View {
        List {
            Section("Version") {
                LabeledContent("App", value: AppVersion.full)
                LabeledContent("Capture extension",
                               value: engine.extensionVersion == "–" ? "not seen yet" : "v\(engine.extensionVersion)")
            }
            Section("How to use") {
                Text("1. Languages tab → download your source and target packs.\n2. Home → tap the broadcast icon, choose ScreenLingo Capture, Start Broadcast.\n3. Switch to your app. If nothing shows, use Test on the Home screen and check the Diagnostics tab.")
                    .font(.footnote)
                Button("Show the welcome tour again") { onboarded = false }
            }
            Section("Changelog") {
                ForEach(AppVersion.changelog, id: \.1) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("v\(v.0)").bold()
                        Text(v.1).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .settingsPage("About & help")
    }
}

struct PrivacySettings: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @AppStorage("privateSession") private var privateSession = false
    @AppStorage("diagIncludeText") private var includeText = false
    @AppStorage("showSessionSpeakers") private var showSpeakers = true

    var body: some View {
        List {
            Section {
                Toggle("Private session", isOn: $privateSession)
                Text("New translations are not added to History or persistent translation memory. Previously saved entries remain.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Translation privacy") }
            Section {
                Toggle("Show recognized speaker labels", isOn: $showSpeakers)
                Text("Only detects visible Name: labels; this does not identify voices or unnamed people.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Include recognized names and text in diagnostics", isOn: $includeText)
                Text("Leave off unless you specifically need text in a troubleshooting export. OCR and translation run on-device.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Personal content") }
            Section {
                NavigationLink {
                    HistoryStorageSettings()
                } label: {
                    Label("Manage stored history", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink {
                    MemoryManagementView()
                } label: {
                    Label("Manage translation memory", systemImage: "externaldrive")
                }
            } header: { Text("Review local data") }
            ResetSection(keys: ["privateSession", "diagIncludeText", "showSessionSpeakers"])
        }
        .settingsPage("Privacy")
    }
}

/// Collection is independent of which diagnostics page happens to be visible.
struct DiagnosticsCollectionControls: View {
    @AppStorage("diagnosticsEnabled") private var enabled = true
    @AppStorage("detailedCollection") private var detailed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Simple diagnostics", isOn: $enabled)
            Toggle("Detailed diagnostics", isOn: $detailed).disabled(!enabled)
            Text(enabled ? (detailed ? "Records summary counters, graphs, device samples and events." : "Summary counters only. Graph sampling, device polling and event history are off.") : "Diagnostic collection is off. Capture and translation continue.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Changing collection starts a fresh diagnostic session. Detailed collection requires Simple diagnostics.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
