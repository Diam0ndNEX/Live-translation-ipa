import SwiftUI

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
    @AppStorage("cjkSingleCharacters") private var cjkSingleCharacters = true
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

    private var key: String { "\(mode)|\(area)|\(customY0)|\(customY1)|\(speed)|\(stability)|\(boost)|\(skipUnchanged)|\(confidence)|\(correction)|\(cjkSingleCharacters)" }
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
                Toggle("Translate single Chinese, Japanese or Korean characters", isOn: $cjkSingleCharacters)
                Hint("One character can be a whole word. Turn off if icons or labels on screen get translated by mistake.")
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
                                "minTextH", "ignoreList", "dropNoise", "cjkSingleCharacters", "boost", "skipUnchanged", "ocrConfidence", "ocrCorrection",
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
    /// 2.2.1 (E6): the nine rule values when the page opened. Leaving the page used to reload all settings
    /// every time, which drops in-flight translation work and OCR packets even when nothing changed.
    @State private var rulesAtAppear: String?
    private var ruleSignature: String {
        [cleanOCR, slang, speakerDetect, langLock, contextualLanguage, languageRecovery].map(String.init).joined(separator: "|")
            + "\u{1F}" + neverTranslate + "\u{1F}" + sourceFixes + "\u{1F}" + glossary
    }

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
        .onAppear { if rulesAtAppear == nil { rulesAtAppear = ruleSignature } }
        .onDisappear {
            if let start = rulesAtAppear, start != ruleSignature { engine.pipelineSettingsChanged() }
            rulesAtAppear = nil
        }
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
                Hint("Opens the window when capture starts, only if ScreenLingo is still open.")
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
                HStack(spacing: KitSpace.row) {
                    ForEach(AccentChoice.allCases) { color in
                        Button { accent = color.rawValue; engine.tap() } label: {
                            Circle()
                                .fill(LinearGradient(colors: [color.start, color.end], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 36, height: 36)
                                .overlay(Circle().stroke(Color.primary, lineWidth: accent == color.rawValue ? 3 : 0))
                                .scaleEffect(accent == color.rawValue ? 1.12 : 1)
                                .animation(KitMotion.spring, value: accent)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(PressableStyle())
                        .sensoryFeedback(.selection, trigger: accent)
                        .accessibilityLabel(color.title)
                        .accessibilityAddTraits(accent == color.rawValue ? .isSelected : [])
                    }
                }
            }
            Section("Feedback") {
                LabeledToggleRow(title: "Haptic feedback for taps", detail: "A light tick when you press buttons.", isOn: $uiHaptics)
            }
            ResetSection(keys: ["accent", "appearance", "uiHaptics"])
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
    }
}
