// ScreenLingo – App – UI fixtures: kit gallery (2.1.0, spec §13.9 step 1)
// Fixture-only page that shows every App/UI/Kit component with sample data, so the screenshot job can show them
// before any screen uses them. Compiled only with SCREENLINGO_FIXTURES.
#if SCREENLINGO_FIXTURES
import SwiftUI

struct KitGallery: View {
    @State private var showArea = false

    var body: some View {
        NavigationStack {
            List {
                Section("LanguagePairTitle") {
                    LanguagePairTitle(source: "Portuguese", target: "English", status: "Works offline",
                                      statusSymbol: "checkmark.circle.fill", onSource: {}, onTarget: {}, onSwap: {})
                    LanguagePairTitle(source: "Auto-detect", target: "Japanese", status: "Japanese pack needs download",
                                      statusSymbol: "arrow.down.circle", statusTone: .caution, canSwap: false,
                                      onSource: {}, onTarget: {}, onSwap: {})
                }
                Section("StartButton") {
                    HStack(spacing: 0) {
                        StartButton(live: false)
                        StartButton(live: true)
                    }
                    .frame(maxWidth: .infinity)
                }
                Section("PhaseHeader") {
                    PhaseHeader(phase: .idle)
                    PhaseHeader(phase: .starting, elapsed: 3, mode: "Low Latency")
                    PhaseHeader(phase: .live, elapsed: 252, mode: "Low Latency", action: {})
                    PhaseHeader(phase: .paused, elapsed: 252, mode: "Legacy")
                    PhaseHeader(phase: .attention(.windowClosed), elapsed: 600)
                    PhaseHeader(phase: .attention(.captureLost))
                }
                Section("LiveCaption") {
                    LiveCaption(translated: "Hello, how are you today?", original: "Olá, como você está hoje?", stage: .translating)
                    LiveCaption(translated: "", stage: .reading)
                    LiveCaption(translated: "Wait. If the bridge is closed, we have to go around through the old market, and that takes at least two more hours.",
                                original: "Espera. Se a ponte estiver fechada, temos de dar a volta pelo mercado antigo.", held: true)
                }
                Section("StatLine") {
                    StatLine(value: "412 ms", caption: "Typical delay · screen text to floating window",
                             samples: [380, 420, 455, 401, 390, 512, 470, 412, 398, 405],
                             secondary: ["P95 780 ms", "126 translations", "0 problems"])
                    StatLine(value: nil, caption: "Typical delay", emptyCaption: "No session yet")
                }
                Section("LensRow") {
                    NavigationLink { Text("Speed") } label: { LensRow(title: "Speed", value: "412 ms median", symbol: "speedometer") }
                    NavigationLink { Text("Device") } label: { LensRow(title: "Device", value: "Nominal · 41%", symbol: "iphone") }
                    NavigationLink { Text("Language") } label: {
                        LensRow(title: "Language", value: "Pack missing", symbol: "globe", valueTone: .caution)
                    }
                }
                Section("CaptionPreview") {
                    CaptionPreview()
                    HStack {
                        CaptionPreview(themeOverride: "light", compact: true)
                        CaptionPreview(themeOverride: "yellow", compact: true)
                        CaptionPreview(themeOverride: "sepia", compact: true)
                    }
                }
                Section("AreaEditor") {
                    Button("Open the reading area editor") { showArea = true }
                }
            }
            .navigationTitle("Kit")
        }
        .fullScreenCover(isPresented: $showArea) {
            AreaEditor(initial: 0...0.35, onSave: { _ in showArea = false }, onCancel: { showArea = false })
        }
    }
}
#endif
