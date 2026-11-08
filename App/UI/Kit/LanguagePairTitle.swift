// ScreenLingo – App – UI kit: LanguagePairTitle (2.1.0, spec §13.4.3)
import SwiftUI

/// The language pair as the screen's title: two tappable words with the swap glyph between them.
/// Position maps to effect (left word = from, right word = into); the glyph turns on swap as feedback.
struct LanguagePairTitle: View {
    let source: String
    let target: String
    /// Pack line under the title, e.g. "Works offline" with a checkmark.
    var status: String
    var statusSymbol: String
    var statusTone: PhaseTone = .neutral
    /// False when swapping makes no sense (auto-detect as source).
    var canSwap: Bool = true
    var onSource: () -> Void
    var onTarget: () -> Void
    var onSwap: () -> Void

    @State private var turns = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: KitSpace.unit) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: KitSpace.tight) { words }
                VStack(alignment: .leading, spacing: 2) { words }
            }
            .font(.largeTitle.bold())
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
            Label(status, systemImage: statusSymbol)
                .font(.subheadline)
                .foregroundStyle(statusTone == .neutral ? Color.secondary : statusTone.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var words: some View {
        Button(action: onSource) { Text(source).lineLimit(1).minimumScaleFactor(0.7) }
            .accessibilityLabel("Translate from \(source)")
            .accessibilityHint("Choose the language to translate from")
        Button {
            withAnimation(KitMotion.state(reduceMotion)) { turns += 180 }
            onSwap()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.title2.weight(.semibold))
                .rotationEffect(.degrees(reduceMotion ? 0 : turns))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(!canSwap)
        .opacity(canSwap ? 1 : 0.35)
        .accessibilityLabel("Swap languages")
        .sensoryFeedback(.selection, trigger: turns)
        Button(action: onTarget) { Text(target).lineLimit(1).minimumScaleFactor(0.7) }
            .accessibilityLabel("Translate into \(target)")
            .accessibilityHint("Choose the language to translate into")
    }
}
