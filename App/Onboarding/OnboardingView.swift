// ScreenLingo – App – Guided setup (2.1.0, spec §13.5.7)
import SwiftUI
import Translation

/// One screen, three live rows that turn green as they really happen: language pack ready, broadcast started,
/// floating window on screen. Done enables when all three are green. Skip is always there; unfinished setup
/// comes back as one "Finish setup" row on Translate.
struct OnboardingView: View {
    let engine: TranslatorEngine
    @Binding var done: Bool
    @AppStorage("setupState") private var setupState = ""
    @StateObject private var pair: EngineSlice<PairSnapshot>
    @StateObject private var capture: EngineSlice<CaptureSnapshot>
    @State private var languagesOpen = false
    @Environment(\.dynamicTypeSize) private var typeSize

    init(engine: TranslatorEngine, done: Binding<Bool>) {
        self.engine = engine
        _done = done
        _pair = StateObject(wrappedValue: EngineSlice(engine) { PairSnapshot.read($0) })
        _capture = StateObject(wrappedValue: EngineSlice(engine) { CaptureSnapshot.read($0) })
    }

    private var p: PairSnapshot { pair.value }
    private var packDone: Bool { p.packState == .ready || p.packState == .autoDetect }
    private var broadcastDone: Bool { capture.value.alive }
    private var windowDone: Bool { capture.value.pipActive }
    private var allDone: Bool { packDone && broadcastDone && windowDone }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Three quick checks. Each one turns green when it has actually happened on your phone.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                Section {
                    CheckRow(number: 1, title: "Language pair ready", done: packDone, detail: packDetail) {
                        LanguagePairTitle(source: LanguageNames.name(p.source, in: p.languages),
                                          target: LanguageNames.name(p.target, in: p.languages),
                                          status: p.packState.title, statusSymbol: p.packState.symbol,
                                          canSwap: p.source != "auto",
                                          onSource: { languagesOpen = true }, onTarget: { languagesOpen = true },
                                          onSwap: { engine.swapLanguages() })
                        if p.source != "auto", p.statuses[p.source] == .supported {
                            Button("Get the \(LanguageNames.name(p.source, in: p.languages)) pack") { engine.download(p.source) }
                                .buttonStyle(.borderedProminent)
                                .frame(minHeight: 44)
                        }
                    }
                    CheckRow(number: 2, title: "Start a broadcast", done: broadcastDone,
                             detail: "Tap the button, choose ScreenLingo Capture, then Start Broadcast.") {
                        HStack(spacing: KitSpace.row) {
                            // Capture only (2.2.1, U3). iOS may refuse to open the floating window while the capture sheet
                            // is coming up, so step 3 has its own button.
                            StartButton(live: broadcastDone) { engine.captureRequested() }
                            .scaleEffect(0.6)
                            .frame(width: 106, height: 106)
                            Text(capture.value.status.title).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    CheckRow(number: 3, title: "Floating window is on screen", done: windowDone,
                             detail: windowDone ? "It floats over other apps while you watch."
                                                : "After the broadcast starts, tap the button. Then switch to any app with text.") {
                        if !windowDone {
                            Button("Open the floating window") { engine.startPiP() }
                                .buttonStyle(.bordered)
                                .frame(minHeight: 44)
                                .disabled(!broadcastDone)
                        }
                    }
                }
            }
            .kitPage()
            // 2.2.2: the long title ended in "Set up Scree…" at accessibility sizes.
            .navigationTitle(typeSize.isAccessibilitySize ? "Set up" : "Set up ScreenLingo")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { setupState = "skipped"; done = true }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    setupState = "done"
                    done = true
                } label: {
                    Text(allDone ? "Done" : "Done (finish the checks first)")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!allDone)
                .padding(.horizontal, KitSpace.margin)
                .padding(.vertical, KitSpace.tight)
            }
            .sheet(isPresented: $languagesOpen) { LanguageSheet(engine: engine) }
            .sensoryFeedback(.success, trigger: allDone)
        }
    }

    private var packDetail: String {
        switch p.packState {
        case .ready: return "Works offline."
        case .autoDetect: return "Auto-detect needs no download up front."
        case .checking: return "Checking which packs are on this phone…"
        case .needsDownload: return p.downloadMessage.isEmpty ? "This language needs a one-time download." : p.downloadMessage
        case .unsupported: return "This pair isn't supported on this phone. Choose another language."
        }
    }
}

/// A numbered check that turns green when it has happened. Never green on a guess.
private struct CheckRow<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    let detail: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: KitSpace.row) {
            HStack(spacing: KitSpace.row) {
                Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                    .font(.title2)
                    .foregroundStyle(done ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(.vertical, KitSpace.tight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number): \(title), \(done ? "done" : "not done")")
    }
}
