import SwiftUI

/// A setting remains stored under its existing key; moving it between pages
/// never enables, disables, or resets that feature automatically.
private struct ExperimentalOption: View {
    let title: String
    let explanation: String
    @Binding var enabled: Bool
    var available = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(title, isOn: $enabled).disabled(!available)
            Text(explanation)
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }
}

struct ExperimentalFeaturesView: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @AppStorage("incrementalBatchRecovery") private var incrementalBatchRecovery = false
    @AppStorage("directPiPBuffer") private var directPiPBuffer = false
    @AppStorage("subtitleAwareChangeDetection") private var subtitleAwareChangeDetection = false
    @AppStorage("preserveRelatedMovieGroups") private var preserveRelatedMovieGroups = false

    // Previous opt-in Smart pipeline controls are experimental, not core defaults.
    @AppStorage("adaptiveConfirmation") private var adaptiveConfirmation = false
    @AppStorage("confirmationDeadline") private var confirmationDeadline = 0.6
    @AppStorage("continuousRotation") private var continuousRotation = false
    @AppStorage("skipUnchanged") private var skipUnchanged = true

    private var pipelineSignature: String {
        "\(incrementalBatchRecovery)|\(subtitleAwareChangeDetection)|\(preserveRelatedMovieGroups)|\(adaptiveConfirmation)|\(confirmationDeadline)|\(continuousRotation)"
    }

    var body: some View {
        List {
            Section {
                Text("Try features that still need device testing. New experiments start off and your established settings remain unchanged.")
                    .font(.subheadline)
                Text("Test one switch at a time on the same video. Switch it off if subtitles become slower, less complete or less accurate.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink("Translation system") { TranslationSettings() }
                Text("Choose Legacy, Hybrid Recovery or Low Latency in Translation & memory.")
                    .font(.footnote).foregroundStyle(.secondary)
                ExperimentalOption(
                    title: "Incremental translation recovery",
                    explanation: "Retains completed speculative sentence results for exact temporary reuse, even when their batch is interrupted. Never displays incomplete captions.",
                    enabled: $incrementalBatchRecovery)
            } header: { Text("Translation experiments") }

            Section {
                ExperimentalOption(
                    title: "Subtitle-area change detection",
                    explanation: "Samples more of the selected subtitle region to catch small changes. Rotated video uses the standard full-frame detector.",
                    enabled: $subtitleAwareChangeDetection, available: skipUnchanged)
                if !skipUnchanged {
                    Text("First enable Skip unchanged frames in Reading & OCR.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ExperimentalOption(
                    title: "Multiple nearby text groups",
                    explanation: "When active-text focus is enabled, keeps additional nearby aligned lyric or dialogue rows in any preset. May sometimes include unrelated text.",
                    enabled: $preserveRelatedMovieGroups)
            } header: { Text("Recognition & lyrics experiments") }

            Section {
                ExperimentalOption(
                    title: "Direct PiP pixel-buffer rendering",
                    explanation: "Avoids an intermediate image while drawing floating subtitles. Compare appearance and smoothness before keeping it enabled.",
                    enabled: $directPiPBuffer)
            } header: { Text("Rendering experiment") }

            Section {
                ExperimentalOption(
                    title: "Confidence-aware OCR confirmation",
                    explanation: "Confirms exceptionally clear text sooner, and may spend extra reads on uncertain text. Off preserves the fixed stability setting.",
                    enabled: $adaptiveConfirmation)
                VStack(alignment: .leading, spacing: 5) {
                    LabeledContent("Confirmation deadline",
                                   value: String(format: "%.2f s", confirmationDeadline))
                    Slider(value: $confirmationDeadline, in: 0.2...1.2, step: 0.05)
                        .disabled(!adaptiveConfirmation)
                    Text("Caps adaptive confirmation timing; it does not force unreliable words through.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ExperimentalOption(
                    title: "Continuous rotation recalibration",
                    explanation: "Rechecks settled automatic rotation if reading order later appears reversed. May cause additional recalibration.",
                    enabled: $continuousRotation)
            } header: { Text("Existing optional experiments") }

            Section {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Pipeline profiling").font(.subheadline.weight(.medium))
                    Text("Automatically records numeric OCR, model and PiP timing markers for Instruments. No subtitle text is included.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("PiP heartbeat backpressure").font(.subheadline.weight(.medium))
                    Text("Automatically avoids redundant idle frames if the PiP renderer is busy; new subtitles still enqueue immediately.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Automatic optimizations") }

            ResetSection(keys: [
                "incrementalBatchRecovery", "directPiPBuffer",
                "subtitleAwareChangeDetection", "preserveRelatedMovieGroups",
                "adaptiveConfirmation", "confirmationDeadline", "continuousRotation"
            ])
        }
        .settingsPage("Experimental Features")
        .onChange(of: pipelineSignature) { _, _ in engine.pipelineSettingsChanged() }
        .onChange(of: directPiPBuffer) { _, _ in engine.applyStyle() }
    }
}
