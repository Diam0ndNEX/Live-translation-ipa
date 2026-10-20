import SwiftUI
import ReplayKit
import Translation

@main
struct ScreenTranslatorApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        v.preferredExtension = Shared.extensionBundleID
        v.showsMicrophoneButton = false
        return v
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var engine = TranslatorEngine()

    var body: some View {
        NavigationStack {
            Form {
                Section("Translate into") {
                    Picker("Language", selection: $engine.targetCode) {
                        ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                    }
                }
                Section("1 · Floating window") {
                    PiPPreview(layer: engine.pip.displayLayer)
                        .frame(height: 170)
                        .listRowInsets(EdgeInsets())
                    Button("Start floating PiP") { engine.startPiP() }
                }
                Section("2 · Screen capture") {
                    HStack {
                        Text("Tap icon → Start Broadcast")
                        Spacer()
                        BroadcastPicker().frame(width: 44, height: 44)
                    }
                    Text("Then switch to your game/app. Text on screen is translated in the PiP window.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Status") {
                    Text(engine.status)
                    if !engine.original.isEmpty {
                        Text(engine.original).font(.caption).foregroundStyle(.secondary)
                        Text(engine.translated).bold()
                    }
                }
            }
            .navigationTitle("Screen Translator")
        }
        .translationTask(engine.legacyConfig) { session in
            await engine.runLegacy(session)
        }
    }
}
