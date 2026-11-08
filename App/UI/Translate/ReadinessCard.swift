// ScreenLingo – App – Translate: ReadinessCard (2.1.10)
// The preparation and warm-up status that the old Live tab showed, as one calm card on Translate.
// It reads a value snapshot, so it redraws only when preparation changes.
import SwiftUI

struct ReadinessCard: View {
    let prep: PrepFacts
    let phase: SessionPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tone: Color {
        switch prep.phase {
        case .ready: return .green
        case .attention: return .orange
        case .working: return .accentColor
        case .waiting: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: KitSpace.row) {
            HStack(alignment: .top, spacing: KitSpace.row) {
                lead.frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prep.title).font(.subheadline.weight(.semibold))
                    Text(prep.detail).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if prep.phase == .working, let since = prep.since {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Text("Current step · \(max(0, Int(context.date.timeIntervalSince(since)))) s")
                                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if !prep.warmup.isEmpty {
                Label(prep.warmup, systemImage: "flame")
                    .font(.footnote).foregroundStyle(.secondary)
                    .symbolEffect(.pulse, options: .repeating, isActive: prep.phase == .working && !reduceMotion)
            }
            HStack(spacing: KitSpace.tight) {
                ReadinessStepView(title: "Languages", step: prep.languages)
                ReadinessStepView(title: "Session", step: prep.sessions)
                ReadinessStepView(title: "Model run", step: prep.execution)
            }
            Text(prep.conditions).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .kitSurface()
        .animation(KitMotion.state(reduceMotion), value: prep)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var lead: some View {
        switch prep.phase {
        case .working: ProgressView()
        case .ready: Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(tone)
        case .attention: Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(tone)
        case .waiting: Image(systemName: "moon.zzz.fill").font(.title3).foregroundStyle(tone)
        }
    }
}

/// Soft ripples that leave the Start button while it waits, and a small waveform while live.
struct RippleBackdrop: View {
    var live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if reduceMotion {
            EmptyView()
        } else {
            // 2.2.1 (U12): 15 fps (was 30) and paused while the scene is not active. Battery effect unmeasured.
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: scenePhase != .active)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        let phase = ((t / 3.2) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(Color.accentColor.opacity((1 - phase) * (live ? 0.18 : 0.28)), lineWidth: 2)
                            .scaleEffect(0.5 + phase)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct WaveformBars: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !active || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(Color.accentColor.opacity(active ? 0.9 : 0.35))
                        .frame(width: 4, height: active && !reduceMotion ? 8 + 14 * abs(sin(t * 3 + Double(i) * 0.9)) : 8)
                }
            }
            .frame(height: 24)
        }
        .accessibilityHidden(true)
    }
}
