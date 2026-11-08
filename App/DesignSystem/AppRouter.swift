// ScreenLingo – App – Typed navigation (2.0.0 build 90)
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case live, library, languages, diagnostics, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: "Live"; case .library: "Library"; case .languages: "Languages"
        case .diagnostics: "Diagnostics"; case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .live: "captions.bubble.fill"; case .library: "books.vertical.fill"; case .languages: "globe"
        case .diagnostics: "waveform.path.ecg"; case .settings: "gearshape.fill"
        }
    }
}

/// Everything that opens as a sheet. One sheet at a time.
enum AppSheet: String, Identifiable, Hashable {
    case more, status, test, reader, captureArea, workspace, testRuns
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

    /// screenlingo://live | library | languages | diagnostics | settings | more | status | test | reader | capture-area | text-photos | test-runs
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard url.scheme == "screenlingo" else { return false }
        let target = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        if let tab = AppTab(rawValue: target) { go(tab); return true }
        let sheets: [String: AppSheet] = ["more": .more, "status": .status, "test": .test, "reader": .reader,
                                          "capture-area": .captureArea, "text-photos": .workspace,
                                          "test-runs": .testRuns]
        guard let sheet = sheets[target] else { return false }
        if sheet == .more || sheet == .status || sheet == .test { tab = .live }
        present(sheet)
        return true
    }

    func dismissSheet() { pendingSheet?.cancel(); sheet = nil }
}
