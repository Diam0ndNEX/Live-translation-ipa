// ScreenLingo – App – Translate: Focus mode (2.1.0, spec §13.5.1; replaces the Focus reader sheet)
// Full-screen text. Controls hide after 3 s and come back on tap. Uses the existing reader keys.
import SwiftUI

struct FocusMode: View {
    let engine: TranslatorEngine
    @StateObject private var output: EngineSlice<OutputSnapshot>
    @EnvironmentObject private var feedback: FeedbackCenter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("readerSize") private var size = 28.0
    @AppStorage("readerOriginal") private var showOriginal = true
    @AppStorage("readerAlignment") private var centered = false
    @AppStorage("readerFont") private var font = "rounded"
    @AppStorage("readerSpacing") private var spacing = 8.0
    @AppStorage("readerWidth") private var width = "full"
    @ScaledMetric(relativeTo: .title) private var scale = 1.0
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showOptions = false

    init(engine: TranslatorEngine) {
        self.engine = engine
        _output = StateObject(wrappedValue: EngineSlice(engine) { OutputSnapshot.read($0) })
    }

    private var design: Font.Design {
        switch font { case "serif": return .serif; case "mono": return .monospaced; case "standard": return .default; default: return .rounded }
    }
    private var hasText: Bool { !output.value.translated.isEmpty }

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: centered ? .center : .leading, spacing: KitSpace.group) {
                    if output.value.frozen {
                        Label("Held", systemImage: "pin.fill").font(.headline).foregroundStyle(.orange)
                    }
                    Text(hasText ? output.value.translated : "Waiting for text on screen")
                        .font(.system(size: size * scale, weight: .semibold, design: design))
                        .foregroundStyle(hasText ? Color.primary : Color.secondary)
                        .lineSpacing(max(0, min(16, spacing)))
                        .textSelection(.enabled)
                    if showOriginal, !output.value.original.isEmpty {
                        Text(output.value.original)
                            .font(.system(size: max(15, size * 0.6) * scale, design: design))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .multilineTextAlignment(centered ? .center : .leading)
                .frame(maxWidth: width == "narrow" ? 560 : .infinity, alignment: centered ? .center : .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, KitSpace.margin)
                .padding(.vertical, 72)
            }
            .contentShape(Rectangle())
            .onTapGesture { showControls() }
            if controlsVisible { topBar.transition(.opacity) }
        }
        .safeAreaInset(edge: .bottom) {
            if controlsVisible { bottomBar.transition(.opacity) }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : KitMotion.spring, value: controlsVisible)
        .onAppear { showControls() }
        .onDisappear { hideTask?.cancel() }
        .sheet(isPresented: $showOptions) { options }
        .statusBarHidden(!controlsVisible)
        .accessibilityAction(named: "Show controls") { showControls() }
    }

    private var topBar: some View {
        HStack {
            Button("Done") { dismiss() }.bold().frame(minHeight: 44)
            Spacer()
            ShareLink(item: output.value.translated) { Label("Share", systemImage: "square.and.arrow.up") }
                .disabled(!hasText)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, KitSpace.margin)
        .background(.bar)
    }

    private var bottomBar: some View {
        HStack(spacing: KitSpace.tight) {
            bar(output.value.frozen ? "Release" : "Hold", output.value.frozen ? "pin.slash" : "pin", enabled: hasText) { engine.toggleFrozenOutput() }
            bar("Listen", "speaker.wave.2", enabled: hasText) { engine.speak(output.value.translated) }
            bar("Copy", "doc.on.doc", enabled: hasText) {
                UIPasteboard.general.string = output.value.translated
                feedback.show("Copied", severity: .success)
            }
            bar("Text", "textformat.size", enabled: true) { showOptions = true }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, KitSpace.margin)
        .padding(.vertical, KitSpace.tight)
        .background(.bar)
    }

    private func bar(_ title: String, _ symbol: String, enabled: Bool, run: @escaping () -> Void) -> some View {
        Button { run(); showControls() } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(!enabled)
    }

    private var options: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    LabeledContent("Size") {
                        Slider(value: $size, in: 18...56) { Text("Text size") } minimumValueLabel: {
                            Image(systemName: "textformat.size.smaller")
                        } maximumValueLabel: { Image(systemName: "textformat.size.larger") }
                    }
                    LabeledContent("Line spacing") { Slider(value: $spacing, in: 0...16) { Text("Line spacing") } }
                    Picker("Font", selection: $font) {
                        Text("Rounded").tag("rounded"); Text("Standard").tag("standard"); Text("Serif").tag("serif"); Text("Monospaced").tag("mono")
                    }
                }
                Section("Layout") {
                    Toggle("Show original text", isOn: $showOriginal)
                    Toggle("Center text", isOn: $centered)
                    Picker("Width", selection: $width) { Text("Full").tag("full"); Text("Narrow").tag("narrow") }
                }
            }
            .navigationTitle("Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showOptions = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func showControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !showOptions else { return }
            controlsVisible = false
        }
    }
}
