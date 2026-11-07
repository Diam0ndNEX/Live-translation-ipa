// ScreenLingo – App
import SwiftUI

extension View {
    func settingsPage(_ title: String) -> some View {
        self.scrollContentBackground(.hidden)
            .background(Palette.background.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct ResetSection: View {
    @EnvironmentObject var engine: TranslatorEngine
    @EnvironmentObject private var feedback: FeedbackCenter
    let keys: [String]
    @State private var confirm = false
    var body: some View {
        Section {
            // The dialog belongs to the button that opens it, not to the Section.
            Button("Reset this page to defaults", role: .destructive) { confirm = true }
                .frame(minHeight: 44)
                .confirmDestructive("Reset every setting on this page?", message: "Only this page's settings return to their defaults.",
                                    isPresented: $confirm, button: "Reset") {
                    engine.resetKeys(keys); feedback.show("Page reset to defaults", severity: .success)
                }
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
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
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
    @EnvironmentObject private var router: AppRouter
    @State private var query = ""
    private var chevron: some View { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }

    private func matches(_ title: String, _ keywords: String) -> Bool {
        query.isEmpty || (title + " " + keywords).localizedCaseInsensitiveContains(query)
    }

    private var translateMatches: Bool {
        matches("Reading & OCR", "capture movie subtitles frames recognition tracking confirmation")
        || matches("Languages & text rules", "understanding glossary slang protect names source fixes automatic recovery")
        || matches("Translation & memory", "translate ahead pretranslation warm up cache remember SQLite speculative model")
        || matches("Presets", "profiles saved configurations")
    }
    private var subtitleMatches: Bool {
        matches("Floating subtitles", "picture in picture PiP font size theme appearance window")
        || matches("Subtitle timing", "min display clear heartbeat steady captions handoff responsive")
        || matches("Feedback & sharing", "haptics speak copy clipboard voice vibration")
    }
    private var personalizeMatches: Bool {
        matches("App appearance", "interface accent color dark light system theme haptics")
        || matches("Reader & photos", "workspace photo OCR reading")
        || matches("History & storage", "saved translations retention limit delete memory library")
    }
    private var advancedMatches: Bool {
        matches("Performance & battery", "speed cool power thermal idle awake energy")
        || matches("Experimental Features", "smart pipeline beta low latency lyrics incremental PiP advanced model rotation")
        || matches("Diagnostics & tests", "metrics benchmark export sessions simulator validation fresh translation")
    }
    private var supportMatches: Bool {
        matches("Privacy", "private session text diagnostic speaker")
        || matches("Backup & restore", "export import reset settings")
        || matches("About & help", "version changelog guide")
    }
    private var anyMatch: Bool {
        testsMatch || translateMatches || subtitleMatches || personalizeMatches || advancedMatches || supportMatches
    }

    private var testsMatch: Bool {
        matches("Tests & diagnostics", "test runs dashboard compare modes export zip report simulator memory management evidence")
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
                        if matches("Translation & memory", "translate ahead pretranslation warm up cache remember SQLite speculative model") {
                            SettingsNavRow(title: "Translation & memory", detail: "Translate ahead, model readiness and remembered text",
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
                        if matches("App appearance", "interface accent color dark light system theme haptics") {
                            SettingsNavRow(title: "App appearance", detail: "Light or dark, accent color and haptics",
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
                        if matches("Experimental Features", "smart pipeline beta low latency lyrics incremental PiP advanced model rotation") {
                            SettingsNavRow(title: "Experimental Features", detail: "Opt-in features that still need device testing",
                                           symbol: "flask", destination: ExperimentalFeaturesView())
                        }
                        if matches("Diagnostics & tests", "metrics benchmark export sessions simulator validation fresh translation") {
                            SettingsNavRow(title: "Diagnostics & tests", detail: "What is collected, test-run saving and the simulator",
                                           symbol: "waveform.path.ecg", destination: DiagnosticsSettings())
                        }
                    }
                }

                if testsMatch {
                    Section("Tests & diagnostics") {
                        Button { router.present(.diagnostics) } label: {
                            ListRow(title: "Live dashboard", subtitle: "Health, timing and exports while you translate", symbol: "waveform.path.ecg") { chevron }
                        }.buttonStyle(.plain)
                        Button { router.present(.testRuns) } label: {
                            ListRow(title: "Test runs", subtitle: "Compare Legacy, Hybrid and Low Latency on the same content", symbol: "checklist") { chevron }
                        }.buttonStyle(.plain)
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
            .background(Palette.background.ignoresSafeArea())
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
    @AppStorage("rapidTextTracking") private var rapidTextTracking = true
    @AppStorage("joinAdjacentText") private var joinAdjacentText = true
    @AppStorage("activeTextFocus") private var activeTextFocus = true
    @State private var showAreaEditor = false

    // Manual content-style selection only applies recommended switch values.
    // Applying a saved custom preset writes UserDefaults directly, so the
    // preset's explicit overrides are never replaced by this picker.
    private var contentStyleSelection: Binding<String> {
        Binding(get: { mode }, set: { value in
            mode = value
            let recommended = PresetRecognitionPolicy.legacyDefaults(for: value)
            rapidTextTracking = recommended[PresetRecognitionPolicy.rapidTextTracking] ?? true
            joinAdjacentText = recommended[PresetRecognitionPolicy.joinAdjacentText] ?? true
            activeTextFocus = recommended[PresetRecognitionPolicy.activeTextFocus] ?? true
        })
    }

    private var key: String { "\(mode)|\(area)|\(customY0)|\(customY1)|\(speed)|\(stability)|\(boost)|\(skipUnchanged)|\(confidence)|\(correction)" }
    private var recognitionPolicy: String { "\(adaptiveOCR)|\(subtitleTracking)|\(deduplicateCopies)|\(rapidTextTracking)|\(joinAdjacentText)|\(activeTextFocus)" }

    var body: some View {
        List {
            Section {
                Picker("Content style defaults", selection: contentStyleSelection) {
                    ForEach(TranslateMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Hint("Pick what you usually watch. This chooses sensible reading options; you can still change them below.")
                Picker("Speed", selection: $speed) {
                    ForEach(SpeedPreset.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Hint("Faster shows translations sooner. More careful avoids translating text that is still fading in.")
                Picker("Area to read", selection: $area) {
                    ForEach(OCRArea.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Button { showAreaEditor = true } label: { Label("Choose area on a preview", systemImage: "viewfinder") }.frame(minHeight: 44)
                if area == OCRArea.custom.rawValue {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Reads from \(Int(customY0 * 100))% to \(Int(customY1 * 100))% of the screen height (0% is the bottom)")
                            .font(.footnote).foregroundStyle(.secondary)
                        Slider(value: $customY0, in: 0...0.9).accessibilityLabel("Lower edge of the reading area")
                        Slider(value: $customY1, in: 0.1...1).accessibilityLabel("Upper edge of the reading area")
                    }
                }
                Toggle("Ignore numbers and symbols", isOn: $dropNoise)
                Hint("Skips scores, timers and icons so they are not translated.")
            } header: { Text("What to read") }

            AdvancedSection(title: "Filtering", footer: "These decide which text on screen is ignored.") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ignore text smaller than \(Int(minTextH * 100))% of the screen").font(.subheadline)
                    Slider(value: $minTextH, in: 0...0.08).accessibilityLabel("Smallest text to read")
                }
                TextField("Ignore text containing… (comma separated)", text: $ignoreList, axis: .vertical).lineLimit(1...3)
            }

            AdvancedSection(title: "Text order", footer: "If sentences come out in the wrong order, the picture is probably rotated. Automatic checks which way the lines read. Pick a fixed rotation to force it.") {
                Picker("Frame rotation", selection: $frameRot) {
                    Text("Automatic").tag("auto")
                    Text("None").tag("0")
                    Text("90° clockwise").tag("90")
                    Text("180° (upside down)").tag("180")
                    Text("270° clockwise").tag("270")
                }
            }

            AdvancedSection(title: "Accuracy and speed", footer: "Instant is fastest but may translate half-faded text. Always boosting contrast helps thin or outlined fonts but is slower.") {
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
                Hint("Does no reading while the picture stays the same. Saves battery.")
                Toggle("OCR language correction", isOn: $correction)
                VStack(alignment: .leading) {
                    Text("Minimum confidence · \(Int(confidence * 100))%")
                    Slider(value: $confidence, in: 0.1...0.9, step: 0.05).accessibilityLabel("Minimum recognition confidence")
                }
            }

            AdvancedSection(title: "Smarter recognition") {
                Toggle("Adaptive detail in Balanced", isOn: $adaptiveOCR)
                Hint("Reads small or unclear subtitles in more detail without lowering accuracy elsewhere.")
                Toggle("Track subtitle position and lifetime", isOn: $subtitleTracking)
                Hint("Keeps moving or multi-line subtitles together across frames.")
                Toggle("Merge duplicate OCR copies", isOn: $deduplicateCopies)
                Hint("Removes shadow or overlapping copies of the same subtitle but keeps genuinely repeated lyrics.")
            }
            AdvancedSection(title: "Text behavior", footer: "Applies to every preset.") {
                Toggle("React quickly to changing text", isOn: $rapidTextTracking)
                Hint("Confirms changing text sooner when reading is fast. Heat and power safeguards stay on.")
                Toggle("Join neighboring text fragments", isOn: $joinAdjacentText)
                Hint("Merges words or boxes on the same line. Turn off for separate speech bubbles.")
                Toggle("Prioritize the active text group", isOn: $activeTextFocus)
                Hint("Follows the text that is changing instead of treating every box equally. Good for moving subtitles and lyrics.")
            }
            AdvancedSwitchSection()
            ResetSection(keys: ["mode", "area", "customY0", "customY1", "frameRot", "speed", "stability",
                                "minTextH", "ignoreList", "dropNoise", "boost", "skipUnchanged", "ocrConfidence", "ocrCorrection",
                                "adaptiveOCR", "subtitleTracking", "deduplicateCopies",
                                "rapidTextTracking", "joinAdjacentText", "activeTextFocus"])
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
                Toggle("Clean up reading mistakes", isOn: $cleanOCR)
                Hint("Fixes common mix-ups such as 0 and O before translating.")
                Toggle("Recognize speakers (\"Name: text\")", isOn: $speakerDetect)
                Hint("Keeps names untranslated and puts each speaker on their own line.")
            } header: { Text("Understanding") }
            Section {
                editor($neverTranslate)
            } header: {
                Text("Never translate")
            } footer: {
                Text("Words or names to keep exactly as written, separated by commas or new lines. Example: Subaru, Emilia")
            }
            Section {
                editor($glossary)
            } header: {
                Text("Replace in the translation")
            } footer: {
                Text("One per line: word=replacement. Example: Lord Subaru=Subaru")
            }
            AdvancedSection(title: "Language detection", footer: "These help Automatic pick the right source language.") {
                Toggle("Expand chat slang (pq, vc, tbm, idk…)", isOn: $slang)
                Hint("Spells slang out before translating so it isn't misread.")
                Toggle("Lock detected language", isOn: $langLock)
                Hint("Stops Automatic from flipping between languages.")
                Toggle("Use recent context for ambiguous languages", isOn: $contextualLanguage)
                Hint("Recent subtitles can help Automatic recognize a short, ambiguous phrase.")
                Toggle("Recover Automatic after repeated failures", isOn: $languageRecovery)
                Hint("Rechecks the source language if translation keeps failing.")
            }
            AdvancedSection(title: "Fix the original text", footer: "One per line: wrong=right. Example: Rern=Rem. Applied before translating.") {
                editor($sourceFixes)
            }
            AdvancedSwitchSection()
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
            Section("Look") {
                Picker("Window size", selection: $winSize) {
                    ForEach(WindowSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Theme", selection: $theme) {
                    ForEach(PiPTheme.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Text size", selection: $textSize) {
                    ForEach(PiPTextSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Show original text", isOn: $showOriginal)
                Hint("Shows the source line under the translation.")
            }
            Section {
                Toggle("Open the floating window when capture starts", isOn: $autoOpenPiP)
                Toggle("Clear subtitle when text ends", isOn: $autoClear)
                if autoClear {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keep text after it disappears · \(String(format: "%.1f", clearHold)) s")
                            .font(.subheadline)
                        Slider(value: $clearHold, in: 0...5, step: 0.5).accessibilityLabel("How long to keep text after it disappears")
                    }
                }
            } header: { Text("Behavior") } footer: {
                Text("When captions appear is under Subtitle timing. Speech, copying and vibration are under Feedback & sharing.")
            }
            AdvancedSection(title: "Typography") {
                Picker("Font", selection: $pipFont) {
                    ForEach(PiPFont.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Colour speaker names", isOn: $highlightNames)
                NavigationLink {
                    CaptionAppearanceSettings()
                } label: {
                    Label("Spacing and layout", systemImage: "textformat.size")
                }
            }
            AdvancedSwitchSection()
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
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @AppStorage("homeMetrics") private var homeMetrics = true
    @AppStorage("uiHaptics") private var uiHaptics = true

    var body: some View {
        List {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            } header: { Text("Light or dark") } footer: {
                Text("System follows your iPhone's setting.")
            }
            Section("Accent color") {
                HStack(spacing: Space.m) {
                    ForEach(AccentChoice.allCases) { color in
                        Button { accent = color.rawValue; engine.tap() } label: {
                            Circle()
                                .fill(LinearGradient(colors: [color.start, color.end], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 36, height: 36)
                                .overlay(Circle().stroke(Color.primary, lineWidth: accent == color.rawValue ? 3 : 0))
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(color.title)
                        .accessibilityAddTraits(accent == color.rawValue ? .isSelected : [])
                    }
                }
            }
            Section("Feedback") {
                LabeledToggleRow(title: "Haptic feedback for taps", detail: "A light tick when you press buttons.", isOn: $uiHaptics)
                LabeledToggleRow(title: "Show timing details in Status", detail: "Adds the per-stage timing list to the Status sheet.", isOn: $homeMetrics)
            }
            ResetSection(keys: ["accent", "appearance", "homeMetrics", "uiHaptics"])
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
                Hint("Does less work when the phone gets hot, memory is low or Low Power Mode is on.")
                Toggle("Cool mode", isOn: $coolMode)
                Hint("Reads the screen less often to keep the phone cooler. Very short subtitles may be missed.")
                Toggle("Keep screen awake during capture", isOn: $keepAwake)
            } header: { Text("Heat and battery") }
            Section {
                Picker("Pause after no text", selection: $idleMinutes) {
                    Text("Never").tag(0)
                    Text("1 minute").tag(1)
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("30 minutes").tag(30)
                }
                Toggle("Pause reading inside ScreenLingo", isOn: $suppressOwnInterface)
                Hint("Avoids translating this app's own screens. Turn off to read a video floating over ScreenLingo. Text & photos still works.")
            } header: { Text("When nothing is happening") } footer: {
                Text("Pausing saves power but can delay the next detected text.")
            }
            AdvancedSection(title: "Cooling and idle details") {
                Toggle("Smart Cool controller", isOn: $smartCool).disabled(!coolMode)
                Hint("Adjusts how often the screen is read to match the actual workload. Off uses fixed, conservative timing.")
                Toggle("Reduce reading when no text is visible", isOn: $idleBackoff)
            }
            AdvancedSwitchSection()
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
                Text("Share or copy your settings as text, keep it somewhere safe, and import it later to restore. Backups from earlier builds still restore. Presets have their own export.")
            }
            Section {
                Button("Reset every setting", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Presets and history are kept.")
            }
        }
        .settingsPage("Backup & reset")
        .confirmDestructive("Reset every setting to its default?", message: "Presets and history are kept.", isPresented: $confirmReset, button: "Reset every setting") {
            engine.resetAllSettings()
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
                Text("1. Languages tab: download your source and target packs.\n2. Live tab: tap the round broadcast button, choose ScreenLingo Capture, then Start Broadcast.\n3. Switch to your app. If nothing shows, open Status on the Live tab, or Settings → Tests & diagnostics.")
                    .font(.footnote)
                Button("Show the welcome tour again") { onboarded = false }
            }
            Section("What's new") {
                ForEach(Array(AppVersion.changelog.prefix(3)), id: \.1) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("v\(v.0)").bold()
                        Text(v.1).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                NavigationLink("Full changelog") {
                    List(AppVersion.changelog, id: \.1) { v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("v\(v.0)").bold()
                            Text(v.1).font(.footnote).foregroundStyle(.secondary)
                        }
                    }.settingsPage("Changelog")
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
                Hint("New translations are not added to your Library or saved translation memory. Things saved earlier stay.")
            } header: { Text("Translation privacy") }
            Section {
                Toggle("Show recognized speaker labels", isOn: $showSpeakers)
                Hint("Only reads visible \"Name:\" labels. It does not identify voices or people without a label.")
                Toggle("Include recognized text in diagnostic exports", isOn: $includeText)
                Hint("Leave off unless a troubleshooting export needs the text. Reading and translating happen on your phone.")
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
    @EnvironmentObject var engine: TranslatorEngine
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
        .onChange(of: enabled) { _, _ in engine.diagnosticsSettingsChanged() }
        .onChange(of: detailed) { _, _ in engine.diagnosticsSettingsChanged() }
    }
}
