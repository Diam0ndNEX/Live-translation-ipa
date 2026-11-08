// ScreenLingo – App – Typed navigation (2.1.0, spec §13.3)
import SwiftUI

/// Four tabs (§13.3). Languages is no longer a tab: it is a sheet from the pair on Translate.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case translate, library, diagnostics, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .translate: "Translate"; case .library: "Library"
        case .diagnostics: "Diagnostics"; case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .translate: "captions.bubble.fill"; case .library: "books.vertical.fill"
        case .diagnostics: "waveform.path.ecg"; case .settings: "gearshape.fill"
        }
    }
    /// Tabs remembered by build 90 and older ("live", "languages") open Translate.
    static func restored(_ raw: String?) -> AppTab {
        switch raw {
        case "live", "languages": return .translate
        default: return AppTab(rawValue: raw ?? "") ?? .translate
        }
    }
}

/// Which side of the pair the language sheet edits.
enum LanguageSide: String, Hashable { case source, target }

/// Everything that opens as a sheet. One sheet at a time.
enum AppSheet: String, Identifiable, Hashable {
    case more, status, test, reader, captureArea, testRuns, languages
    var id: String { rawValue }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .translate {
        didSet { if tab != oldValue { UserDefaults.standard.set(tab.rawValue, forKey: "appTab") } }
    }
    @Published var sheet: AppSheet?
    @Published var libraryPath = NavigationPath()
    /// The side the language sheet opens on (the word tapped in the pair title).
    @Published var languageSide: LanguageSide = .target
    private var pendingSheet: Task<Void, Never>?

    init() { tab = AppTab.restored(UserDefaults.standard.string(forKey: "appTab")) }

    /// Switch tab and close any sheet.
    func go(_ tab: AppTab) {
        pendingSheet?.cancel()
        sheet = nil
        self.tab = tab
    }

    /// Open a sheet. If another sheet is open it closes first, so SwiftUI never swaps sheets in one frame.
    func present(_ next: AppSheet) {
        pendingSheet?.cancel()
        guard sheet != nil, sheet != next else { sheet = next; return }
        sheet = nil
        pendingSheet = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.sheet = next
        }
    }

    /// Opens the language sheet on Translate (replaces the old Languages tab).
    func openLanguages(_ side: LanguageSide = .target) {
        go(.translate)
        languageSide = side
        present(.languages)
    }

    /// screenlingo://translate | live | library | languages | diagnostics | settings | more | status | test | reader |
    /// capture-area | text-photos | test-runs. `live` and `languages` are the build 90 links and keep working.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard url.scheme == "screenlingo" else { return false }
        let target = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        if target == "live" || target == "text-photos" { go(.translate); return true }
        if target == "languages" { openLanguages(); return true }
        if let tab = AppTab(rawValue: target) { go(tab); return true }
        let sheets: [String: AppSheet] = ["more": .more, "status": .status, "test": .test, "reader": .reader,
                                          "capture-area": .captureArea,
                                          "test-runs": .testRuns]
        guard let sheet = sheets[target] else { return false }
        if sheet == .more || sheet == .status || sheet == .test { tab = .translate }
        present(sheet)
        return true
    }

    func dismissSheet() { pendingSheet?.cancel(); sheet = nil }
}
