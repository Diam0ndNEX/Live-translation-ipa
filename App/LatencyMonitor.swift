import SwiftUI

@MainActor
final class LatencyMonitor: ObservableObject {
    @Published var last = LatencyBreakdown()
}

struct LatencyReadout: View {
    @ObservedObject var monitor: LatencyMonitor
    var body: some View {
        HStack(spacing: 12) {
            metric("READ", monitor.last.recognition)
            Spacer(minLength: 0)
            metric("PROCESS", monitor.last.translation)
            Spacer(minLength: 0)
            metric("TOTAL", monitor.last.total)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
    private func metric(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value > 0 ? "\(Int(value))" : "—").font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                Text("ms").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct LatencyDetail: View {
    @ObservedObject var monitor: LatencyMonitor
    var body: some View {
        Section {
            row("OCR recognition", monitor.last.recognition)
            row("Confirmation window", monitor.last.confirmation)
            row("Delivery & filtering", monitor.last.delivery)
            row("Translation queue", monitor.last.queue)
            row("Translation processing", monitor.last.translation)
            row("Readability hold", monitor.last.displayHold)
            row("Frame preparation", monitor.last.rendering)
            row("First sighting → frame enqueue", monitor.last.total)
            LabeledContent("Repeated requests avoided", value: "\(monitor.last.requestsSaved)")
        } header: { Text("Latest translation timing") } footer: {
            Text("Total starts at the first OCR pass for this text and ends when its frame is enqueued. It includes confirmation. Actual display on screen can occur later. Processing includes source detection, cache lookups, model work and assembly.")
        }
    }
    private func row(_ title: String, _ ms: Double) -> some View {
        LabeledContent(title, value: "\(Int(ms)) ms")
    }
}

struct PairedTimingCard: View {
    let samples: [PipelineMeasurement]
    private func average(_ key: KeyPath<LatencyBreakdown, Double>) -> Double {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0) { $0 + $1.stages[keyPath: key] } / Double(samples.count)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Measured stages · same displayed outputs").font(.subheadline.bold())
            if samples.isEmpty {
                Text("Waiting for a v1.0 translation timing sample.").font(.footnote).foregroundStyle(.secondary)
            } else {
                stage("OCR confirmation window", average(\.confirmation))
                stage("Final OCR pass", average(\.recognition))
                stage("Delivery & filtering", average(\.delivery))
                stage("Translation queue", average(\.queue))
                stage("Translation processing", average(\.translation))
                stage("Readability hold", average(\.displayHold))
                stage("Frame preparation", average(\.rendering))
                Divider()
                stage("Total to frame enqueue", average(\.total))
                Text("Averages use \(samples.count) matched displayed results. Confirmation includes earlier OCR passes and spacing between them. Translation-ahead can overlap confirmation. This replaces the old residual ‘Waiting & display’ estimate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.card()
    }
    private func stage(_ title: String, _ value: Double) -> some View {
        HStack { Text(title); Spacer(); Text("\(Int(value)) ms").monospacedDigit() }.font(.footnote)
    }
}

