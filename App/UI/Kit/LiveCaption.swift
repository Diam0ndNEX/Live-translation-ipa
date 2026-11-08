// ScreenLingo – App – UI kit: LiveCaption (2.1.0, spec §13.4.3)
import SwiftUI

/// Where a caption is in the pipeline, shown as a three-step trail.
enum CaptionStage: Int, CaseIterable, Equatable {
    case reading, translating, showing
    var title: String {
        switch self { case .reading: return "Reading"; case .translating: return "Translating"; case .showing: return "Showing" }
    }
}

/// The translation as large auto-fit text (up to 6 lines), the original below in secondary colour,
/// the Reading · Translating · Showing trail, and a held (pinned) state.
struct LiveCaption: View {
    let translated: String
    var original: String = ""
    var showOriginal: Bool = true
    var stage: CaptionStage = .showing
    var held: Bool = false
    /// Placeholder while nothing has been translated yet.
    var placeholder: String = "Waiting for text on screen"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var captionSize: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: KitSpace.row) {
            HStack(alignment: .firstTextBaseline, spacing: KitSpace.tight) {
                if held {
                    Image(systemName: "pin.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Held")
                }
                Text(translated.isEmpty ? placeholder : translated)
                    .font(.system(size: captionSize, weight: .semibold))
                    .minimumScaleFactor(0.7)   // 40 pt down to 28 pt, then lines wrap
                    .lineLimit(6)
                    .foregroundStyle(translated.isEmpty ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(reduceMotion ? .identity : .opacity)
                    .animation(KitMotion.state(reduceMotion), value: translated)
                    .textSelection(.enabled)
            }
            if showOriginal, !original.isEmpty {
                Text(original)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .accessibilityLabel("Original: \(original)")
            }
            StageTrail(stage: stage)
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

private struct StageTrail: View {
    let stage: CaptionStage
    var body: some View {
        HStack(spacing: KitSpace.row) {
            ForEach(CaptionStage.allCases, id: \.self) { step in
                HStack(spacing: KitSpace.unit) {
                    Image(systemName: step == stage ? "circle.fill" : "circle")
                        .font(.footnote)
                        .foregroundStyle(step == stage ? Color.accentColor : Color.secondary)
                    Text(step.title)
                        .font(.footnote)
                        .foregroundStyle(step == stage ? Color.primary : Color.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step: \(stage.title)")
    }
}
