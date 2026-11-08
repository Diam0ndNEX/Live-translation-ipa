// ScreenLingo – App – UI kit: StatLine (2.1.0, spec §13.4.3)
import SwiftUI
import Charts

/// One hero number with its caption and a sparkline, then one row of two or three secondary values.
/// Replaces tile grids. With no evidence it shows a dash and says so, never a coloured score (R7).
struct StatLine: View {
    /// Hero value already formatted ("412 ms"), or nil when there is no data yet.
    let value: String?
    let caption: String
    var samples: [Double] = []
    var secondary: [String] = []
    var emptyCaption: String = "No data yet"

    var body: some View {
        VStack(alignment: .leading, spacing: KitSpace.tight) {
            HeroNumber(text: value ?? "–")
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
            Text(value == nil ? emptyCaption : caption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if samples.count > 1 {
                Chart(Array(samples.enumerated()), id: \.offset) { point in
                    LineMark(x: .value("Sample", point.offset), y: .value("Value", point.element))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.accentColor)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 36)
                .accessibilityLabel("Trend of the last \(samples.count) samples")
            }
            if !secondary.isEmpty {
                Text(secondary.joined(separator: "  ·  "))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
