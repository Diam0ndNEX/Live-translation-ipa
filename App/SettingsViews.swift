// Screen Translator – App – v0.9.0
import SwiftUI

private extension View {
    func settingsPage(_ title: String) -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ResetSection: View {
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
struct SettingsView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @State private var query = ""

    private func show(_ title: String, _ keywords: String) -> Bool {
        query.isEmpty || (title + " " + keywords).localizedCaseInsensitiveContains(query)
    }

    private var anyMatch: Bool {
        show("Presets", "save profile custom switch")
            || show("Reading & OCR", "mode area custom rotation order speed stability ignore noise contrast frames words small")
            || show("Understanding & rules", "clean slang speaker language lock never translate glossary fixes names")
            || show("Floating window", "size theme colour font text original auto open clear hold display vibrate speak voice copy preview")
            || show("Interface", "accent colour home sections haptics keep awake history save")
            || show("Performance & power", "adaptive battery idle pause thermal hot")
            || show("Backup & reset", "export import backup restore reset")
            || show("About & help", "version changelog help how")
    }

    var body: some View {
        NavigationStack {
            List {
                if show("Presets", "save profile custom switch") {
                    Section { PresetsLinkRow(store: engine.presets) }
                }
                Section {
                    if show("Reading & OCR", "mode area custom rotation order speed stability ignore noise contrast frames words small") {
                        NavigationLink { ReadingSettings() } label: { Label("Reading & OCR", systemImage: "viewfinder") }
                    }
                    if show("Understanding & rules", "clean slang speaker language lock never translate glossary fixes names") {
                        NavigationLink { IntelligenceSettings() } label: { Label("Understanding & rules", systemImage: "brain") }
                    }
                    if show("Floating window", "size theme colour font text original auto open clear hold display vibrate speak voice copy preview") {
                        NavigationLink { WindowSettings() } label: { Label("Floating window", systemImage: "rectangle.on.rectangle") }
                    }
                    if show("Interface", "accent colour home sections haptics keep awake history save") {
                        NavigationLink { InterfaceSettings() } label: { Label("Interface", systemImage: "paintbrush.fill") }
                    }
                    if show("Performance & power", "adaptive battery idle pause thermal hot") {
                        NavigationLink { PerformanceSettings() } label: { Label("Performance & power", systemImage: "bolt.fill") }
                    }
                    if show("Backup & reset", "export import backup restore reset") {
                        NavigationLink { BackupSettings() } label: { Label("Backup & reset", systemImage: "externaldrive.fill") }
                    }
                    if show("About & help", "version changelog help how") {
                        NavigationLink { AboutSettings() } label: { Label("About & help", systemImage: "info.circle") }
                    }
                } footer: {
                    Text(AppVersion.full)
                }
            }
            .overlay { if !anyMatch { ContentUnavailableView.search(text: query) } }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .searchable(text: $query, prompt: "Search settings")
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

    private var key: String { "\(mode)|\(area)|\(customY0)|\(customY1)|\(speed)|\(stability)|\(boost)|\(skipUnchanged)" }

    var body: some View {
        List {
            Section("What to read") {
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
            } header: {
                Text("Speed & quality")
            } footer: {
                Text("Instant is fastest but may translate half-faded text. Always boosting contrast helps thin or outlined fonts but is slower.")
            }

            ResetSection(keys: ["mode", "area", "customY0", "customY1", "frameRot", "speed", "stability",
                                "minTextH", "ignoreList", "dropNoise", "boost", "skipUnchanged"])
        }
        .settingsPage("Reading & OCR")
        .onChange(of: key) { _, _ in engine.syncConfig() }
        .onChange(of: frameRot) { _, _ in engine.rotationSettingChanged() }
    }
}

// MARK: - Understanding & rules
struct IntelligenceSettings: View {
    @AppStorage("cleanOCR") private var cleanOCR = true
    @AppStorage("slang") private var slang = true
    @AppStorage("speakerDetect") private var speakerDetect = true
    @AppStorage("langLock") private var langLock = true
    @AppStorage("neverTranslate") private var neverTranslate = ""
    @AppStorage("sourceFixes") private var sourceFixes = ""
    @AppStorage("glossary") private var glossary = ""

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
            ResetSection(keys: ["cleanOCR", "slang", "speakerDetect", "langLock", "neverTranslate", "sourceFixes", "glossary"])
        }
        .settingsPage("Understanding & rules")
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
    @AppStorage("minDisplay") private var minDisplay = 0.0
    @AppStorage("haptics") private var haptics = false
    @AppStorage("speak") private var speak = false
    @AppStorage("speechRate") private var speechRate = 0.5
    @AppStorage("autoCopy") private var autoCopy = false

    private var styleKey: String { "\(theme)|\(textSize)|\(pipFont)|\(highlightNames)" }

    private var previewImage: UIImage {
        var st = PiPStyle.make(theme: PiPTheme(rawValue: theme) ?? .dark,
                               size: PiPTextSize(rawValue: textSize) ?? .auto,
                               font: PiPFont(rawValue: pipFont) ?? .standard)
        st.highlightNames = highlightNames
        return PiPRenderer.image(original: "Rem: O-o Subaru é filho de um Deus?",
                                 translated: "Rem: W-wait, is Subaru the son of a God? Why didn't he ever tell us?",
                                 showOriginal: showOriginal,
                                 size: (WindowSize(rawValue: winSize) ?? .normal).size, style: st)
    }

    var body: some View {
        List {
            Section("Preview") {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .listRowInsets(EdgeInsets())
            }
            Section("Look") {
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
                Toggle("Colour speaker names", isOn: $highlightNames)
                Toggle("Show original text", isOn: $showOriginal)
            }
            Section {
                Toggle("Open automatically when capture starts", isOn: $autoOpenPiP)
                Toggle("Clear when text ends", isOn: $autoClear)
                if autoClear {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keep the translation \(String(format: "%.1f", clearHold)) s after the text ends")
                            .font(.subheadline)
                        Slider(value: $clearHold, in: 0...5, step: 0.5)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Show each translation at least \(String(format: "%.1f", minDisplay)) s").font(.subheadline)
                    Slider(value: $minDisplay, in: 0...4, step: 0.5)
                }
            } header: {
                Text("Behaviour")
            } footer: {
                Text("A minimum display time stops fast-changing text from flickering past before you can read it.")
            }
            Section("Feedback") {
                Toggle("Vibrate on new translation", isOn: $haptics)
                Toggle("Copy every translation to the clipboard", isOn: $autoCopy)
                Toggle("Speak translation aloud", isOn: $speak)
                if speak {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Speaking speed").font(.subheadline)
                        Slider(value: $speechRate, in: 0.3...0.65)
                    }
                }
            }
            ResetSection(keys: ["winSize", "theme", "textSize", "pipFont", "highlightNames", "showOriginal", "autoOpenPiP",
                                "autoClear", "clearHold", "minDisplay", "haptics", "speak", "speechRate", "autoCopy"])
        }
        .settingsPage("Floating window")
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
    @AppStorage("uiHaptics") private var uiHaptics = true
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("saveHistory") private var saveHistory = true
    @State private var confirmClear = false

    var body: some View {
        List {
            Section("Accent colour") {
                HStack(spacing: 14) {
                    ForEach(AccentChoice.allCases) { a in
                        Circle()
                            .fill(LinearGradient(colors: [a.start, a.end], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 34, height: 34)
                            .overlay(Circle().stroke(Color.white, lineWidth: accent == a.rawValue ? 3 : 0))
                            .onTapGesture { accent = a.rawValue; engine.tap() }
                            .accessibilityLabel(a.title)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Toggle("Presets", isOn: $homePresets)
                Toggle("Tools under the preview", isOn: $homeTools)
                Toggle("Quick settings", isOn: $homeQuick)
                Toggle("Recent language pairs", isOn: $homeRecent)
                Toggle("Status & diagnostics summary", isOn: $homeStatus)
            } header: {
                Text("Home screen")
            } footer: {
                Text("Hide what you don't use for a calmer Home screen.")
            }
            Section("Behaviour") {
                Toggle("Tap feedback (haptics)", isOn: $uiHaptics)
                Toggle("Keep screen awake while capturing", isOn: $keepAwake)
            }
            Section {
                Toggle("Remember history between launches", isOn: $saveHistory)
                Button("Clear all history", role: .destructive) { confirmClear = true }
            } header: {
                Text("History")
            }
            ResetSection(keys: ["accent", "homePresets", "homeTools", "homeQuick", "homeStatus", "homeRecent",
                                "uiHaptics", "keepAwake", "saveHistory"])
        }
        .settingsPage("Interface")
        .onChange(of: saveHistory) { _, on in
            if !on { UserDefaults.standard.removeObject(forKey: "historyData") }
        }
        .confirmationDialog("Delete every translation in History?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear all history", role: .destructive) { engine.history.removeAll(); engine.toast("History cleared") }
        }
    }
}

// MARK: - Performance
struct PerformanceSettings: View {
    @EnvironmentObject var engine: TranslatorEngine
    @AppStorage("adaptive") private var adaptive = true
    @AppStorage("idleMinutes") private var idleMinutes = 0

    var body: some View {
        List {
            Section {
                Toggle("Adaptive performance", isOn: $adaptive)
                Picker("Pause after no text for", selection: $idleMinutes) {
                    Text("Never").tag(0)
                    Text("1 minute").tag(1)
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("30 minutes").tag(30)
                }
            } footer: {
                Text("Adaptive performance reads less often when the phone gets hot, Low Power Mode is on, or the capture extension is running low on memory. Auto-pause saves battery during long gaps.")
            }
            Section {
                Button("Reset diagnostics counters") { engine.diag.reset(); engine.toast("Counters reset") }
            }
            ResetSection(keys: ["adaptive", "idleMinutes"])
        }
        .settingsPage("Performance & power")
        .onChange(of: adaptive) { _, _ in engine.syncConfig() }
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
                ShareLink(item: engine.exportSettings()) { Label("Export all settings", systemImage: "square.and.arrow.up") }
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
                Text("1. Languages tab → download your source and target packs.\n2. Home → tap the broadcast icon, choose Translator Capture, Start Broadcast.\n3. Switch to your app. If nothing shows, use Test on the Home screen and check the Diagnostics tab.")
                    .font(.footnote)
                Button("Show the welcome tour again") { onboarded = false }
            }
            Section("Changelog") {
                ForEach(AppVersion.changelog, id: \.0) { v in
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
