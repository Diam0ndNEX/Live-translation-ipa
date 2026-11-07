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
            Toggle(title, isOn: $enabled).disabled(!available).frame(minHeight: 44)
            Hint(explanation)
        }
        .padding(.vertical, 3)
    }
}

struct ExperimentalFeaturesView: View {
    @EngineHandle private var engine
    @AppStorage("incrementalBatchRecovery") private var incrementalBatchRecovery = false
    @AppStorage("directPiPBuffer") private var directPiPBuffer = false
    @AppStorage("hybridSwitchGuard") private var hybridSwitchGuard = true
    @AppStorage("pixelConfirmation") private var pixelConfirmation = true
    @AppStorage("eventDrivenOCR") private var eventDrivenOCR = true
    @AppStorage("fastOCR") private var fastOCR = false
    @AppStorage("legacySharedSession") private var legacySharedSession = true
    @AppStorage("subtitleAwareChangeDetection") private var subtitleAwareChangeDetection = false
    @AppStorage("preserveRelatedMovieGroups") private var preserveRelatedMovieGroups = false

    // Previous opt-in Smart pipeline controls are experimental, not core defaults.
    @AppStorage("adaptiveConfirmation") private var adaptiveConfirmation = false
    @AppStorage("confirmationDeadline") private var confirmationDeadline = 0.6
    @AppStorage("continuousRotation") private var continuousRotation = false
    @AppStorage("skipUnchanged") private var skipUnchanged = true

    private var pipelineSignature: String {
        "\(incrementalBatchRecovery)|\(pixelConfirmation)|\(eventDrivenOCR)|\(fastOCR)|\(subtitleAwareChangeDetection)|\(preserveRelatedMovieGroups)|\(adaptiveConfirmation)|\(confirmationDeadline)|\(continuousRotation)"
    }

    var body: some View {
        List {
            SettingsPageHeader(symbol: "flask", title: "Experimental Features", summary: "Switches for ideas that are not proven yet.")
            Section {
                Text("Optional features that are still being tested. New ones start switched off and your normal settings are never changed for you.")
                    .font(.subheadline)
                Text("Try one switch at a time on the same video. Switch it off again if captions get slower, less complete or less accurate.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink("Translation system") { TranslationSettings() }
                Text("Pick Legacy, Hybrid or Low Latency in Translation & memory, or on the Live tab.")
                    .font(.footnote).foregroundStyle(.secondary)
                ExperimentalOption(
                    title: "Incremental translation recovery",
                    explanation: "Keeps sentences that were already translated ahead of time, even if the rest of the batch was interrupted, so they can be reused. Never shows an unfinished caption.",
                    enabled: $incrementalBatchRecovery)
                ExperimentalOption(
                    title: "Hybrid model switch guard",
                    explanation: "On (default): Hybrid avoids starting a second translation model while the first is busy or just finished. Turn off to compare with the older 1.9.9 behavior on the same video. Applies from the next subtitle.",
                    enabled: $hybridSwitchGuard)
                ExperimentalOption(
                    title: "Legacy shared session",
                    explanation: "On (default): Legacy reuses its already warmed-up translation session when it is free. Off: uses separate sessions like 1.9.9.",
                    enabled: $legacySharedSession)
            } header: { Text("Translation experiments") }

            Section {
                ExperimentalOption(
                    title: "Pixel-verified confirmation",
                    explanation: "On (default): a subtitle counts as confirmed when its pixels stay the same for the normal waiting time, instead of reading it a second time. Any change falls back to reading again. Off: two reads, like 1.9.9.",
                    enabled: $pixelConfirmation)
                ExperimentalOption(
                    title: "Event-driven OCR",
                    explanation: "On (default): while the shown subtitle does not change, reading pauses (it still checks at least every 0.55 s) and restarts the moment it changes. Fewer reads and less heat. Off: reads at a fixed rhythm.",
                    enabled: $eventDrivenOCR)
                ExperimentalOption(
                    title: "Fast OCR",
                    explanation: "Reads text faster but without spelling correction. It may miss accents or non-Latin text. Compare on the same video before keeping it.",
                    enabled: $fastOCR)
            } header: { Text("Text reading") }

            Section {
                ExperimentalOption(
                    title: "Subtitle-area change detection",
                    explanation: "Looks at more of the chosen subtitle area to notice small changes. Rotated video uses the normal whole-screen check.",
                    enabled: $subtitleAwareChangeDetection, available: skipUnchanged)
                if !skipUnchanged {
                    Text("Turn on Skip unchanged frames in Reading & OCR first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ExperimentalOption(
                    title: "Multiple nearby text groups",
                    explanation: "Keeps extra nearby lines of lyrics or dialogue together. It may sometimes include text that does not belong.",
                    enabled: $preserveRelatedMovieGroups)
            } header: { Text("Lyrics and dialogue") }

            Section {
                ExperimentalOption(
                    title: "Direct PiP pixel-buffer rendering",
                    explanation: "Draws the floating captions directly instead of through an extra image. Check how it looks and moves before keeping it on.",
                    enabled: $directPiPBuffer)
            } header: { Text("Floating window") }

            Section {
                ExperimentalOption(
                    title: "Confidence-aware OCR confirmation",
                    explanation: "Confirms very clear text sooner and may read unclear text more times. Off keeps the fixed stability setting.",
                    enabled: $adaptiveConfirmation)
                VStack(alignment: .leading, spacing: 5) {
                    LabeledContent("Confirmation deadline",
                                   value: String(format: "%.2f s", confirmationDeadline))
                    Slider(value: $confirmationDeadline, in: 0.2...1.2, step: 0.05)
                        .disabled(!adaptiveConfirmation)
                    Text("Sets the longest wait. It never lets unreliable words through.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ExperimentalOption(
                    title: "Continuous rotation recalibration",
                    explanation: "Checks the detected screen rotation again if the reading order later looks reversed. May cause extra re-checks.",
                    enabled: $continuousRotation)
            } header: { Text("Older optional experiments") }

            Section {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Pipeline profiling").font(.subheadline.weight(.medium))
                    Text("Always on: records timing numbers for Xcode Instruments. No caption text is included.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("PiP heartbeat backpressure").font(.subheadline.weight(.medium))
                    Text("Always on: skips needless idle frames when the floating window is busy. New captions still appear at once.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Always on") }

            ResetSection(keys: [
                "incrementalBatchRecovery", "directPiPBuffer", "hybridSwitchGuard",
                "pixelConfirmation", "eventDrivenOCR", "fastOCR", "legacySharedSession",
                "subtitleAwareChangeDetection", "preserveRelatedMovieGroups",
                "adaptiveConfirmation", "confirmationDeadline", "continuousRotation"
            ])
        }
        .settingsPage("Experimental Features")
        .onChange(of: pipelineSignature) { _, _ in engine.pipelineSettingsChanged() }
        .onChange(of: directPiPBuffer) { _, _ in engine.applyStyle() }
    }
}
