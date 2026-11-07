// ScreenLingo – App – Basic / Advanced split for Settings (2.0.0 build 86)
import SwiftUI

/// One switch for the whole Settings area. Basic options are always visible; Advanced sections appear when it is on.
/// Hidden options keep their values. The key lives here so no Settings page owns it twice.
@MainActor
final class AdvancedMode: ObservableObject {
    static let key = "showAdvancedSettings"
    @Published var on: Bool {
        didSet { UserDefaults.standard.set(on, forKey: Self.key) }
    }
    init() { on = UserDefaults.standard.bool(forKey: Self.key) }
}

/// A Settings section that only shows in Advanced mode.
struct AdvancedSection<Content: View>: View {
    @EnvironmentObject private var mode: AdvancedMode
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        if mode.on {
            Section {
                content()
            } header: { Text("Advanced · \(title)") } footer: {
                if let footer { Text(footer) }
            }
        }
    }
}

/// The same Advanced gate for screens built from cards in a ScrollView (AdvancedSection is for Lists).
struct AdvancedBlock<Content: View>: View {
    @EnvironmentObject private var mode: AdvancedMode
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        if mode.on {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader(title: "Advanced · \(title)", detail: footer)
                content()
            }
        } else {
            Banner(text: "More detail about \(title.lowercased()) is hidden.", severity: .info,
                   actionTitle: "Show advanced details") { mode.on = true }
        }
    }
}

/// Short explanation under a control, in plain language.
struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Last row of every page: switch Advanced options on or off.
struct AdvancedSwitchSection: View {
    @EnvironmentObject private var mode: AdvancedMode
    var body: some View {
        Section {
            Toggle("Show advanced options", isOn: $mode.on).frame(minHeight: 44)
        } footer: {
            Text(mode.on ? "Advanced options use technical terms. The defaults are safe to leave alone."
                         : "More options are hidden. Turn this on to see technical settings for this page.")
        }
    }
}
