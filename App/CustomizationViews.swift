import SwiftUI

struct ResponsivenessSettings: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @EnvironmentObject private var feedback: FeedbackCenter
    @AppStorage("displayPolicy") private var policy = "immediate"
    @AppStorage("minDisplay") private var minimum = 0.0
    @AppStorage("heartbeatInterval") private var heartbeat = 1.0
    @AppStorage("steadyCaptions") private var steadyCaptions = true
    @AppStorage("protectConfirmedPresentation") private var protectConfirmed = true

    private var timingKey: String { "\(policy)|\(minimum)|\(heartbeat)" }
    private var continuityKey: String { "\(steadyCaptions)|\(protectConfirmed)" }

    var body: some View {
        List {
            Section {
                Picker("When a translation is ready", selection: $policy) {
                    Text("Show immediately").tag("immediate")
                    Text("Keep results readable").tag("readable")
                }
                if policy == "readable" {
                    Stepper("Show for at least \(minimum, specifier: "%.1f") s",
                            value: $minimum, in: 0...4, step: 0.1)
                }
                Hint("Immediately shows each confirmed translation as soon as it is ready. Readable can briefly keep the current caption on screen so it can be read.")
            } header: { Text("When captions appear") }

            Section {
                Toggle("Keep captions steady", isOn: $steadyCaptions)
                Hint("Keeps a confirmed caption on screen instead of replacing it with a first, uncertain reading.")
            } header: { Text("Stability") }

            AdvancedSection(title: "Caption handoff and floating window") {
                Toggle("Let a confirmed caption finish before it is replaced", isOn: $protectConfirmed)
                    .disabled(!steadyCaptions)
                Hint("Gives an already confirmed subtitle a short, limited chance to finish before a newer one takes over.")
                Picker("Refresh the idle floating window every", selection: $heartbeat) {
                    Text("0.5 seconds").tag(0.5)
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                }
                Hint("Repeats the current frame so the floating window stays alive. New subtitles still appear at once.")
            }

            LatencyDetail(monitor: engine.latency)
            Section {
                Button("Copy timing report") {
                    UIPasteboard.general.string = engine.diag.report(engine: engine)
                    feedback.show("Timing report copied", severity: .success)
                }.frame(minHeight: 44)
            }
            AdvancedSwitchSection()
            ResetSection(keys: ["displayPolicy", "minDisplay", "heartbeatInterval", "steadyCaptions", "protectConfirmedPresentation"])
        }
        .settingsPage("Subtitle timing")
        .onChange(of: timingKey) { _, _ in engine.timingSettingsChanged() }
        .onChange(of: continuityKey) { _, _ in engine.pipelineSettingsChanged() }
    }
}

struct CaptionAppearanceSettings: View {
    @EngineHandle private var engine
    @AppStorage("pipWeight") private var weight = "bold"
    @AppStorage("pipAlignment") private var alignment = "left"
    @AppStorage("pipLineSpacing") private var spacing = 0.0
    @AppStorage("pipPadding") private var padding = 24.0
    @AppStorage("pipScale") private var scale = 1.0
    @AppStorage("originalFraction") private var originalFraction = 0.27
    @AppStorage("speakerAccent") private var accent = "blue"
    private var key: String { "\(weight)|\(alignment)|\(spacing)|\(padding)|\(scale)|\(originalFraction)|\(accent)" }
    var body: some View {
        List {
            Section("Text") {
                Picker("Weight", selection: $weight) {
                    Text("Regular").tag("regular"); Text("Medium").tag("medium"); Text("Bold").tag("bold")
                }
                Picker("Alignment", selection: $alignment) {
                    Text("Left").tag("left"); Text("Center").tag("center"); Text("Right").tag("right")
                }
                VStack(alignment: .leading) {
                    Text("Text scale · \(Int(scale * 100))%")
                    Slider(value: $scale, in: 0.75...1.5, step: 0.05).accessibilityLabel("Text scale")
                }
            }
            AdvancedSection(title: "Spacing", footer: "These change how captions look only. They do not change reading, translation or language detection.") {
                Stepper("Line spacing · \(Int(spacing))", value: $spacing, in: 0...16, step: 1)
                Stepper("Side padding · \(Int(padding))", value: $padding, in: 12...48, step: 2)
                VStack(alignment: .leading) {
                    Text("Space for original text · \(Int(originalFraction * 100))%")
                    Slider(value: $originalFraction, in: 0.15...0.4, step: 0.01).accessibilityLabel("Space for original text")
                }
                Picker("Speaker name colour", selection: $accent) {
                    Text("Blue").tag("blue"); Text("Mint").tag("mint"); Text("Purple").tag("purple"); Text("Amber").tag("amber")
                }
            }
            AdvancedSwitchSection()
            ResetSection(keys: ["pipWeight", "pipAlignment", "pipLineSpacing", "pipPadding", "pipScale", "originalFraction", "speakerAccent"])
        }
        .settingsPage("Caption layout")
        .onChange(of: key) { _, _ in engine.applyStyle() }
    }
}

struct ReaderWorkspaceSettings: View {
    @EngineHandle private var engine
    @AppStorage("readerFont") private var font = "rounded"
    @AppStorage("readerSpacing") private var spacing = 8.0
    @AppStorage("readerWidth") private var width = "full"
    @AppStorage("photoOCREdge") private var edge = 2400
    @AppStorage("photoAutoTranslate") private var autoTranslate = false

    var body: some View {
        List {
            Section("Focus reader") {
                Picker("Reader font", selection: $font) {
                    ForEach(PiPFont.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Reading width", selection: $width) {
                    Text("Full width").tag("full")
                    Text("Narrow column").tag("narrow")
                }
                Stepper("Line spacing · \(Int(spacing))", value: $spacing, in: 0...16, step: 1)
            }
            Section {
                Toggle("Translate right after reading a photo", isOn: $autoTranslate)
            } header: { Text("Photo translation") }
            AdvancedSection(title: "Photo detail", footer: "More detail finds smaller text but uses more memory. It does not affect live screen reading.") {
                Picker("Photo reading detail", selection: $edge) {
                    Text("Lighter").tag(1600)
                    Text("Standard").tag(2400)
                    Text("Most detail").tag(3200)
                }
            }
            AdvancedSwitchSection()
            ResetSection(keys: [
                "readerFont", "readerSpacing", "readerWidth",
                "photoOCREdge", "photoAutoTranslate"
            ])
        }
        .settingsPage("Reader & photos")
    }
}

struct FeedbackStorageSettings: View {
    @EngineHandle private var engine
    @AppStorage("haptics") private var haptics = false
    @AppStorage("hapticStrength") private var hapticStrength = "light"
    @AppStorage("autoCopy") private var autoCopy = false
    @AppStorage("autoCopyFormat") private var autoCopyFormat = "translation"
    @AppStorage("speak") private var speak = false
    @AppStorage("speechRate") private var speechRate = 0.5
    @AppStorage("interruptSpeech") private var interrupt = true

    var body: some View {
        List {
            Section {
                Toggle("Vibrate on new translation", isOn: $haptics)
                Picker("Vibration strength", selection: $hapticStrength) {
                    Text("Light").tag("light")
                    Text("Medium").tag("medium")
                    Text("Strong").tag("strong")
                }.disabled(!haptics)
            } header: { Text("Vibration") }

            Section {
                Toggle("Copy translations automatically", isOn: $autoCopy)
                Picker("What to copy", selection: $autoCopyFormat) {
                    Text("Translation").tag("translation")
                    Text("Original").tag("original")
                    Text("Both").tag("bilingual")
                }.disabled(!autoCopy)
                Hint("Replaces what is on your clipboard every time a translation appears.")
            } header: { Text("Clipboard") }

            Section {
                Toggle("Speak translations aloud", isOn: $speak)
                if speak {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Speech speed").font(.subheadline)
                        Slider(value: $speechRate, in: 0.3...0.65).accessibilityLabel("Speech speed")
                    }
                }
                Toggle("New speech interrupts previous speech", isOn: $interrupt)
                    .disabled(!speak)
            } header: { Text("Speech") }

            ResetSection(keys: [
                "haptics", "hapticStrength", "autoCopy", "autoCopyFormat",
                "speak", "speechRate", "interruptSpeech"
            ])
        }
        .settingsPage("Feedback & sharing")
    }
}
