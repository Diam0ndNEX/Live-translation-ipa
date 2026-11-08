import SwiftUI

/// Shared by Live and settings; indefinite progress never invents a percentage.
/// 2.2.1 (U9): what this card shows, read through EngineSlice so it redraws only when one of these values changes.
/// Before 2.2.1 the card observed the whole engine and redrew on every engine change.
struct ActivityFacts: Equatable {
    var activity = TranslationActivity(title: "", detail: "", phase: .waiting)
    var systemName = ""
    var pendingName = ""
    var warmupProgress = ""
    var languages = TranslationReadiness.Step.pending
    var sessions = TranslationReadiness.Step.pending
    var execution = TranslationReadiness.Step.pending
    var readinessSource = ""
    var readinessTarget = ""
    var completedAt: Date?
    var durationMs: Double?
    var lastCaption: String?
    var conditions = ""
    var selectedPair = ""
    var nonLegacy = false

    @MainActor static func read(_ e: TranslatorEngine) -> ActivityFacts {
        let ready = e.displayedReadiness
        let work = e.modeWorkActivity
        return ActivityFacts(
            activity: e.translationActivity, systemName: e.activeTranslationSystem.shortName,
            pendingName: e.pendingTranslationSystem != e.activeTranslationSystem ? e.pendingTranslationSystem.shortName : "",
            warmupProgress: e.initialWarmupProgress,
            languages: ready.languages, sessions: ready.sessions, execution: ready.execution,
            readinessSource: e.modelReadiness.source, readinessTarget: e.modelReadiness.target,
            completedAt: e.modelReadiness.completedAt, durationMs: e.modelReadiness.durationMs,
            lastCaption: work?.phase == .ready ? work?.title : nil,
            conditions: e.currentRuntimeConditions.isEmpty ? e.translationConditions : e.currentRuntimeConditions,
            selectedPair: "\(e.sourceCode) → \(e.targetCode)", nonLegacy: e.activeTranslationSystem != .legacy)
    }
}

struct TranslationActivityView: View {
    @EngineFacts(ActivityFacts.read) private var facts

    var body: some View {
        let activity = facts.activity
        VStack(alignment: .leading, spacing: 8) {
            Text(facts.systemName).font(.caption).foregroundStyle(.secondary)
            if facts.nonLegacy, !facts.warmupProgress.isEmpty {
                Text(facts.warmupProgress).font(.caption).foregroundStyle(.secondary)
            }
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
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                ReadinessStepView(title: "Languages", step: facts.languages)
                ReadinessStepView(title: "Session", step: facts.sessions)
                ReadinessStepView(title: "Model run", step: facts.execution)
            }
            Text(facts.readinessSource.isEmpty ? "Selected: \(facts.selectedPair)" : "Pair: \(facts.readinessSource) → \(facts.readinessTarget)")
                .font(.caption).foregroundStyle(.secondary)
            if let completed = facts.completedAt, let ms = facts.durationMs {
                TimelineView(.periodic(from: completed, by: 1)) { context in
                    Text("Last successful model request: \(Int(ms)) ms · \(max(0, Int(context.date.timeIntervalSince(completed)))) s ago")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text("Historical response only. A completed request does not prove the model is still loaded.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if facts.nonLegacy {
                Text("No model response recorded for this preparation yet. Session setup alone does not run the model.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let last = facts.lastCaption {
                Text("Last caption: " + last).font(.caption)
            }
            Text(facts.conditions).font(.caption).foregroundStyle(.secondary)
            if !facts.pendingName.isEmpty {
                Text("Next capture: \(facts.pendingName)").font(.caption)
            }
        }.accessibilityElement(children: .combine)
    }
}


struct ReadinessStepView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let step: TranslationReadiness.Step
    private var label: String {
        switch step {
        case .pending: return "Not verified"
        case .working: return "In progress"
        case .complete: return "Verified"
        case .blocked: return "Unavailable"
        case .idle: return title == "Model run" ? "Verified earlier" : "Recheck needed"
        }
    }
    private var color: Color {
        switch step {
        case .complete: return .green
        case .working: return .accentColor
        case .blocked: return .orange
        case .pending, .idle: return .secondary
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
                RoundedRectangle(cornerRadius: 3).fill(color.opacity(step == .pending || step == .idle ? 0.2 : 1)).frame(height: 5)
            }
            HStack(spacing: 4) {
                if step == .working { ProgressView().controlSize(.mini) }
                else { Image(systemName: step == .complete ? "checkmark.circle.fill" : (step == .blocked ? "exclamationmark.circle" : "circle")).foregroundStyle(color) }
                Text(title).font(.caption.weight(.semibold))
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel(title + ": " + label)
    }
}
