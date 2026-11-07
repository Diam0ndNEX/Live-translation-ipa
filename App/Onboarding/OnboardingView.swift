// ScreenLingo – App – Guided setup (2.0.0 build 86)
import SwiftUI
import Translation

/// Three real checks: pick languages and download the pack, start a broadcast, confirm the floating window.
/// Skip is allowed and can be resumed from the "Finish setup" banner on Live.
struct OnboardingView: View {
    let engine: TranslatorEngine
    @Binding var done: Bool
    @AppStorage("setupState") private var setupState = ""
    @State private var step = 0
    @StateObject private var pair: EngineSlice<PairSnapshot>
    @StateObject private var capture: EngineSlice<CaptureSnapshot>

    init(engine: TranslatorEngine, done: Binding<Bool>) {
        self.engine = engine
        _done = done
        _pair = StateObject(wrappedValue: EngineSlice(engine) { PairSnapshot.read($0) })
        _capture = StateObject(wrappedValue: EngineSlice(engine) { CaptureSnapshot.read($0) })
    }

    private var windowOpen: Bool { capture.value.alive || capture.value.pipActive }

    var body: some View {
        VStack(spacing: Space.l) {
            HStack {
                Text("Step \(step + 1) of 3").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Skip for now") { setupState = "skipped"; done = true }.foregroundStyle(.secondary).frame(minHeight: 44)
            }
            ScrollView {
                VStack(spacing: Space.xl) {
                    switch step {
                    case 0: languages
                    case 1: start
                    default: confirm
                    }
                }.padding(.vertical, Space.l)
            }
            HStack(spacing: Space.m) {
                if step > 0 { SecondaryButton(title: "Back") { step -= 1 } }
                PrimaryButton(title: step < 2 ? "Next" : "Finish") {
                    if step < 2 { step += 1 } else { setupState = "done"; done = true }
                }
            }
        }
        .padding(Space.l)
        .background(Palette.background.ignoresSafeArea())
    }

    private func header(_ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(spacing: Space.m) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var languages: some View {
        VStack(spacing: Space.l) {
            header("globe", "Pick your languages", "Translation runs on your phone, so each language needs a one-time download.")
            LanguagePairBar(
                source: Binding(get: { pair.value.source }, set: { engine.sourceCode = $0 }),
                target: Binding(get: { pair.value.target }, set: { engine.targetCode = $0 }),
                items: pair.value.languages, swapDisabled: pair.value.source == "auto"
            ) { engine.swapLanguages() }
            StatusPill(text: pair.value.packState.title, symbol: pair.value.packState.symbol, severity: pair.value.packState.severity)
            if pair.value.source != "auto", pair.value.statuses[pair.value.source] == .supported {
                PrimaryButton(title: "Download language pack", symbol: "arrow.down.circle") { engine.download(pair.value.source) }
            }
            if !pair.value.downloadMessage.isEmpty { Banner(text: pair.value.downloadMessage) }
        }
    }

    private var start: some View {
        VStack(spacing: Space.l) {
            header("play.rectangle.fill", "Start a test broadcast", Strings.startHelp)
            BroadcastPicker(onTap: { engine.captureRequested(); if !engine.pipActive { engine.startPiP() } })
                .frame(width: 84, height: 84)
                .background(Color.accentColor, in: Circle())
                .accessibilityLabel("Start screen capture")
            StatusPill(text: capture.value.status.title, symbol: capture.value.status.symbol, severity: capture.value.severity)
        }
    }

    private var confirm: some View {
        VStack(spacing: Space.l) {
            header("pip", "Check the floating window", "Switch to any app with text. A small translation window should float on top.")
            if windowOpen {
                StatusPill(text: "Capture is running. You're set.", symbol: "checkmark.seal.fill", severity: .success)
            } else {
                StatusPill(text: "No floating window yet", symbol: "clock.fill", severity: .warning)
                Text("You can finish now and start from the Live tab at any time.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }
}
