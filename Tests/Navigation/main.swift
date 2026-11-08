// Navigation and narrow-observation tests (v2.0.0 build 90, spec §12.10).
// Compiled standalone on the macOS runner with:
//   swiftc -parse-as-library App/DesignSystem/AppRouter.swift App/DesignSystem/ObjectSlice.swift Tests/Navigation/main.swift
import Foundation
import SwiftUI
import Combine

private var failures = 0
private func check(_ ok: Bool, _ what: String) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what)"); failures += 1 }
}

@MainActor
private final class Counter: ObservableObject {
    @Published var value = 0
    @Published var noise = 0
}

@main
struct NavigationTests {
    @MainActor
    static func main() async {
        UserDefaults.standard.removeObject(forKey: "appTab")

        // Tabs: five, stable order, typed. Diagnostics is a tab, not a page inside Settings.
        check(AppTab.allCases == [.live, .library, .languages, .diagnostics, .settings], "five tabs in order Live, Library, Languages, Diagnostics, Settings")
        check(AppTab.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty }, "every tab has a title and symbol")

        let router = AppRouter()
        check(router.tab == .live, "starts on Live")
        router.go(.languages)
        check(router.tab == .languages && router.sheet == nil, "go(.languages) selects the tab")
        check(UserDefaults.standard.string(forKey: "appTab") == "languages", "selected tab is remembered")

        // A sheet opens immediately when none is open.
        router.present(.more)
        check(router.sheet == .more, "present opens a sheet at once")

        // go() closes any open sheet (a sheet can send the user to a tab).
        router.go(.settings)
        check(router.sheet == nil && router.tab == .settings, "go() closes the open sheet")

        // Replacing a sheet closes first, then opens the next one.
        router.present(.status)
        router.present(.reader)
        check(router.sheet == nil, "replacing a sheet closes the old one first")
        try? await Task.sleep(for: .milliseconds(700))
        check(router.sheet == .reader, "the new sheet opens after the old one closed")

        router.dismissSheet()
        check(router.sheet == nil, "dismissSheet closes")

        // Deep links.
        check(router.open(URL(string: "screenlingo://library")!) && router.tab == .library, "deep link opens a tab")
        check(router.open(URL(string: "screenlingo://status")!) && router.tab == .live && router.sheet == .status, "deep link opens a sheet on Live")
        router.dismissSheet()
        check(router.open(URL(string: "screenlingo://diagnostics")!) && router.tab == .diagnostics && router.sheet == nil, "deep link opens the Diagnostics tab")
        check(!router.open(URL(string: "screenlingo://nowhere")!), "unknown deep link is rejected")
        check(!router.open(URL(string: "https://example.com/live")!), "other schemes are rejected")

        // A pending replacement is cancelled by go().
        router.present(.status)
        router.present(.reader)
        router.go(.live)
        try? await Task.sleep(for: .milliseconds(700))
        check(router.sheet == nil, "go() cancels a pending sheet")

        // Narrow observation: a slice publishes only when its own value changes.
        let source = Counter()
        let slice = ObjectSlice(source) { $0.value }
        var publishes = 0
        let bag = slice.objectWillChange.sink { _ in publishes += 1 }
        source.noise += 1
        try? await Task.sleep(for: .milliseconds(500))
        check(publishes == 0 && slice.value == 0, "unrelated change does not redraw the slice")
        source.value = 7
        try? await Task.sleep(for: .milliseconds(500))
        check(slice.value == 7 && publishes == 1, "own change publishes once")
        for i in 8...40 { source.value = i }
        try? await Task.sleep(for: .milliseconds(700))
        check(slice.value == 40 && publishes <= 3, "bursts are coalesced (\(publishes) publishes for 33 changes)")
        bag.cancel()

        // Source check: the old tab switching API is gone.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let files = FileManager.default.enumerator(at: root.appendingPathComponent("App"), includingPropertiesForKeys: nil) {
            var found: [String] = []
            for case let url as URL in files where url.pathExtension == "swift" {
                if let text = try? String(contentsOf: url, encoding: .utf8), text.contains("selectTab") { found.append(url.lastPathComponent) }
            }
            check(found.isEmpty, "no selectTab left in App (\(found))")
        }

        if failures > 0 { print("\(failures) navigation test(s) failed"); exit(1) }
        print("Navigation tests passed")
    }
}
