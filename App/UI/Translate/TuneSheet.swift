// ScreenLingo – App – Translate: Tune sheet (2.1.0, spec §13.5.1; replaces the More sheet)
// Area, window size, show original, clear when text ends, scene, content and reading speed.
import SwiftUI

struct TuneSheet: View {
    let engine: TranslatorEngine
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @AppStorage("area") private var area = OCRArea.smart.rawValue
    @AppStorage("winSize") private var winSize = WindowSize.normal.rawValue
    @AppStorage("showOriginal") private var showOriginal = false
    @AppStorage("autoClear") private var autoClear = true
    @AppStorage("mode") private var mode = TranslateMode.movie.rawValue
    @AppStorage("speed") private var speed = SpeedPreset.balanced.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CaptionPreview()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    Picker("Area to read", selection: $area) { ForEach(OCRArea.allCases) { Text($0.title).tag($0.rawValue) } }
                    Button { router.present(.captureArea) } label: { LensRow(title: "Adjust the band", symbol: "viewfinder") }
                    Picker("Content style", selection: Binding(get: { mode }, set: { PresetRecognitionPolicy.apply(mode: $0) })) {
                        ForEach(TranslateMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Reading speed", selection: $speed) { ForEach(SpeedPreset.allCases) { Text($0.title).tag($0.rawValue) } }
                } header: { Text("Reading") } footer: {
                    Text("Content style sets the reading options that suit it: subtitles, game text or comics.")
                }
                Section {
                    Picker("Window size", selection: $winSize) { ForEach(WindowSize.allCases) { Text($0.title).tag($0.rawValue) } }
                    Toggle("Show original text", isOn: $showOriginal)
                    Toggle("Clear when text ends", isOn: $autoClear)
                } header: { Text("Floating caption") } footer: {
                    Text("Clear when text ends removes the caption when the screen text goes away.")
                }
                Section("Scene") {
                    ScenesStrip(store: engine.presets)
                }
            }
            .kitPage()
            .navigationTitle("Reading and window")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: area) { _, _ in engine.syncConfig() }
            .onChange(of: mode) { _, _ in engine.pipelineSettingsChanged() }
            .onChange(of: speed) { _, _ in engine.syncConfig() }
            .onChange(of: winSize) { _, _ in engine.applyWindowSize() }
            .onChange(of: showOriginal) { _, _ in engine.applyStyle() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// The capture-area band editor as a full-screen page. Saves the same keys the old editor saved.
struct AreaSheet: View {
    @EngineHandle private var engine
    @EnvironmentObject private var feedback: FeedbackCenter
    @Environment(\.dismiss) private var dismiss
    @AppStorage("customY0") private var lower = 0.0
    @AppStorage("customY1") private var upper = 0.5
    @AppStorage("area") private var area = "smart"

    var body: some View {
        AreaEditor(initial: ExportFormat.normalizedArea(lower, upper),
                   onSave: { range in
                       lower = range.lowerBound; upper = range.upperBound; area = "custom"
                       engine.syncConfig()
                       feedback.show("Reading area saved", severity: .success)
                       dismiss()
                   },
                   onCancel: { dismiss() })
    }
}
