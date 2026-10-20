// Screen Translator – App UI – v0.2.0
import SwiftUI
import ReplayKit
import Translation

@main
struct ScreenTranslatorApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}

// MARK: - Root
struct RootView: View {
    @StateObject private var engine = TranslatorEngine()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }
            LanguagesView().tabItem { Label("Languages", systemImage: "globe") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .environmentObject(engine)
        .preferredColorScheme(.dark)
        .translationTask(engine.legacyConfig) { session in await engine.runLegacy(session) }
        .translationTask(engine.downloadConfig) { session in await engine.runDownload(session) }
        .task { await engine.loadLanguages() }
        .onChange(of: phase) { _, p in if p == .active { engine.server.start() } }
    }
}

// MARK: - Broadcast picker
final class PickerHolder {
    var view: RPSystemBroadcastPickerView?
    func trigger() {
        view?.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .allTouchEvents)
    }
}

struct BroadcastPicker: UIViewRepresentable {
    let holder: PickerHolder
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        v.preferredExtension = Self.extensionID()
        v.showsMicrophoneButton = false
        holder.view = v
        return v
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}

    /// Finds the bundled .appex so it works even if a sideloader renames bundle IDs.
    static func extensionID() -> String? {
        guard let dir = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        for u in items where u.pathExtension == "appex" {
            if let id = Bundle(url: u)?.bundleIdentifier { return id }
        }
        return nil
    }
}

// MARK: - Helpers
extension View {
    func card() -> some View {
        self.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct LangMenu: View {
    @Binding var code: String
    let items: [LangItem]
    var allowAuto = false

    var label: String {
        code == "auto" ? "Auto-detect" : (items.first { $0.code == code }?.name ?? code)
    }
    var body: some View {
        Menu {
            if allowAuto { Button("Auto-detect") { code = "auto" } }
            ForEach(items) { i in Button(i.name) { code = i.code } }
        } label: {
            HStack {
                Text(label).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.caption)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Home
struct HomeView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @AppStorage("mode") private var mode = TranslateMode.movie.rawValue
    @AppStorage("area") private var area = OCRArea.smart.rawValue
    @AppStorage("winSize") private var winSize = WindowSize.normal.rawValue
    @AppStorage("showOriginal") private var showOriginal = true
    @State private var holder = PickerHolder()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text("Screen Translator").font(.title2.bold())
                    Text(AppVersion.full).font(.caption)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(LinearGradient(colors: [.blue, .indigo], startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 18))

                HStack(spacing: 10) {
                    LangMenu(code: $engine.sourceCode, items: engine.languages, allowAuto: true)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    LangMenu(code: $engine.targetCode, items: engine.languages)
                }

                VStack(spacing: 8) {
                    Text(engine.translated.isEmpty ? "Translations appear here and in the PiP window" : engine.translated)
                        .font(.headline)
                        .foregroundStyle(engine.translated.isEmpty ? .secondary : Color.cyan)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 90)
                }
                .card()

                VStack(spacing: 4) {
                    Picker("Translate mode", selection: $mode) {
                        ForEach(TranslateMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Divider()
                    Picker("OCR area", selection: $area) {
                        ForEach(OCRArea.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Divider()
                    Picker("Window size", selection: $winSize) {
                        ForEach(WindowSize.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .onChange(of: winSize) { _, _ in engine.applyWindowSize() }
                    Divider()
                    Toggle("Show original text", isOn: $showOriginal)
                }
                .card()

                HStack(spacing: 10) {
                    Button {
                        engine.startPiP()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { holder.trigger() }
                    } label: {
                        Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity).padding()
                            .background(LinearGradient(colors: [.blue, .indigo], startPoint: .leading, endPoint: .trailing),
                                        in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button { engine.pip.stop() } label: {
                        Label("Stop PiP", systemImage: "stop.fill").padding()
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .foregroundStyle(.white)
                .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Diagnostics").font(.caption.bold()).foregroundStyle(.secondary)
                    HStack {
                        Circle().fill(engine.captureAlive ? Color.green : Color.red).frame(width: 10, height: 10)
                        Text(engine.captureAlive
                             ? "Capture connected · \(engine.frames) frames · \(engine.ocrCount) text updates"
                             : "Capture not connected")
                            .font(.footnote)
                    }
                    Text(engine.status).font(.footnote).foregroundStyle(.secondary)
                    if engine.extensionVersion != "–" && engine.extensionVersion != AppVersion.version {
                        Text("⚠️ Capture extension is v\(engine.extensionVersion) but app is v\(AppVersion.version). Reinstall the IPA.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Test translation") { engine.runTest() }
                            .buttonStyle(.bordered)
                        Spacer()
                        Text("Manual capture:").font(.footnote).foregroundStyle(.secondary)
                        BroadcastPicker(holder: holder).frame(width: 44, height: 44)
                    }
                }
                .card()
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - Languages
struct LanguagesView: View {
    @EnvironmentObject var engine: TranslatorEngine

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Offline translation needs a language pack for each language. Tap the download icon next to a language – iOS shows its own download prompt. Status is checked against your target language (\(engine.targetCode)).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Languages") {
                    ForEach(engine.languages) { l in
                        HStack {
                            Text(l.name)
                            Spacer()
                            switch engine.langStatus[l.code] {
                            case .installed:
                                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                    .labelStyle(.iconOnly)
                            case .supported:
                                Button { engine.download(l.code) } label: {
                                    Image(systemName: "arrow.down.circle")
                                }.buttonStyle(.borderless)
                            case .unsupported:
                                Text(l.code == engine.targetCode ? "target" : "–").foregroundStyle(.secondary)
                            default:
                                ProgressView()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Languages")
            .toolbar { Button("Refresh") { Task { await engine.refreshStatus() } } }
        }
    }
}

// MARK: - Settings
struct SettingsView: View {
    @EnvironmentObject var engine: TranslatorEngine

    var body: some View {
        NavigationStack {
            List {
                Section("Version") {
                    LabeledContent("App", value: AppVersion.full)
                    LabeledContent("Capture extension", value: engine.extensionVersion == "–" ? "not seen yet" : "v\(engine.extensionVersion)")
                }
                Section("Changelog") {
                    ForEach(AppVersion.changelog, id: \.0) { v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("v\(v.0)").bold()
                            Text(v.1).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Help") {
                    Text("1. Languages tab → download source and target packs.\n2. Home → Start. Allow PiP, then Start Broadcast.\n3. Switch to your app. Use Test translation if nothing shows.")
                        .font(.footnote)
                }
                Section {
                    Button("Reset settings", role: .destructive) {
                        for k in ["source", "target", "mode", "area", "winSize", "showOriginal"] {
                            UserDefaults.standard.removeObject(forKey: k)
                        }
                        engine.sourceCode = "auto"; engine.targetCode = "en"
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
