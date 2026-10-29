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
            HStack(spacing: 8) {
                ReadinessStepView(title: "Languages", step: engine.modelReadiness.languages)
                ReadinessStepView(title: "Session", step: engine.modelReadiness.sessions)
                ReadinessStepView(title: "Model run", step: engine.modelReadiness.execution)
            }
            Text(engine.modelReadiness.source.isEmpty ? "Selected: \(engine.sourceCode) → \(engine.targetCode)" : "Pair: \(engine.modelReadiness.source) → \(engine.modelReadiness.target)")
                .font(.caption2).foregroundStyle(.secondary)
            if let completed = engine.modelReadiness.completedAt, let ms = engine.modelReadiness.durationMs {
                TimelineView(.periodic(from: completed, by: 1)) { context in
                    Text("Last successful model request: \(Int(ms)) ms · \(max(0, Int(context.date.timeIntervalSince(completed)))) s ago")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text("This records an observed response; iOS may unload the model later.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let work = engine.modeWorkActivity, work.phase == .ready {
                Text("Last caption: " + work.title).font(.caption)
            }
            Text(engine.currentRuntimeConditions.isEmpty ? engine.translationConditions : engine.currentRuntimeConditions).font(.caption2).foregroundStyle(.secondary)
            if engine.pendingTranslationSystem != engine.activeTranslationSystem {
                Text("Next capture: \(engine.pendingTranslationSystem.title)").font(.caption)
            }
        }.accessibilityElement(children: .combine)
    }
}


private struct ReadinessStepView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let step: TranslationReadiness.Step
    private var label: String {
        switch step {
        case .pending: return "Not verified"
        case .working: return "In progress"
        case .complete: return "Verified"
        case .blocked: return "Unavailable"
        }
    }
    private var color: Color {
        switch step {
        case .complete: return .green
        case .working: return .accentColor
        case .blocked: return .orange
        case .pending: return .secondary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if step == .working && !reduceMotion {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(color.opacity(0.15))
                        Capsule().fill(color).frame(width: geometry.size.width * 0.35)
                            .phaseAnimator([false, true]) { band, trailing in
                                band.offset(x: trailing ? geometry.size.width * 0.65 : 0)
                            } animation: { _ in .easeInOut(duration: 0.9) }
                    }.clipped()
                }.frame(height: 5)
            } else {
                RoundedRectangle(cornerRadius: 3).fill(color.opacity(step == .pending ? 0.2 : 1)).frame(height: 5)
            }
            HStack(spacing: 4) {
                if step == .working { ProgressView().controlSize(.mini) }
                else { Image(systemName: step == .complete ? "checkmark.circle.fill" : (step == .blocked ? "exclamationmark.circle" : "circle")).foregroundStyle(color) }
                Text(title).font(.caption2.weight(.semibold))
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel(title + ": " + label)
    }
}
