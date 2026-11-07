// ScreenLingo – App – Root (2.0.0 build 85)
import SwiftUI
import Combine
import Translation
import UIKit

@main
struct ScreenTranslatorApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}

/// Owns the long-lived objects. It never publishes, so the root view does not redraw when the engine changes.
@MainActor
final class AppModel: ObservableObject {
    let engine = TranslatorEngine()
    let router = AppRouter()
    let feedback = FeedbackCenter()
    let theme = ThemeStore()
    let advanced = AdvancedMode()
    private var bag = Set<AnyCancellable>()

    init() {
        // The engine's toast text goes through the one feedback queue.
        engine.$toastText.compactMap { $0 }.sink { [feedback] text in
            let lower = text.lowercased()
            let bad = lower.contains("could not") || lower.contains("not a valid") || lower.contains("failed")
            feedback.show(text, severity: bad ? .error : .info)
        }.store(in: &bag)
    }
}

struct RootView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("diagnosticsEnabled") private var diagnosticsEnabled = true
    @AppStorage("detailedCollection") private var detailedCollection = false
    @AppStorage("showSessionSpeakers") private var showSessionSpeakers = true
    @AppStorage("privateSession") private var privateSession = false
    @AppStorage("coolMode") private var coolMode = false

    var body: some View {
        RootContent(model: model, onboarded: $onboarded)
            .environment(\.engineRef, model.engine)
            .environmentObject(model.engine)
            .environmentObject(model.router)
            .environmentObject(model.feedback)
            .environmentObject(model.theme)
            .environmentObject(model.advanced)
            .onOpenURL { model.router.open($0) }
            .task {
                let engine = model.engine
                engine.diag.noteExecutionPhase(phase == .active ? "active" : (phase == .background ? "background" : "inactive"), pipActive: engine.pipActive)
                engine.setAppInterfaceVisible(phase != .background)
                await engine.loadLanguages()
            }
            .onChange(of: diagnosticsEnabled) { _, _ in model.engine.diagnosticsSettingsChanged() }
            .onChange(of: detailedCollection) { _, _ in model.engine.diagnosticsSettingsChanged() }
            .onChange(of: privateSession) { _, _ in model.engine.diag.clearSpeakers() }
            .onChange(of: showSessionSpeakers) { _, _ in model.engine.diag.clearSpeakers() }
            .onChange(of: coolMode) { _, _ in model.engine.powerPolicyChanged() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                model.engine.handleMemoryPressure()
            }
            .onChange(of: phase) { _, p in
                let engine = model.engine
                engine.setAppInterfaceVisible(p != .background)
                engine.diag.noteExecutionPhase(p == .active ? "active" : (p == .background ? "background" : "inactive"), pipActive: engine.pipActive)
                if p == .active { engine.server.start() }
                if p == .background {
                    engine.diag.checkpointRun() // Test Run crash safety if iOS ends the app in the background
                    engine.saveMemory(force: true)
                    let backgroundTask = MemoryBackgroundTask()
                    backgroundTask.begin()
                    Task {
                        _ = await engine.flushPendingMemory(maxWaitSeconds: 2.5)
                        backgroundTask.end()
                    }
                }
            }
    }
}

/// Observes only the theme, the router and the feedback queue.
private struct RootContent: View {
    let model: AppModel
    @Binding var onboarded: Bool
    @ObservedObject private var theme: ThemeStore
    @ObservedObject private var router: AppRouter

    init(model: AppModel, onboarded: Binding<Bool>) {
        self.model = model
        _onboarded = onboarded
        _theme = ObservedObject(wrappedValue: model.theme)
        _router = ObservedObject(wrappedValue: model.router)
    }

    var body: some View {
        TabView(selection: $router.tab) {
            LiveView(engine: model.engine).tabItem { Label(AppTab.live.title, systemImage: AppTab.live.symbol) }.tag(AppTab.live)
            LibraryView(engine: model.engine).tabItem { Label(AppTab.library.title, systemImage: AppTab.library.symbol) }.tag(AppTab.library)
            LanguagesView(engine: model.engine).tabItem { Label(AppTab.languages.title, systemImage: AppTab.languages.symbol) }.tag(AppTab.languages)
            SettingsView().tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.symbol) }.tag(AppTab.settings)
        }
        .tint(theme.tint)
        .preferredColorScheme(theme.appearance.scheme)
        .overlay(alignment: .top) { NoticeHost(center: model.feedback) }
        .background(TranslationHost())
        .sheet(item: $router.sheet) { SheetHost(sheet: $0, engine: model.engine) }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { if !$0 { onboarded = true } })) {
            OnboardingView(engine: model.engine, done: $onboarded)
                .environmentObject(model.engine)
                .environmentObject(model.router)
                .environmentObject(model.feedback)
                .environmentObject(model.advanced)
                .preferredColorScheme(theme.appearance.scheme)
                .tint(theme.tint)
        }
    }
}

/// The two Apple Translation sessions need the engine's configurations; this tiny view is the only one that watches them.
private struct TranslationHost: View {
    @EnvironmentObject private var engine: TranslatorEngine
    var body: some View {
        Color.clear
            .translationTask(engine.legacyConfig) { session in await engine.runLegacy(session) }
            .translationTask(engine.downloadConfig) { session in await engine.runDownload(session) }
    }
}

/// One place that decides what each sheet shows.
private struct SheetHost: View {
    let sheet: AppSheet
    let engine: TranslatorEngine
    var body: some View {
        switch sheet {
        case .more: MoreSheet(engine: engine)
        case .status: StatusSheet(engine: engine)
        case .test: TestSheet(engine: engine)
        case .reader: ReaderView()
        case .captureArea: CaptureAreaEditor()
        case .workspace: TranslationWorkspace()
        case .diagnostics: DiagnosticsView()
        case .testRuns: TestRunsScreen(diag: engine.diag)
        }
    }
}

/// The system can suspend an app before its confirmed SQLite writes finish.
/// A short, explicitly ended background task gives the writer a bounded chance
/// to commit. It does not promise extra background time or hide failed writes.
@MainActor
private final class MemoryBackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "ScreenLingo translation memory flush",
            expirationHandler: { [weak self] in
                Task { @MainActor in self?.end() }
            })
    }

    func end() {
        guard identifier != .invalid else { return }
        let finished = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(finished)
    }
}
