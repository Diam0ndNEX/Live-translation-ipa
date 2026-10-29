import SwiftUI

/// Shared by Live and settings; indefinite progress never invents a percentage.
struct TranslationActivityView: View {
    @EnvironmentObject private var engine: TranslatorEngine

    var body: some View {
        let activity = engine.translationActivity
        VStack(alignment: .leading, spacing: 8) {
            Text(engine.activeTranslationSystem.title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                if activity.phase == .working {
                    ProgressView().controlSize(.small).accessibilityLabel("Translation work in progress")
                } else {
                    Image(systemName: activity.phase == .ready ? "checkmark.circle.fill" : (activity.phase == .attention ? "exclamationmark.triangle.fill" : "clock"))
                        .foregroundStyle(activity.phase == .ready ? Color.green : Color.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(activity.title).font(.subheadline.weight(.semibold))
                    Text(activity.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if activity.phase == .working, let since = activity.since {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Text("Current step · \(max(0, Int(context.date.timeIntervalSince(since)))) s")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if engine.activeTranslationSystem != .legacy, !engine.modeAvailability.isEmpty {
                Text(engine.modeAvailability).font(.caption2).foregroundStyle(.secondary)
            }
            if engine.pendingTranslationSystem != engine.activeTranslationSystem {
                Text("Next capture: \(engine.pendingTranslationSystem.title)").font(.caption)
            }
        }.accessibilityElement(children: .combine)
    }
}
