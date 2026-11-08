// ScreenLingo – App – UI kit: shared rules (2.1.0, spec §13.4.1)
import SwiftUI

/// Spacing on a 4 pt grid, page margin 20, gap between groups 24.
enum KitSpace {
    static let unit: CGFloat = 4
    static let tight: CGFloat = 8
    static let row: CGFloat = 12
    static let margin: CGFloat = 20
    static let group: CGFloat = 24
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
