// ScreenLingo – App – Typed navigation (2.0.0 build 85)
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case live, library, languages, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .live: "Live"; case .library: "Library"; case .languages: "Languages"; case .settings: "Settings" }
    }
    var symbol: String {
        switch self { case .live: "captions.bubble.fill"; case .library: "books.vertical.fill"; case .languages: "globe"; case .settings: "gearshape.fill" }
    }
}

/// Everything that opens as a sheet. One sheet at a time.
enum AppSheet: String, Identifiable, Hashable {
    case more, status, test, reader, captureArea, workspace, diagnostics, testRuns
    var id: String { rawValue }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .live {
        didSet { if tab != oldValue { UserDefaults.standard.set(tab.rawValue, forKey: "appTab") } }
    }
    @Published var sheet: AppSheet?
    @Published var libraryPath = NavigationPath()
    private var pendingSheet: Task<Void, Never>?

    init() { tab = AppTab(rawValue: UserDefaults.standard.string(forKey: "appTab") ?? "") ?? .live }

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

    func dismissSheet() { pendingSheet?.cancel(); sheet = nil }
}
