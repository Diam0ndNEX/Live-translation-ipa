// ScreenLingo – App – Design system tokens (2.1.0)
import SwiftUI
import UIKit

// MARK: - Accent and appearance (stored under the existing "accent" key; "appearance" is new, default System)
enum AccentChoice: String, CaseIterable, Identifiable {
    case blue, purple, teal, orange, pink, green
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var start: Color {
        switch self {
        case .blue: Color(red: 0.25, green: 0.52, blue: 1)
        case .purple: Color(red: 0.55, green: 0.38, blue: 0.95)
        case .teal: Color(red: 0.1, green: 0.7, blue: 0.82)
        case .orange: Color(red: 1, green: 0.6, blue: 0.2)
        case .pink: Color(red: 0.95, green: 0.38, blue: 0.62)
        case .green: Color(red: 0.2, green: 0.75, blue: 0.45)
        }
    }
    var end: Color {
        switch self {
        case .blue: Color(red: 0.45, green: 0.42, blue: 0.98)
        case .purple: Color(red: 0.85, green: 0.38, blue: 0.9)
        case .teal: Color(red: 0.2, green: 0.5, blue: 0.95)
        case .orange: Color(red: 0.95, green: 0.3, blue: 0.4)
        case .pink: Color(red: 0.7, green: 0.3, blue: 0.95)
        case .green: Color(red: 0.1, green: 0.6, blue: 0.75)
        }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self { case .system: nil; case .dark: .dark; case .light: .light }
    }
}

/// One observable source for accent and appearance. It follows UserDefaults, so the Settings pickers
/// (which write the same keys) update every screen at once. It only publishes when a value really changes.
@MainActor
final class ThemeStore: ObservableObject {
    static let accentKey = "accent"
    static let appearanceKey = "appearance"
    @Published private(set) var accent: AccentChoice
    @Published private(set) var appearance: Appearance
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accent = AccentChoice(rawValue: defaults.string(forKey: Self.accentKey) ?? "") ?? .blue
        appearance = Appearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func reload() {
        let a = AccentChoice(rawValue: defaults.string(forKey: Self.accentKey) ?? "") ?? .blue
        let p = Appearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        if a != accent { accent = a }
        if p != appearance { appearance = p }
    }
    var tint: Color { accent.start }
    var gradient: LinearGradient { LinearGradient(colors: [accent.start, accent.end], startPoint: .leading, endPoint: .trailing) }
}

// MARK: - Motion
// 2.2.1 (U11): spacing, radii and colour roles now live in App/UI/Kit/KitStyle.swift (KitSpace, KitRadius, KitColor).
enum Motion {
    static let quick = 0.18, standard = 0.3
}
