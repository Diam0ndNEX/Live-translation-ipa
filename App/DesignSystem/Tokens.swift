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

// MARK: - Scales
enum Space {
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
}
enum Radius {
    static let s: CGFloat = 12, m: CGFloat = 20, l: CGFloat = 28
}
enum Motion {
    static let quick = 0.18, standard = 0.3
}

// MARK: - Colour roles (adaptive: light, dark, increased contrast follows the system)
private func adaptive(light: UIColor, dark: UIColor) -> Color {
    Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
}
enum Palette {
    static let background = adaptive(light: UIColor(red: 0.94, green: 0.95, blue: 0.985, alpha: 1), dark: UIColor(red: 0.035, green: 0.043, blue: 0.075, alpha: 1))
    static let surface = adaptive(light: .white, dark: UIColor(red: 0.075, green: 0.09, blue: 0.14, alpha: 1))
    static let surfaceRaised = adaptive(light: UIColor(red: 0.91, green: 0.93, blue: 0.96, alpha: 1), dark: UIColor(red: 0.12, green: 0.14, blue: 0.2, alpha: 1))
    static let cardShadow = adaptive(light: UIColor.black.withAlphaComponent(0.07), dark: UIColor.black.withAlphaComponent(0.35))
    static let separator = adaptive(light: UIColor.black.withAlphaComponent(0.1), dark: UIColor.white.withAlphaComponent(0.12))
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(uiColor: .tertiaryLabel)
    static let success = adaptive(light: UIColor(red: 0.1, green: 0.55, blue: 0.3, alpha: 1), dark: UIColor(red: 0.3, green: 0.85, blue: 0.5, alpha: 1))
    static let warning = adaptive(light: UIColor(red: 0.75, green: 0.42, blue: 0, alpha: 1), dark: UIColor(red: 1, green: 0.7, blue: 0.25, alpha: 1))
    static let danger = adaptive(light: UIColor(red: 0.8, green: 0.15, blue: 0.15, alpha: 1), dark: UIColor(red: 1, green: 0.45, blue: 0.42, alpha: 1))
}
