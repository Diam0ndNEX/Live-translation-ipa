// ScreenLingo – App – Focus reader (2.0.0 build 85)
import SwiftUI

/// Large, calm text. All reading options live in one controls sheet.
struct ReaderView: View {
    let engine: TranslatorEngine
    @StateObject private var output: EngineSlice<OutputSnapshot>
    @EnvironmentObject private var feedback: FeedbackCenter
    @Environment(\.dismiss) private var dismiss
    @AppStorage("readerSize") private var size = 28.0
    @AppStorage("readerOriginal") private var showOriginal = true
    @AppStorage("readerAlignment") private var centered = false
    @AppStorage("readerFont") private var font = "rounded"
    @AppStorage("readerSpacing") private var spacing = 8.0
    @AppStorage("readerWidth") private var width = "full"
    @ScaledMetric(relativeTo: .title) private var scale = 1.0
    @State private var showControls = false

    init(engine: TranslatorEngine) {
        self.engine = engine
        _output = StateObject(wrappedValue: EngineSlice(engine) { OutputSnapshot.read($0) })
    }

    private var design: Font.Design {
        switch font { case "serif": return .serif; case "mono": return .monospaced; case "standard": return .default; default: return .rounded }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: centered ? .center : .leading, spacing: Space.xl) {
                    if output.value.translated.isEmpty {
                        EmptyState(title: "Ready to read", symbol: "text.book.closed", message: "Start a live translation, or translate text in Text & photos.")
                    } else {
                        Text(output.value.translated).font(.system(size: size * scale, weight: .medium, design: design))
                            .lineSpacing(max(0, min(16, spacing))).textSelection(.enabled)
                        if showOriginal, !output.value.original.isEmpty {
                            Divider()
                            Text(output.value.original).font(.system(size: max(15, size * 0.65) * scale))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                .multilineTextAlignment(centered ? .center : .leading)
                .frame(maxWidth: width == "narrow" ? 560 : .infinity, alignment: centered ? .center : .leading)
                .frame(maxWidth: .infinity).padding(Space.xl)
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Focus reader").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { engine.toggleFrozenOutput() } label: { Image(systemName: output.value.frozen ? "play.fill" : "pause.fill") }
                        .accessibilityLabel(output.value.frozen ? "Resume live text" : "Freeze current text")
                    Button { showControls = true } label: { Image(systemName: "textformat.size") }
                        .accessibilityLabel("Reading options")
                    Menu {
                        Button { engine.speak(output.value.translated) } label: { Label("Listen", systemImage: "speaker.wave.2") }
                        Button { UIPasteboard.general.string = output.value.translated; feedback.show("Copied", severity: .success) } label: { Label("Copy translation", systemImage: "doc.on.doc") }
                        ShareLink(item: output.value.translated) { Label("Share text", systemImage: "square.and.arrow.up") }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("More")
                }
            }
            .sheet(isPresented: $showControls) {
                SheetScaffold(title: "Reading options") {
                    Form {
                        Section("Text") {
                            HStack { Image(systemName: "textformat.size.smaller"); Slider(value: $size, in: 18...56).accessibilityLabel("Text size"); Image(systemName: "textformat.size.larger") }
                            HStack { Text("Line spacing"); Slider(value: $spacing, in: 0...16).accessibilityLabel("Line spacing") }
                            Picker("Font", selection: $font) {
                                Text("Rounded").tag("rounded"); Text("Standard").tag("standard"); Text("Serif").tag("serif"); Text("Monospaced").tag("mono")
                            }
                        }
                        Section("Layout") {
                            Toggle("Show original text", isOn: $showOriginal)
                            Toggle("Center text", isOn: $centered)
                            Picker("Width", selection: $width) { Text("Full").tag("full"); Text("Narrow").tag("narrow") }
                        }
                    }.scrollContentBackground(.hidden)
                }
                .presentationDetents([.medium, .large])
            }
        }
    }
}
