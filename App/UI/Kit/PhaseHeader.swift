// ScreenLingo – App – UI kit: PhaseHeader (2.1.0, spec §13.4.3)
import SwiftUI

/// Glyph + word + timer + mode, e.g. "● Live · 04:12 · Low Latency". Replaces every status pill.
struct PhaseHeader: View {
    let phase: SessionPhase
    var elapsed: TimeInterval? = nil
    var mode: String? = nil
    var action: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: KitSpace.tight) {
                Image(systemName: phase.symbol)
                    .foregroundStyle(phase.tone.color)
                    .symbolEffect(.pulse, options: .repeating, isActive: phase == .live && !reduceMotion)
                    .accessibilityHidden(true)
                Text(line)
                    .font(.headline)
                    .foregroundStyle(phase.tone == .neutral ? Color.primary : phase.tone.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(action == nil ? "" : "Opens session details")
    }

    private var line: String {
        var parts = [phase.word]
        if let elapsed, phase.isSession { parts.append(Self.clock(elapsed)) }
        if let mode, !mode.isEmpty { parts.append(mode) }
        return parts.joined(separator: " · ")
    }
    private var accessibilityText: String {
        var parts = [phase.word]
        if let elapsed, phase.isSession { parts.append("for " + Self.spoken(elapsed)) }
        if let mode, !mode.isEmpty { parts.append(mode) }
        return parts.joined(separator: ", ")
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
    static func spoken(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = [.hour, .minute, .second]
        return f.string(from: max(0, t)) ?? ""
    }
}
