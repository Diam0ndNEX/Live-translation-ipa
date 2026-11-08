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
            return .live
        case .libraryEmpty, .libraryMany:
            return .library
        case .diagnosticsIdle, .diagnosticsLive, .diagnosticsBad:
            return .diagnostics
        case .settingsRoot, .settingsCaption:
            return .settings
        case .languagesSheet:
            return .languages
        }
    }

    var baselineSheet: AppSheet? {
        self == .areaEditor ? .captureArea : nil
    }

    /// Called once from the root view. Onboarding is driven by the `-onboarded NO` launch argument, not here.
    @MainActor static func apply(router: AppRouter) {
        guard let fixture = current else { return }
        router.go(fixture.baselineTab)
        if let sheet = fixture.baselineSheet { router.present(sheet) }
    }
}

/// Root hook: routes the fixture and, for `kit`, covers the app with the component gallery.
struct FixtureHost: ViewModifier {
    let router: AppRouter
    @State private var showKit = UIFixture.current == .kit
    func body(content: Content) -> some View {
        content
            .task { UIFixture.apply(router: router) }
            .fullScreenCover(isPresented: $showKit) { KitGallery() }
    }
}
#endif
