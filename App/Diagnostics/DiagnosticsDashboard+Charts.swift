import SwiftUI
import Charts

// MARK: - Small helpers
func fmt(_ v: Double) -> String { v >= 100 ? "\(Int(v))" : String(format: "%.1f", v) }

func level(_ v: Double, _ n: Int, _ warn: Double, _ bad: Double) -> Color {
    n == 0 ? Color.primary : (v > bad ? Color.red : (v > warn ? Color.orange : Color.green))
}

struct BarRow: Identifiable {
    let name: String
    let value: Int
    var id: String { name }
}

struct DonutPart: Identifiable {
    let name: String
    let value: Int
    let color: Color
    var id: String { name }
}

struct Bucket: Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
}

// MARK: - Building blocks
/// One labelled value per row (replaces the 2.0.0 tile grid).
struct StatTile: View {
    let title: String
    let value: String
    var tint: Color = Color.primary
    var icon: String? = nil
    var body: some View {
        HStack(spacing: KitSpace.row) {
            if let icon { Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24).accessibilityHidden(true) }
            Text(title).font(.body)
            Spacer(minLength: KitSpace.tight)
            Text(value).font(.body.monospacedDigit()).foregroundStyle(tint == Color.primary ? Color.secondary : tint)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

struct LineCard: View {
    let title: String
    let samples: [Sample]
    var color: Color = Color.cyan
    var unit = "ms"
    var rule: Double? = nil
    var markers: [TimelineEvent] = []

    private func stat(_ n: String, _ v: Double) -> some View {
        VStack(spacing: 1) {
            Text(fmt(v)).font(.caption.weight(.semibold).monospacedDigit())
            Text(n).font(.caption).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        let sm = Diagnostics.summarize(samples)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if sm.n > 0 {
                    Text("\(fmt(sm.last)) \(unit)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(color)
                }
            }
            if samples.count < 2 {
                Text(samples.isEmpty
                     ? "No measurements in this range. Detailed collection records measured work, not synthetic values."
                     : "One measurement: \(fmt(sm.last)) \(unit). Another sample is needed for a trend.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                Chart {
                    ForEach(samples) { s in
                        AreaMark(x: .value("Time", s.t), y: .value(unit, s.v))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", s.t), y: .value(unit, s.v))
                            .foregroundStyle(color)
                            .interpolationMethod(.monotone)
                    }
                    if let r = rule {
                        RuleMark(y: .value("Limit", r))
                            .foregroundStyle(Color.red.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    ForEach(markers) { e in
                        RuleMark(x: .value("Event", e.time))
                            .foregroundStyle(e.kind.color.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.minute().second())
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .animation(.smooth(duration: 0.35), value: samples.count)
                .frame(height: 110)
                HStack {
                    stat("min", sm.min)
                    Spacer()
                    stat("avg", sm.avg)
                    Spacer()
                    stat("p95", sm.p95)
                    Spacer()
                    stat("max", sm.max)
                }
            }
        }
        .kitSurface()
    }
}

struct HistogramCard: View {
    let title: String
    let values: [Double]
    var color: Color = Color.cyan

    private struct Bin: Identifiable {
        let label: String
        let count: Int
        let order: Int
        var id: Int { order }
    }

    private var bins: [Bin] {
        guard values.count >= 3, let mx = values.max(), mx > 0 else { return [] }
        let n = 8
        let w = mx / Double(n)
        var counts = [Int](repeating: 0, count: n)
        for v in values { counts[Swift.min(n - 1, Int(v / w))] += 1 }
        return (0..<n).map { Bin(label: "\(Int(Double($0) * w))", count: counts[$0], order: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if bins.isEmpty {
                Text(values.isEmpty ? "No timing measurements in this range." :
                     "\(values.count) timing samples; at least three are needed for a histogram.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                Chart(bins) { b in
                    BarMark(x: .value("Range (ms)", b.label), y: .value("Count", b.count))
                        .foregroundStyle(color.gradient)
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 120)
            }
        }
        .kitSurface()
    }
}

struct DonutCard: View {
    let title: String
    let parts: [DonutPart]
    var body: some View {
        let shown = parts.filter { $0.value > 0 }
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if shown.isEmpty {
                Text("No data yet.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart(shown) { p in
                    SectorMark(angle: .value("Count", p.value), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(by: .value("Part", p.name))
                }
                .chartForegroundStyleScale(domain: shown.map { $0.name }, range: shown.map { $0.color })
                .chartLegend(position: .bottom, alignment: .center, spacing: 8)
                .frame(height: 210)
            }
        }
        .kitSurface()
    }
}

struct BarListCard: View {
    let title: String
    let rows: [BarRow]
    var color: Color = Color.blue
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if rows.allSatisfy({ $0.value == 0 }) {
                Text("No data yet.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Chart(rows) { r in
                    BarMark(x: .value("Count", r.value), y: .value("Item", r.name))
                        .foregroundStyle(color.gradient)
                        .annotation(position: .trailing) {
                            Text("\(r.value)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                }
                .chartYScale(domain: rows.map { $0.name })
                .frame(height: CGFloat(rows.count) * 34 + 20)
            }
        }
        .kitSurface()
    }
}

struct MultiSpeedChart: View {
    let ocr: [Sample]
    let translate: [Sample]
    let delay: [Sample]
    var body: some View {
        if ocr.count + translate.count + delay.count < 3 {
            Text("Not enough measured timing samples. Memory-only translations do not have model-duration samples.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            Chart {
                ForEach(ocr) { s in
                    LineMark(x: .value("Time", s.t), y: .value("ms", s.v), series: .value("Step", "Reading"))
                        .foregroundStyle(by: .value("Step", "Reading"))
                        .interpolationMethod(.monotone)
                }
                ForEach(translate) { s in
                    LineMark(x: .value("Time", s.t), y: .value("ms", s.v), series: .value("Step", "Translating"))
                        .foregroundStyle(by: .value("Step", "Translating"))
                        .interpolationMethod(.monotone)
                }
                ForEach(delay) { s in
                    LineMark(x: .value("Time", s.t), y: .value("ms", s.v), series: .value("Step", "Total delay"))
                        .foregroundStyle(by: .value("Step", "Total delay"))
                        .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["Reading": Color.green, "Translating": Color.cyan, "Total delay": Color.orange])
            .chartLegend(position: .bottom)
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.minute().second())
                }
            }
            .frame(height: 160)
        }
    }
}
