// Screen Translator – App – v0.9.0
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
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            LanguagesView().tabItem { Label("Languages", systemImage: "globe") }.tag(1)
            HistoryView().tabItem { Label("History", systemImage: "clock") }.tag(2)
            DiagnosticsView().tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }.tag(3)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(4)
        }
        .id(accent)                                   // rebuild so a new accent colour shows everywhere
        .environmentObject(engine)
        .environment(\.selectTab, { tab = $0 })
        .preferredColorScheme(.dark)
        .tint(Theme.accent.start)
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
        .task { await engine.loadLanguages() }
        .onChange(of: phase) { _, p in if p == .active { engine.server.start() } }
    }
}
