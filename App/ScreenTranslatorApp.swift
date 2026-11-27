// ScreenLingo – App – Root (2.1.0; 2.7.0 sidebar-adaptable tabs and keyboard shortcuts)
import SwiftUI
import Combine
import Translation
import UIKit

@main
struct ScreenTranslatorApp: App {
    /// Narrows orientations to portrait except on Translate and Focus mode.
    @UIApplicationDelegateAdaptor(ScreenLingoAppDelegate.self) private var appDelegate
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
    @AppStorage("translationSystem") private var translationSystem = TranslationSystem.legacy.rawValue

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
            // 2.2.1 (E14): the root is the only owner of these two keys; the Translate tab and the settings pages used to repeat them.
            .onChange(of: translationSystem) { _, _ in model.engine.translationSystemChanged() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                model.engine.handleMemoryPressure()
            }
            .onChange(of: phase) { _, p in
                let engine = model.engine
                engine.setAppInterfaceVisible(p != .background)
                engine.diag.noteExecutionPhase(p == .active ? "active" : (p == .background ? "background" : "inactive"), pipActive: engine.pipActive)
                if p == .active { engine.server.start(); engine.openSkippedWindow() }
                if p == .background {
                    if engine.manualMode { engine.endWorkspace() } // typing mode pauses capture; do not leave it paused behind the person's back (U2)
                    engine.flushHistorySave()                       // the Library is written after a second of quiet (E15)
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
        // 2.7.0: the iOS 18 Tab API with the sidebar-adaptable style. iPhone keeps the tab bar; iPad gets the floating
        // tab bar that turns into a sidebar.
        TabView(selection: $router.tab) {
            Tab(AppTab.translate.title, systemImage: AppTab.translate.symbol, value: AppTab.translate) { TranslateScreen(engine: model.engine) }
            Tab(AppTab.library.title, systemImage: AppTab.library.symbol, value: AppTab.library) { LibraryScreen(engine: model.engine) }
            Tab(AppTab.diagnostics.title, systemImage: AppTab.diagnostics.symbol, value: AppTab.diagnostics) { DiagnosticsView() }
            Tab(AppTab.settings.title, systemImage: AppTab.settings.symbol, value: AppTab.settings) { SettingsView() }
        }
        .tabViewStyle(.sidebarAdaptable)
        .modifier(TabBarMinimize())
        .background { KeyCommands(engine: model.engine, router: model.router, feedback: model.feedback) }
        .tint(theme.tint)
        .preferredColorScheme(theme.appearance.scheme)
        .overlay(alignment: .top) { NoticeHost(center: model.feedback) }
        .background(TranslationHost())
        // 2.2.2: the floating window can only start while its video layer is on screen. Nothing mounted it since the
        // 2.1.0 rebuild, so every "Open floating window" button silently failed. The root keeps it alive on every tab.
        .overlay(alignment: .bottomTrailing) { PiPHost(layer: model.engine.pip.displayLayer) }
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
        #if SCREENLINGO_FIXTURES
        .modifier(FixtureHost(router: model.router, engine: model.engine, feedback: model.feedback))
        #endif
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
        case .more: TuneSheet(engine: engine)
        case .status: SessionSheet(engine: engine)
        case .test: TestSheet(engine: engine)
        // 2.7.0: on iPad these three open as large pages instead of a small form sheet (no change on iPhone).
        case .reader: FocusMode(engine: engine).presentationSizing(.page)
        case .captureArea: AreaSheet().presentationSizing(.page)
        case .testRuns: TestRunsScreen(diag: engine.diag).presentationSizing(.page)
        case .languages: LanguageSheet(engine: engine)
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
