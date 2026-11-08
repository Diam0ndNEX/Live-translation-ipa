// ScreenLingo – App – UI fixtures (2.1.0, spec §13.7 and §13.9 step 0)
// Compiled only when SCREENLINGO_FIXTURES is set. Only the screenshot workflow sets it, for a Debug simulator build;
// the Release build and the .ipa never contain this code.
#if SCREENLINGO_FIXTURES
import SwiftUI

/// A named screen state for screenshots, chosen with the launch argument `-uiFixture <name>`.
///
/// Step 0 (baseline of the build 90 screens): a fixture can only open the right tab or sheet. It does not fake
/// engine state, because the 2.0.0 views read `TranslatorEngine` directly and faking it would mean writing into the
/// engine. So the state fixtures (`live-short`, `paused`, `attention-lost`, `library-many`, …) show the idle screen
/// of their tab in the baseline. The 2.1.0 views read snapshot structs (`App/UI/Model`), and later steps make these
/// fixtures inject those snapshots instead, without starting capture.
enum UIFixture: String, CaseIterable {
    case idle
    case idlePackMissing = "idle-pack-missing"
    case starting
    case liveShort = "live-short"
    case liveLong = "live-long"
    case paused
    case attentionLost = "attention-lost"
    case libraryEmpty = "library-empty"
    case libraryMany = "library-many"
    case diagnosticsIdle = "diagnostics-idle"
    case diagnosticsLive = "diagnostics-live"
    case diagnosticsBad = "diagnostics-bad"
    case settingsRoot = "settings-root"
    case settingsCaption = "settings-caption"
    case settingsInterface = "settings-interface"
    case languagesSheet = "languages-sheet"
    case onboarding
    case areaEditor = "area-editor"
    /// Every 2.1.0 kit component on one scrolling page (step 1).
    case kit

    /// The fixture named on the command line, if any.
    static var current: UIFixture? {
        UserDefaults.standard.string(forKey: "uiFixture").flatMap(UIFixture.init(rawValue:))
    }

    /// Where the build 90 interface can show this fixture.
    var baselineTab: AppTab {
        switch self {
        case .idle, .idlePackMissing, .starting, .liveShort, .liveLong, .paused, .attentionLost, .onboarding, .areaEditor, .kit:
            return .translate
        case .libraryEmpty, .libraryMany:
            return .library
        case .diagnosticsIdle, .diagnosticsLive, .diagnosticsBad:
            return .diagnostics
        case .settingsRoot, .settingsCaption, .settingsInterface:
            return .settings
        case .languagesSheet:
            return .translate
        }
    }

    var baselineSheet: AppSheet? {
        switch self {
        case .areaEditor: return .captureArea
        case .languagesSheet: return .languages
        default: return nil
        }
    }

    /// Called once from the root view. Onboarding is driven by the `-onboarded NO` launch argument, not here.
    @MainActor static func apply(router: AppRouter) {
        guard let fixture = current else { return }
        router.go(fixture.baselineTab)
        if let sheet = fixture.baselineSheet { router.present(sheet) }
    }
}

// MARK: - Fake snapshots (no capture is started; the engine is untouched)
extension UIFixture {
    /// Built once per launch so ids and times stay stable between redraws.
    @MainActor static let translateFixture: TranslateSnapshot? = current?.translateSnapshot
    @MainActor static let libraryFixture: [HistoryItem]? = current?.libraryItems

    var libraryItems: [HistoryItem]? {
        switch self {
        case .libraryEmpty: return []
        case .libraryMany:
            let lines = [("Olá, como vai?", "Hello, how are you?"), ("Precisamos sair antes da chuva.", "We need to leave before the rain."),
                         ("Você viu aquilo?", "Did you see that?"), ("A ponte está fechada.", "The bridge is closed."),
                         ("Onde fica a estação?", "Where is the station?")]
            let now = Date()
            return (0..<200).map { i in
                let line = lines[i % lines.count]
                return HistoryItem(original: line.0, translated: line.1, date: now.addingTimeInterval(Double(-i) * 1800),
                                   starred: i % 7 == 0, sourceLanguage: "pt", targetLanguage: "en")
            }
        default: return nil
        }
    }

    var translateSnapshot: TranslateSnapshot? {
        let now = Date()
        let recent = [
            RecentLine(id: UUID(), translated: "Hello, how are you?", original: "Olá, como vai?", date: now.addingTimeInterval(-120)),
            RecentLine(id: UUID(), translated: "We need to leave before the rain.", original: "Precisamos sair antes da chuva.", date: now.addingTimeInterval(-400)),
            RecentLine(id: UUID(), translated: "Did you see that?", original: "Você viu aquilo?", date: now.addingTimeInterval(-900)),
        ]
        var s = TranslateSnapshot(phase: .idle, sourceCode: "pt", targetCode: "en", sourceName: "Portuguese", targetName: "English",
                                  detected: "–", packState: .ready, translated: "", original: "", stage: .reading, held: false,
                                  paused: false, pipActive: false, sessionStarted: nil, modeName: "Low Latency",
                                  recentPairs: ["pt>en", "en>de", "ja>en"], recent: recent)
        switch self {
        case .idle: return s
        case .idlePackMissing:
            s.sourceCode = "ja"; s.sourceName = "Japanese"; s.packState = .needsDownload; s.recent = []
            return s
        case .starting:
            s.phase = .starting; s.sessionStarted = now.addingTimeInterval(-4); s.pipActive = true
            return s
        case .liveShort:
            s.phase = .live; s.sessionStarted = now.addingTimeInterval(-252); s.pipActive = true
            s.translated = "Hello, how are you today?"; s.original = "Olá, como você está hoje?"; s.stage = .showing
            return s
        case .liveLong:
            s.phase = .live; s.sessionStarted = now.addingTimeInterval(-1312); s.pipActive = true; s.held = true
            s.translated = "Wait. If the bridge is closed we have to go around through the old market, and that takes at least two more hours, so tell the others to pack light and meet us at the north gate before sunset."
            s.original = "Espera. Se a ponte estiver fechada, temos de dar a volta pelo mercado antigo."
            s.stage = .translating
            return s
        case .paused:
            s.phase = .paused; s.paused = true; s.sessionStarted = now.addingTimeInterval(-600); s.pipActive = true
            s.translated = "Hello, how are you today?"; s.original = "Olá, como você está hoje?"; s.stage = .showing
            return s
        case .attentionLost:
            s.phase = .attention(.captureLost); s.sessionStarted = now.addingTimeInterval(-75)
            s.translated = "Hello, how are you today?"; s.original = "Olá, como você está hoje?"
            return s
        default: return nil
        }
    }
}

extension UIFixture {
    /// Fills the recorder's in-memory series with sample timings (fixture builds only; nothing is saved).
    @MainActor static func seedDiagnostics(_ d: Diagnostics, bad: Bool) {
        let now = Date()
        func series(_ base: Double, _ spread: Int, step: Int) -> [Sample] {
            (0..<120).map { i in Sample(t: now.addingTimeInterval(Double(i - 120) * 2), v: base + Double((i * step) % spread)) }
        }
        d.ocr = series(bad ? 260 : 105, bad ? 240 : 30, step: 13)
        d.translate = series(bad ? 900 : 42, bad ? 700 : 25, step: 17)
        d.latency = series(bad ? 1300 : 380, bad ? 900 : 160, step: 37)
        d.s.translations = 126
        d.s.failures = bad ? 9 : 0
        if bad {
            d.event(.error, "Translation failed for one caption")
            d.event(.capture, "Capture connection lost")
        }
    }
}

/// Root hook: routes the fixture and, for `kit`, covers the app with the component gallery.
struct FixtureHost: ViewModifier {
    let router: AppRouter
    let engine: TranslatorEngine
    @State private var showKit = UIFixture.current == .kit
    func body(content: Content) -> some View {
        content
            .task {
                if let fixture = UIFixture.current, fixture == .diagnosticsLive || fixture == .diagnosticsBad {
                    UIFixture.seedDiagnostics(engine.diag, bad: fixture == .diagnosticsBad)
                }
                UIFixture.apply(router: router)
            }
            .fullScreenCover(isPresented: $showKit) { KitGallery() }
    }
}
#endif
