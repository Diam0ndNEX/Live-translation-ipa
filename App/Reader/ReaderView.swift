// ScreenLingo – App – Focus reader (2.0.0 build 89)
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

    private var hasText: Bool { !output.value.translated.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: centered ? .center : .leading, spacing: Space.xl) {
                    if !hasText {
                        EmptyState(title: "Ready to read", symbol: "text.book.closed", message: "Start a live translation, or translate text in Text & photos.")
                    } else {
                        StatusPill(text: output.value.frozen ? "Held" : (output.value.translating ? "Translating" : "Live"),
                                   symbol: output.value.frozen ? "pause.circle.fill" : "dot.radiowaves.left.and.right",
                                   severity: output.value.frozen ? .warning : .info)
                        Text(output.value.translated).font(.system(size: size * scale, weight: .semibold, design: design))
                            .lineSpacing(max(0, min(16, spacing))).textSelection(.enabled)
                        if showOriginal, !output.value.original.isEmpty {
                            VStack(alignment: centered ? .center : .leading, spacing: Space.s) {
                                SectionHeader(title: "Original")
                                Text(output.value.original).font(.system(size: max(15, size * 0.6) * scale, design: design))
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                            }.infoCard()
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
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: output.value.translated) { Image(systemName: "square.and.arrow.up") }
                        .disabled(!hasText).accessibilityLabel("Share text")
                }
            }
            .safeAreaInset(edge: .bottom) { controlBar }
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

    /// The four things you do while reading, always in reach.
    private var controlBar: some View {
        HStack(spacing: Space.s) {
            barButton(output.value.frozen ? "play.fill" : "pause.fill", output.value.frozen ? "Resume" : "Hold", enabled: hasText) {
                engine.toggleFrozenOutput()
            }
            barButton("speaker.wave.2", "Listen", enabled: hasText) { engine.speak(output.value.translated) }
            barButton("doc.on.doc", "Copy", enabled: hasText) {
                UIPasteboard.general.string = output.value.translated; feedback.show("Copied", severity: .success)
            }
            barButton("textformat.size", "Text") { showControls = true }
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.s)
        .background(.regularMaterial)
    }

    private func barButton(_ symbol: String, _ title: String, enabled: Bool = true, run: @escaping () -> Void) -> some View {
        Button { Feedback.tap(); run() } label: {
            VStack(spacing: Space.xs) {
                Image(systemName: symbol).font(.title3.weight(.semibold))
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
}
