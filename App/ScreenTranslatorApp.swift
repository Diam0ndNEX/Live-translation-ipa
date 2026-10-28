// Screen Translator – App – v0.11.0
import SwiftUI
import Translation

@main
struct ScreenTranslatorApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}

struct RootView: View {
    @StateObject private var engine = TranslatorEngine()
    @Environment(\.scenePhase) private var phase
    @AppStorage("accent") private var accent = AccentChoice.blue.rawValue
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("diagnosticsEnabled") private var diagnosticsEnabled = true
    @AppStorage("detailedCollection") private var detailedCollection = false
    @AppStorage("showSessionSpeakers") private var showSessionSpeakers = true
    @AppStorage("privateSession") private var privateSession = false
    @AppStorage("coolMode") private var coolMode = false
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView().tabItem { Label("Live", systemImage: "captions.bubble.fill") }.tag(0)
            LanguagesView().tabItem { Label("Languages", systemImage: "globe") }.tag(1)
            HistoryView().tabItem { Label("Library", systemImage: "books.vertical.fill") }.tag(2)
            DiagnosticsView().tabItem { Label("Activity", systemImage: "waveform.path.ecg") }.tag(3)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(4)
        }
        .environmentObject(engine)
        .environment(\.selectTab, { tab = $0 })
        .preferredColorScheme(.dark)
        .tint((AccentChoice(rawValue: accent) ?? .blue).start)
        .overlay(alignment: .top) {
            if let t = engine.toastText {
                ToastView(text: t)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: engine.toastText)
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { if !$0 { onboarded = true } })) {
            OnboardingView(done: $onboarded)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
        .translationTask(engine.legacyConfig) { session in await engine.runLegacy(session) }
        .translationTask(engine.downloadConfig) { session in await engine.runDownload(session) }
        .task {
            engine.diag.noteExecutionPhase(phase == .active ? "active" : (phase == .background ? "background" : "inactive"), pipActive: engine.pipActive)
            await engine.loadLanguages()
        }
        .onChange(of: diagnosticsEnabled) { _, _ in engine.diagnosticsSettingsChanged() }
        .onChange(of: detailedCollection) { _, _ in engine.diagnosticsSettingsChanged() }
        .onChange(of: privateSession) { _, _ in engine.diag.clearSpeakers() }
        .onChange(of: showSessionSpeakers) { _, _ in engine.diag.clearSpeakers() }
        .onChange(of: coolMode) { _, _ in engine.powerPolicyChanged() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            engine.handleMemoryPressure()
        }
        .onChange(of: phase) { _, p in
            engine.diag.noteExecutionPhase(p == .active ? "active" : (p == .background ? "background" : "inactive"), pipActive: engine.pipActive)
            if p == .active { engine.server.start() }
            if p == .background { engine.saveMemory(force: true) }
        }
    }
}
