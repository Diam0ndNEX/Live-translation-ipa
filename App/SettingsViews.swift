// Screen Translator – App – v0.8.0
import SwiftUI

private extension View {
    func settingsPage(_ title: String) -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Settings home
struct SettingsView: View {
    @EnvironmentObject var engine: TranslatorEngine

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { ReadingSettings() } label: { Label("Reading & OCR", systemImage: "viewfinder") }
                    NavigationLink { IntelligenceSettings() } label: { Label("Understanding & rules", systemImage: "brain") }
                    NavigationLink { WindowSettings() } label: { Label("Floating window", systemImage: "rectangle.on.rectangle") }
                    NavigationLink { PerformanceSettings() } label: { Label("Performance & power", systemImage: "bolt.fill") }
                    NavigationLink { ProfilesSettings() } label: { Label("Profiles & backup", systemImage: "square.stack.3d.up") }
                    NavigationLink { PrivacySettings() } label: { Label("Privacy & history", systemImage: "hand.raised") }
                    NavigationLink { AboutSettings() } label: { Label("About & help", systemImage: "info.circle") }
                } footer: {
                    Text(AppVersion.full)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
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
                Text("If sentences come out in the wrong order, the capture is probably rotated. Automatic detects this by checking which direction the lines read naturally. Pick a fixed rotation if you want to force it.")
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
        }
        .settingsPage("Reading & OCR")
        .onChange(of: key) { _, _ in engine.syncConfig() }
        .onChange(of: frameRot) { _, _ in engine.syncConfig() }
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

    private var styleKey: String { "\(theme)|\(textSize)|\(pipFont)|\(highlightNames)" }

    var body: some View {
        List {
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
                Toggle("Speak translation aloud", isOn: $speak)
            }
        }
        .settingsPage("Floating window")
        .onChange(of: styleKey) { _, _ in engine.applyStyle() }
        .onChange(of: winSize) { _, _ in engine.applyWindowSize() }
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
                Button("Reset diagnostics counters") { engine.clearDiagnosticEvents() }
            }
        }
        .settingsPage("Performance & power")
        .onChange(of: adaptive) { _, _ in engine.syncConfig() }
    }
}

// MARK: - Profiles & backup
struct ProfilesSettings: View {
    @EnvironmentObject var engine: TranslatorEngine
    @State private var name = ""
    @State private var message = ""

    var body: some View {
        List {
            Section {
                TextField("Profile name (e.g. Anime night)", text: $name)
                Button("Save current settings as profile") {
                    engine.saveProfile(name)
                    name = ""
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Save")
            } footer: {
                Text("A profile remembers every setting, including languages. Swipe a profile to delete it.")
            }
            Section("Your profiles") {
                if engine.profileNames.isEmpty {
                    Text("None yet.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(engine.profileNames, id: \.self) { p in
                    Button(p) { engine.applyProfile(p) }
                        .swipeActions { Button("Delete", role: .destructive) { engine.deleteProfile(p) } }
                }
            }
            Section {
                ShareLink(item: engine.exportSettings()) { Label("Export settings", systemImage: "square.and.arrow.up") }
                Button {
                    message = engine.importSettings(UIPasteboard.general.string ?? "")
                        ? "Settings imported from the clipboard."
                        : "The clipboard doesn't contain exported settings."
                } label: { Label("Import settings from clipboard", systemImage: "square.and.arrow.down") }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Backup")
            } footer: {
                Text("Export, then copy the text somewhere safe. To restore, copy it again and tap Import.")
            }
        }
        .settingsPage("Profiles & backup")
    }
}

// MARK: - Privacy & history
struct PrivacySettings: View {
    @EnvironmentObject var engine: TranslatorEngine
    @AppStorage("historyRetentionDays") private var retentionDays = 0
    @AppStorage("includeDiagnosticText") private var includeDiagnosticText = false
    @State private var showRetentionInfo = false

    var body: some View {
        List {
            Section {
                Picker("Keep translation history", selection: $retentionDays) {
                    Text("Forever").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
            } header: {
                Text("Local history")
            } footer: {
                Text("Older entries are removed automatically when history is loaded or next saved. History stays on this device and is not uploaded by ScreenLingo.")
            }
            Section {
                Toggle("Include recognized text in diagnostic reports", isOn: $includeDiagnosticText)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Turn this off before sharing reports if the screen may contain private messages, account details, or other sensitive text.")
            }
            Section("Data controls") {
                LabeledContent("Storage", value: "On this device")
                LabeledContent("Translation service", value: "Apple on-device")
                Text("Exported history and diagnostic reports can contain screen text. Review them before sharing.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .settingsPage("Privacy & history")
        .onChange(of: retentionDays) { _, _ in engine.applyHistoryRetention() }
    }
}

// MARK: - About
struct AboutSettings: View {
    @EnvironmentObject var engine: TranslatorEngine
    @State private var confirmReset = false

    var body: some View {
        List {
            Section("Version") {
                LabeledContent("App", value: AppVersion.full)
                LabeledContent("Capture extension",
                               value: engine.extensionVersion == "–" ? "not seen yet" : "v\(engine.extensionVersion)")
            }
            Section("How to use") {
                Text("1. Languages tab → download your source and target packs.\n2. Home → Start. Allow the floating window, then Start Broadcast.\n3. Switch to your app. If nothing shows, use Test translation, and check the Diagnostics tab.")
                    .font(.footnote)
            }
            Section("Changelog") {
                ForEach(AppVersion.changelog, id: \.0) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("v\(v.0)").bold()
                        Text(v.1).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button("Reset all settings", role: .destructive) { confirmReset = true }
            }
        }
        .settingsPage("About & help")
        .confirmationDialog("Reset every setting to its default?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset all settings", role: .destructive) { engine.resetAllSettings() }
        }
    }
}
