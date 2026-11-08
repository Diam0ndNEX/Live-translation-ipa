// ScreenLingo – App – UI kit: shared rules (2.1.0, spec §13.4.1)
import SwiftUI
import UIKit

/// Spacing on a 4 pt grid, page margin 20, gap between groups 24.
enum KitSpace {
    static let unit: CGFloat = 4
    static let tight: CGFloat = 8
    static let row: CGFloat = 12
    static let margin: CGFloat = 20
    static let group: CGFloat = 24
    /// 16 pt, the former large step.
    static let gap: CGFloat = 16
}

/// Corner radii (2.2.1, U11: replaces the old `Radius`).
enum KitRadius {
    static let small: CGFloat = 12, card: CGFloat = 20, large: CGFloat = 28
}

/// The one spring for state changes. Reduce Motion turns it into a short cross-fade.
enum KitMotion {
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static func state(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeInOut(duration: 0.2) : spring }
}

extension PhaseTone {
    /// System semantic colours, so Light, Dark and Increased Contrast all work.
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .accent: return .accentColor
        case .caution: return .orange
        case .failure: return .red
        }
    }
}

/// Hero numerals: 52 pt rounded semibold at the default text size, scaled with Dynamic Type through `@ScaledMetric`.
struct HeroNumber: View {
    let text: String
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 52
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }
}

/// 2.1.8: the tab bar stays put. Shrinking it left a lone round bubble over the content, which looked broken.
struct TabBarMinimize: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.tabBarMinimizeBehavior(.never)
        } else {
            content
        }
    }
}

/// iOS 26: a soft fade under the top bar instead of the hard edge with a hairline. Older systems are unchanged.
struct SoftTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

extension View {
    func softTopEdge() -> some View { modifier(SoftTopEdge()) }
}

/// "ramHit" -> "Ram hit". Raw counter keys never show in the UI.
func humanizedKey(_ raw: String) -> String {
    var out = ""
    for ch in raw {
        if ch.isUppercase, !out.isEmpty { out.append(" ") }
        out.append(ch)
    }
    return out.prefix(1).uppercased() + out.dropFirst().lowercased()
}

// MARK: - Colour roles (2.2.1, U11: replaces the old `Palette`; adaptive for Light, Dark and Increased Contrast)
fileprivate func adaptive(light: UIColor, dark: UIColor) -> Color {
    Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
}
enum KitColor {
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
