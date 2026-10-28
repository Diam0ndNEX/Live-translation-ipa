import SwiftUI

struct ResponsivenessSettings: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @AppStorage("displayPolicy") private var policy = "immediate"
    @AppStorage("minDisplay") private var minimum = 0.0
    @AppStorage("heartbeatInterval") private var heartbeat = 1.0
    @AppStorage("translateAhead") private var ahead = true
    private var key: String { "\(policy)|\(minimum)|\(heartbeat)|\(ahead)" }
    var body: some View {
        List {
            Section {
                Picker("When a translation is ready", selection: $policy) {
                    Text("Show confirmed results immediately").tag("immediate")
                    Text("Keep each result readable").tag("readable")
                }
                if policy == "readable" {
                    Stepper("Minimum visible time · \(minimum, specifier: "%.1f") s", value: $minimum, in: 0...4, step: 0.1)
                }
                Toggle("Prepare translations before OCR confirmation", isOn: $ahead)
            } header: { Text("Waiting & display") } footer: {
                Text("Both modes keep OCR confirmation and complete translations. Readable mode holds only the finished result; it no longer delays translation work. Immediate mode removes that optional hold. Translate-ahead never displays unconfirmed text.")
            }
            Section {
                Picker("Idle PiP heartbeat", selection: $heartbeat) {
                    Text("0.5 seconds").tag(0.5); Text("1 second").tag(1.0); Text("2 seconds").tag(2.0)
                }
            } header: { Text("Floating window keep-alive") } footer: {
                Text("New results always enqueue immediately. The heartbeat only repeats the current image while idle; it is not a delay before a new translation.")
            }
            LatencyDetail(monitor: engine.latency)
            Section {
                Button("Copy timing report") { UIPasteboard.general.string = engine.diag.report(engine: engine); engine.toast("Timing report copied") }
                Button("Reset timing controls", role: .destructive) { engine.resetKeys(["displayPolicy", "minDisplay", "heartbeatInterval", "translateAhead"]) }
            }
        }.navigationTitle("Timing & responsiveness").navigationBarTitleDisplayMode(.inline)
            .onChange(of: key) { _, _ in engine.timingSettingsChanged() }
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
    @AppStorage("homeMetrics") private var metrics = true
    @AppStorage("homeQuickExpanded") private var quick = false
    @AppStorage("homeDetailsExpanded") private var details = false
    var body: some View {
        List {
            Section("Focus reader") {
                Picker("Reader font", selection: $font) { ForEach(PiPFont.allCases) { Text($0.title).tag($0.rawValue) } }
                Stepper("Line spacing · \(Int(spacing))", value: $spacing, in: 0...16, step: 1)
                Picker("Reading width", selection: $width) { Text("Full width").tag("full"); Text("Narrow column").tag("narrow") }
            }
            Section {
                Picker("Photo OCR resolution", selection: $edge) {
                    Text("1600 px · lighter").tag(1600)
                    Text("2400 px · standard").tag(2400)
                    Text("3200 px · more small-text detail").tag(3200)
                }
                Toggle("Translate after reading a photo", isOn: $autoTranslate)
            } header: { Text("Text & photo workspace") } footer: {
                Text("2400 px keeps the previous default. Larger photos may take longer to read and use more main-app memory. This setting does not affect live screen capture.")
            }
            Section("Live screen") {
                Toggle("Show timing cards", isOn: $metrics)
                Toggle("Keep quick settings expanded", isOn: $quick)
                Toggle("Keep troubleshooting expanded", isOn: $details)
            }
            Section {
                Button("Reset reader & workspace", role: .destructive) { engine.resetKeys(["readerFont", "readerSpacing", "readerWidth", "photoOCREdge", "photoAutoTranslate", "homeMetrics", "homeQuickExpanded", "homeDetailsExpanded"]) }
            }
        }.navigationTitle("Reader & workspace").navigationBarTitleDisplayMode(.inline)
    }
}

struct FeedbackStorageSettings: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @AppStorage("hapticStrength") private var haptics = "light"
    @AppStorage("autoCopyFormat") private var copyFormat = "translation"
    @AppStorage("interruptSpeech") private var interrupt = true
    @AppStorage("historyCapacity") private var history = 500
    @AppStorage("diagSamples") private var samples = 600
    var body: some View {
        List {
            Section("Feedback behaviour") {
                Picker("Haptic strength", selection: $haptics) { Text("Light").tag("light"); Text("Medium").tag("medium"); Text("Strong").tag("strong") }
                Picker("Automatic clipboard format", selection: $copyFormat) {
                    Text("Translation").tag("translation"); Text("Original").tag("original"); Text("Both").tag("bilingual")
                }
                Toggle("New speech interrupts previous speech", isOn: $interrupt)
                Text("Haptics, automatic copying and speech must also be enabled in Floating window settings.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Picker("History limit", selection: $history) { Text("100 entries").tag(100); Text("250 entries").tag(250); Text("500 entries").tag(500); Text("1000 entries").tag(1000) }
                NavigationLink("Manage translation memory") { MemoryManagementView() }
                Picker("Diagnostic samples per series", selection: $samples) { Text("300").tag(300); Text("600").tag(600); Text("1200").tag(1200) }
            } header: { Text("Storage budgets") } footer: {
                Text("History and diagnostic sample limits are separate from Translation Memory 2.0. The memory page controls RAM cache and SQLite management thresholds without deleting committed translations.")
            }
            Section { Button("Reset feedback & budgets", role: .destructive) { engine.resetKeys(["hapticStrength", "autoCopyFormat", "interruptSpeech", "historyCapacity", "diagSamples"]) } }
        }.navigationTitle("Feedback & storage").navigationBarTitleDisplayMode(.inline)
            .onDisappear { engine.applyStorageSettings() }
    }
}
