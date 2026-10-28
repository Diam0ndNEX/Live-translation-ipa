import SwiftUI

struct ResponsivenessSettings: View {
    @EnvironmentObject private var engine: TranslatorEngine
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
                Picker("When translation is ready", selection: $policy) {
                    Text("Show immediately").tag("immediate")
                    Text("Keep results readable").tag("readable")
                }
                if policy == "readable" {
                    Stepper("Minimum visible time · \(minimum, specifier: "%.1f") s",
                            value: $minimum, in: 0...4, step: 0.1)
                }
                Text("Immediate shows completed, confirmed translations as soon as they're ready. Readable can briefly hold an already translated caption.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Display timing") }

            Section {
                Toggle("Stable caption transitions", isOn: $steadyCaptions)
                Text("Keeps a confirmed caption visible instead of replacing it with a tentative OCR reading.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Protect confirmed captions during handoff", isOn: $protectConfirmed)
                    .disabled(!steadyCaptions)
                Text("Allows an already-confirmed subtitle a short, bounded chance to complete before a newer confirmed subtitle replaces it.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Subtitle continuity") }

            Section {
                Picker("Idle PiP heartbeat", selection: $heartbeat) {
                    Text("0.5 seconds").tag(0.5)
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                }
                Text("Repeats the current frame to keep PiP alive. New subtitles still submit immediately.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Floating window") }

            LatencyDetail(monitor: engine.latency)
            Section {
                Button("Copy timing report") {
                    UIPasteboard.general.string = engine.diag.report(engine: engine)
                    engine.toast("Timing report copied")
                }
                Button("Reset subtitle timing", role: .destructive) {
                    engine.resetKeys(["displayPolicy", "minDisplay", "heartbeatInterval",
                                      "steadyCaptions", "protectConfirmedPresentation"])
                }
            }
        }
        .navigationTitle("Subtitle timing")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: timingKey) { _, _ in engine.timingSettingsChanged() }
        .onChange(of: continuityKey) { _, _ in engine.pipelineSettingsChanged() }
    }
}

struct CaptionAppearanceSettings: View {
    @EnvironmentObject private var engine: TranslatorEngine
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
            Section("Typography") {
                Picker("Weight", selection: $weight) {
                    Text("Regular").tag("regular"); Text("Medium").tag("medium"); Text("Bold").tag("bold")
                }
                Picker("Alignment", selection: $alignment) {
                    Text("Left").tag("left"); Text("Center").tag("center"); Text("Right").tag("right")
                }
                VStack(alignment: .leading) {
                    Text("Text scale · \(Int(scale * 100))%")
                    Slider(value: $scale, in: 0.75...1.5, step: 0.05)
                }
                Stepper("Line spacing · \(Int(spacing))", value: $spacing, in: 0...16, step: 1)
            }
            Section("Layout") {
                Stepper("Horizontal padding · \(Int(padding))", value: $padding, in: 12...48, step: 2)
                VStack(alignment: .leading) {
                    Text("Space for original text · \(Int(originalFraction * 100))%")
                    Slider(value: $originalFraction, in: 0.15...0.4, step: 0.01)
                }
                Picker("Speaker name colour", selection: $accent) {
                    Text("Blue").tag("blue"); Text("Mint").tag("mint"); Text("Purple").tag("purple"); Text("Amber").tag("amber")
                }
            }
            Section {
                Text("These controls change how captions look. They do not change OCR text, translation wording, language detection or confirmation.").font(.footnote).foregroundStyle(.secondary)
                Button("Reset caption layout", role: .destructive) { engine.resetKeys(["pipWeight", "pipAlignment", "pipLineSpacing", "pipPadding", "pipScale", "originalFraction", "speakerAccent"]) }
            }
        }.navigationTitle("Caption layout").navigationBarTitleDisplayMode(.inline)
            .onChange(of: key) { _, _ in engine.applyStyle() }
    }
}

struct ReaderWorkspaceSettings: View {
    @EnvironmentObject private var engine: TranslatorEngine
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
                Stepper("Line spacing · \(Int(spacing))", value: $spacing, in: 0...16, step: 1)
                Picker("Reading width", selection: $width) {
                    Text("Full width").tag("full")
                    Text("Narrow column").tag("narrow")
                }
            }
            Section {
                Picker("Photo OCR resolution", selection: $edge) {
                    Text("1600 px · lighter").tag(1600)
                    Text("2400 px · standard").tag(2400)
                    Text("3200 px · more small-text detail").tag(3200)
                }
                Toggle("Translate after reading a photo", isOn: $autoTranslate)
            } header: { Text("Photo translation") } footer: {
                Text("Higher resolution can detect smaller text but use more memory. This does not affect live screen capture.")
            }
            ResetSection(keys: [
                "readerFont", "readerSpacing", "readerWidth",
                "photoOCREdge", "photoAutoTranslate"
            ])
        }
        .navigationTitle("Reader & photos")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FeedbackStorageSettings: View {
    @EnvironmentObject private var engine: TranslatorEngine
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
                Text("Automatic copying changes your clipboard whenever a translation is shown.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Clipboard") }

            Section {
                Toggle("Speak translations aloud", isOn: $speak)
                if speak {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Speech speed").font(.subheadline)
                        Slider(value: $speechRate, in: 0.3...0.65)
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
        .navigationTitle("Feedback & sharing")
        .navigationBarTitleDisplayMode(.inline)
    }
}
