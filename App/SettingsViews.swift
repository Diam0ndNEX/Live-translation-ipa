// ScreenLingo – App – Settings (2.1.2: colour-tile rows in rounded groups, one hero summary, native pages)
import SwiftUI

extension View {
    /// Every settings page is a native grouped list with a large title; no header card (R9).
    func settingsPage(_ title: String) -> some View {
        self.listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 44)
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .ambientGlow()
            .background(Color(.systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
    }
}

struct ResetSection: View {
    @EngineHandle private var engine
    @EnvironmentObject private var feedback: FeedbackCenter
    let keys: [String]
    @State private var confirm = false
    var body: some View {
        Section {
            // The dialog belongs to the button that opens it, not to the Section.
            Button("Reset this page", role: .destructive) { confirm = true }
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
            SettingsRow(title: "Scenes", value: store.active.map { store.isModified ? "\($0.name) · changed" : $0.name } ?? "\(store.all.count)",
                        symbol: "square.stack.3d.up", tint: .indigo)
        }
        .buttonStyle(PressableStyle())
    }
}

/// One searchable entry of the Settings list.
private struct SettingsEntry: Identifiable {
    let title: String
    let symbol: String
    let keywords: String
    var id: String { title }
}

/// One grouped list in five groups (§13.5.5). Search finds a row by its title or by plain words for what it holds.
struct SettingsView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var advanced: AdvancedMode
    @EnvironmentObject private var theme: ThemeStore
    @State private var query = ""
    /// Read-only: each key keeps its one owner page (scripts/test_experimental_settings.py).
    private var areaTitle: String { (OCRArea(rawValue: UserDefaults.standard.string(forKey: "area") ?? "") ?? .smart).title }

    private func shows(_ title: String, _ keywords: String) -> Bool {
        query.isEmpty || (title + " " + keywords).localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: KitSpace.group) {
                    if query.isEmpty { hero }
                    settingResults
                    translation
                    reading
                    caption
                    look
                    care
                    advancedGroup
                    if query.isEmpty {
                        SettingsGroup {
                            link("About ScreenLingo", "info.circle", .gray, value: AppVersion.full, destination: AboutSettings())
                        }
                    }
                }
                .padding(.horizontal, KitSpace.margin)
                .padding(.top, KitSpace.tight)
                .padding(.bottom, KitSpace.group)
                .modifier(ReadableColumn())
                .animation(KitMotion.spring, value: query.isEmpty)
            }
            .scrollDismissesKeyboard(.interactively)
            .ambientGlow()
            .background(Color(.systemGroupedBackground))
            .searchable(text: $query, prompt: "Search settings")
            .navigationTitle("Settings")
            #if SCREENLINGO_FIXTURES
            .navigationDestination(isPresented: .constant(UIFixture.current == .settingsCaption)) { CaptionAppearanceSettings() }
            #endif
        }
    }

    /// One row that opens a page. The press feedback comes from the style, not from a big button shape.
    private func link<D: View>(_ title: String, _ symbol: String, _ tint: Color, value: String = "",
                               destination: @autoclosure @escaping () -> D) -> some View {
        NavigationLink { destination() } label: { SettingsRow(title: title, value: value, symbol: symbol, tint: tint) }
            .buttonStyle(PressableStyle())
    }

    /// What is set up right now, at a glance. The one hero object on this screen.
    private var hero: some View {
        let defaults = UserDefaults.standard
        let content = TranslateMode(rawValue: defaults.string(forKey: "mode") ?? "")?.title ?? TranslateMode.movie.title
        let speed = SpeedPreset(rawValue: defaults.string(forKey: "speed") ?? "")?.title ?? SpeedPreset.balanced.title
        let source = engine.sourceCode == "auto" ? "Auto" : engine.sourceCode.uppercased()
        return HStack(spacing: KitSpace.row) {
            IconTile(symbol: "character.bubble.fill", tint: .accentColor).scaleEffect(1.35).padding(KitSpace.unit)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(source) → \(engine.targetCode.uppercased())").font(.title3.weight(.semibold))
                Text("\(engine.pendingTranslationSystem.shortName) · \(content) · \(speed)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(KitSpace.row)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Search finds the setting itself, then opens the page that holds it (§13.5.5).
    @ViewBuilder private var settingResults: some View {
        let found = SettingsSearchIndex.matches(query)
        if !found.isEmpty {
            SettingsGroup(title: "Settings") {
                ForEach(found.prefix(30)) { entry in
                    NavigationLink(destination: page(entry.page)) {
                        HStack(spacing: KitSpace.row) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.label).font(.body)
                                Text(entry.pageTitle).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: KitSpace.tight)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, KitSpace.row)
                        .padding(.vertical, 9)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    @ViewBuilder private func page(_ page: SettingsPage) -> some View {
        switch page {
        case .reading: ReadingSettings()
        case .textRules: IntelligenceSettings()
        case .timing: ResponsivenessSettings()
        case .window: WindowSettings()
        case .style: CaptionAppearanceSettings()
        case .appearance: InterfaceSettings()
        case .feedback: FeedbackStorageSettings()
        case .reader: ReaderWorkspaceSettings()
        case .performance: PerformanceSettings()
        case .privacy: PrivacySettings()
        case .history: HistoryStorageSettings()
        case .backup: BackupSettings()
        case .system: TranslationSettings()
        case .diagnostics: DiagnosticsSettings()
        case .experimental: ExperimentalFeaturesView()
        }
    }

    @ViewBuilder private var translation: some View {
        SettingsGroup(title: "Translation") {
            if shows("System", "legacy hybrid low latency mode translate ahead speculation model warm memory") {
                link("System", "cpu", .blue, value: engine.pendingTranslationSystem.shortName, destination: TranslationSettings())
            }
            if shows("Language packs", "languages download offline pair source target") {
                link("Language packs", "globe", .teal, destination: LanguageSheet(engine: engine, inSheet: false))
            }
            if shows("Scenes", "presets profiles saved configurations") {
                PresetsLinkRow(store: engine.presets)
            }
            if shows("Memory", "translation memory remembered cache database") {
                link("Memory", "externaldrive", .purple, value: "\(engine.memoryCount.formatted()) remembered", destination: MemoryManagementView())
            }
        }
    }

    @ViewBuilder private var reading: some View {
        SettingsGroup(title: "Reading") {
            if shows("Area, recognition and speed", "capture movie subtitles frames ocr recognition tracking confirmation speed") {
                link("Area and recognition", "viewfinder", .green, value: areaTitle, destination: ReadingSettings())
            }
            if shows("Text rules and names", "understanding glossary slang protect names source fixes language detection recovery") {
                link("Text rules and names", "character.book.closed", .pink, destination: IntelligenceSettings())
            }
            if shows("Timing", "min display clear heartbeat steady captions handoff subtitle timing") {
                link("Timing", "timer", .orange, destination: ResponsivenessSettings())
            }
        }
    }

    @ViewBuilder private var caption: some View {
        SettingsGroup(title: "Floating caption",
                      footer: query.isEmpty ? "Both pages show a live preview of the floating caption." : nil) {
            if shows("Window", "floating window picture in picture pip size theme position") {
                link("Window", "pip", .cyan, destination: WindowSettings())
            }
            if shows("Style", "font size weight alignment spacing padding original caption layout") {
                link("Style", "textformat.size", .indigo, destination: CaptionAppearanceSettings())
            }
        }
    }

    @ViewBuilder private var look: some View {
        SettingsGroup(title: "Look and feel") {
            if shows("Appearance", "interface accent color dark light system theme") {
                link("Appearance", "paintpalette", .purple, value: theme.appearance.title, destination: InterfaceSettings())
            }
            if shows("Haptics and feedback", "vibration speak copy clipboard voice sharing") {
                link("Haptics and feedback", "hand.tap", .red, destination: FeedbackStorageSettings())
            }
            if shows("Reader and photos", "focus reader photo ocr reading layout") {
                link("Reader and photos", "text.book.closed", .teal, destination: ReaderWorkspaceSettings())
            }
        }
    }

    @ViewBuilder private var care: some View {
        SettingsGroup(title: "Device and data") {
            if shows("Performance and battery", "speed cool power thermal idle awake energy heat") {
                link("Performance and battery", "bolt.fill", .green, destination: PerformanceSettings())
            }
            if shows("Privacy", "private session diagnostic text speaker") {
                link("Privacy", "hand.raised.fill", .blue, destination: PrivacySettings())
            }
            if shows("History and storage", "saved translations retention limit delete library") {
                link("History and storage", "clock.arrow.circlepath", .gray, destination: HistoryStorageSettings())
            }
            if shows("Backup", "export import reset settings restore") {
                link("Backup and reset", "externaldrive.badge.timemachine", .gray, destination: BackupSettings())
            }
        }
    }

    /// Collapsed until the switch is on; the switch is the last row of the list. Search always finds these rows.
    @ViewBuilder private var advancedGroup: some View {
        let open = advanced.on || !query.isEmpty
        if open {
            SettingsGroup(title: "Advanced") {
                if shows("Diagnostics settings", "metrics benchmark export test runs fresh translation temporary memory") {
                    link("Diagnostics settings", "waveform.path.ecg", .red, destination: DiagnosticsSettings())
                }
                if shows("Experimental features", "beta experiments smart pipeline lyrics incremental pip rotation") {
                    link("Experimental features", "flask", .orange, destination: ExperimentalFeaturesView())
                }
                if shows("Pipeline simulator", "simulate test pipeline") {
                    link("Pipeline simulator", "point.3.connected.trianglepath.dotted", .indigo, destination: PipelineSimulatorView())
                }
                if shows("Test runs", "compare modes legacy hybrid low latency") {
                    Button { router.present(.testRuns) } label: { SettingsRow(title: "Test runs", symbol: "checklist", tint: .teal) }
                        .buttonStyle(PressableStyle())
                }
            }
        }
        if query.isEmpty {
            SettingsGroup(footer: "Diagnostics, experiments and the simulator. Hidden settings keep their values.") {
                HStack(spacing: KitSpace.row) {
                    IconTile(symbol: "slider.horizontal.3", tint: .gray)
                    Toggle("Show advanced settings", isOn: $advanced.on).sensoryFeedback(.selection, trigger: advanced.on)
                }
                .padding(.horizontal, KitSpace.row)
                .padding(.vertical, 9)
                .frame(minHeight: 48)
            }
        }
    }
}

// MARK: - Area and recognition
struct ReadingSettings: View {
    @EngineHandle private var engine
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
                Toggle("Correct reading with language rules", isOn: $correction)
                VStack(alignment: .leading) {
                    Text("Minimum confidence · \(Int(confidence * 100))%")
                    Slider(value: $confidence, in: 0.1...0.9, step: 0.05).accessibilityLabel("Minimum recognition confidence")
                }
            }

            AdvancedSection(title: "Smarter recognition") {
                Toggle("Adaptive detail in Balanced", isOn: $adaptiveOCR)
                Hint("Reads small or unclear subtitles in more detail without lowering accuracy elsewhere.")
                Toggle("Follow where subtitles appear and how long they stay", isOn: $subtitleTracking)
                Hint("Keeps moving or multi-line subtitles together across frames.")
                Toggle("Merge duplicate copies of the same text", isOn: $deduplicateCopies)
                Hint("Removes shadow or overlapping copies of the same subtitle but keeps genuinely repeated lyrics.")
            }
            AdvancedSection(title: "Text behavior", footer: "Applies to every scene.") {
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
        .settingsPage("Area and recognition")
        .fullScreenCover(isPresented: $showAreaEditor) { AreaSheet() }
        .onChange(of: key) { _, _ in engine.syncConfig() }
        .onChange(of: frameRot) { _, _ in engine.rotationSettingChanged() }
        .onChange(of: recognitionPolicy) { _, _ in engine.pipelineSettingsChanged() }
    }
}

// MARK: - Understanding & rules
struct IntelligenceSettings: View {
    @EngineHandle private var engine
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
        .settingsPage("Text rules and names")
        .onChange(of: contextualLanguage) { _, _ in engine.pipelineSettingsChanged() }
        .onChange(of: languageRecovery) { _, _ in engine.pipelineSettingsChanged() }
        .onDisappear { engine.reloadSettings() }
    }
}

// MARK: - Floating window
struct WindowSettings: View {
    @EngineHandle private var engine
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
    var body: some View {
        List {
            Section {
                CaptionPreview()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
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
                Text("When captions appear is under Timing. Speech, copying and vibration are under Haptics and feedback.")
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
        .settingsPage("Window")
        .onChange(of: styleKey) { _, _ in engine.applyStyle() }
        .onChange(of: showOriginal) { _, _ in engine.applyStyle() }
        .onChange(of: winSize) { _, _ in engine.applyWindowSize() }
    }
}

// MARK: - Interface
struct InterfaceSettings: View {
    @EngineHandle private var engine
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
        .settingsPage("Appearance")
    }
}

// MARK: - Performance
struct PerformanceSettings: View {
    @EngineHandle private var engine
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
                Hint("Avoids translating this app's own screens. Turn off to read a video floating over ScreenLingo. Typed and photo translation still work.")
            } header: { Text("When nothing is happening") } footer: {
                Text("Pausing saves power but can delay the next detected text.")
            }
            AdvancedSection(title: "Cooling and idle details") {
                Toggle("Smart cooling", isOn: $smartCool).disabled(!coolMode)
                Hint("Adjusts how often the screen is read to match the actual workload. Off uses fixed, conservative timing.")
                Toggle("Reduce reading when no text is visible", isOn: $idleBackoff)
            }
            AdvancedSwitchSection()
            ResetSection(keys: ["suppressOwnInterface", "coolMode", "smartCool", "adaptive", "idleMinutes", "idleBackoff", "keepAwake"])
        }
        .settingsPage("Performance and battery")
        .onChange(of: suppressOwnInterface) { _, _ in engine.pipelineSettingsChanged() }
        .onChange(of: adaptive) { _, _ in engine.syncConfig() }
        .onChange(of: idleBackoff) { _, _ in engine.syncConfig() }
        .onChange(of: smartCool) { _, _ in engine.pipelineSettingsChanged() }
        .onChange(of: coolMode) { _, _ in engine.powerPolicyChanged() }
    }
}

// MARK: - Backup & reset
struct BackupSettings: View {
    @EngineHandle private var engine
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
        .settingsPage("Backup and reset")
        .confirmDestructive("Reset every setting to its default?", message: "Presets and history are kept.", isPresented: $confirmReset, button: "Reset every setting") {
            engine.resetAllSettings()
        }
    }
}

// MARK: - About
struct AboutSettings: View {
    @EngineHandle private var engine
    @AppStorage("onboarded") private var onboarded = true

    var body: some View {
        List {
            Section("Version") {
                LabeledContent("App", value: AppVersion.full)
                LabeledContent("Capture extension",
                               value: engine.extensionVersion == "–" ? "not seen yet" : "v\(engine.extensionVersion)")
                LabeledContent("Legacy system", value: "based on \(TranslationSystem.referenceVersion)")
            }
            Section("How to use") {
                Text("1. On Translate, tap a language in the pair to choose it and get its pack.\n2. Tap the round Start button, choose ScreenLingo Capture, then Start Broadcast.\n3. Switch to your app. If nothing shows, tap the status line on Translate, or open Diagnostics.")
                    .font(.footnote)
                Button("Run setup again") { onboarded = false }
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
        .settingsPage("About ScreenLingo")
    }
}

struct PrivacySettings: View {
    @EngineHandle private var engine
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
    @EngineHandle private var engine
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
