import SwiftUI

/// Advanced controls live together so experiments can be tested independently
/// without changing the everyday recognition, translation, or PiP defaults.
private struct ExperimentalOption: View {
    let title: String
    let explanation: String
    @Binding var enabled: Bool
    var available = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: $enabled)
                .disabled(!available)
            Text(explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }
}

struct ExperimentalFeaturesView: View {
    @EnvironmentObject private var engine: TranslatorEngine

    // New v1.5.0 experiments. All default to OFF.
    @AppStorage("lowLatencyTranslation") private var lowLatencyTranslation = false
    @AppStorage("incrementalBatchRecovery") private var incrementalBatchRecovery = false
    @AppStorage("directPiPBuffer") private var directPiPBuffer = false
    @AppStorage("subtitleAwareChangeDetection") private var subtitleAwareChangeDetection = false
    @AppStorage("preserveRelatedMovieGroups") private var preserveRelatedMovieGroups = false

    // Existing Smart pipeline controls. Preserve existing AppStorage keys/defaults.
    @AppStorage("adaptiveOCR") private var adaptiveOCR = true
    @AppStorage("adaptiveConfirmation") private var adaptiveConfirmation = false
    @AppStorage("subtitleTracking") private var subtitleTracking = true
    @AppStorage("deduplicateCopies") private var deduplicateCopies = true
    @AppStorage("selectiveSpeculation") private var selectiveSpeculation = true
    @AppStorage("adaptiveSpeculation") private var adaptiveSpeculation = true
    @AppStorage("speculationConfidence") private var speculationConfidence = 0.85
    @AppStorage("confirmationDeadline") private var confirmationDeadline = 0.6
    @AppStorage("steadyCaptions") private var steadyCaptions = true
    @AppStorage("protectConfirmedPresentation") private var protectConfirmedPresentation = true
    @AppStorage("smartCool") private var smartCool = true
    @AppStorage("contextualLanguage") private var contextualLanguage = true
    @AppStorage("continuousRotation") private var continuousRotation = false
    @AppStorage("languageRecovery") private var languageRecovery = true

    // Existing options better located with experiments / controlled comparisons.
    @AppStorage("predictiveWarmup") private var predictiveWarmup = true
    @AppStorage("freshTranslationTest") private var freshTranslationTest = false

    // Prerequisites still live in their ordinary settings pages.
    @AppStorage("skipUnchanged") private var skipUnchanged = true
    @AppStorage("mode") private var mode = TranslateMode.movie.rawValue

    private var pipelineSignature: String {
        [
            String(adaptiveOCR), String(adaptiveConfirmation), String(subtitleTracking),
            String(deduplicateCopies), String(selectiveSpeculation),
            String(adaptiveSpeculation), String(speculationConfidence),
            String(confirmationDeadline), String(steadyCaptions),
            String(protectConfirmedPresentation), String(smartCool),
            String(contextualLanguage), String(continuousRotation),
            String(languageRecovery), String(predictiveWarmup),
            String(freshTranslationTest), String(incrementalBatchRecovery),
            String(subtitleAwareChangeDetection), String(preserveRelatedMovieGroups)
        ].joined(separator: "|")
    }

    var body: some View {
        List {
            Section {
                Text("Try advanced features individually and compare the same video before and after. New experiments start off; existing Smart pipeline preferences are kept exactly as saved.")
                    .font(.subheadline)
                Text("Some options can increase latency, miss text, include unrelated words or change translation fluency.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            newModelSection
            newRecognitionSection
            newRenderingSection
            existingRecognitionSection
            existingContinuitySection
            existingTranslationSection
            existingWorkloadSection
            comparisonSection
            builtInSection

            Section {
                Button("Use fixed recognition and legacy continuity") {
                    adaptiveOCR = false
                    adaptiveConfirmation = false
                    subtitleTracking = false
                    deduplicateCopies = false
                    selectiveSpeculation = false
                    steadyCaptions = false
                    smartCool = false
                }
                .accessibilityHint("Switches existing advanced recognition and continuity features off")
            }

            ResetSection(keys: [
                "lowLatencyTranslation", "incrementalBatchRecovery", "directPiPBuffer",
                "subtitleAwareChangeDetection", "preserveRelatedMovieGroups",
                "adaptiveOCR", "adaptiveConfirmation", "subtitleTracking",
                "deduplicateCopies", "selectiveSpeculation", "adaptiveSpeculation",
                "speculationConfidence", "confirmationDeadline", "steadyCaptions",
                "protectConfirmedPresentation", "smartCool", "contextualLanguage",
                "continuousRotation", "languageRecovery", "predictiveWarmup",
                "freshTranslationTest"
            ])
        }
        .settingsPage("Experimental Features")
        .onChange(of: pipelineSignature) { _, _ in engine.pipelineSettingsChanged() }
        .onChange(of: lowLatencyTranslation) { _, _ in engine.translationStrategyChanged() }
        .onChange(of: directPiPBuffer) { _, _ in engine.applyStyle() }
    }

    private var newModelSection: some View {
        Section {
            if #available(iOS 26.4, *) {
                ExperimentalOption(
                    title: "Low-latency translation models",
                    explanation: "Use Apple's traditional on-device translation models to prioritize speed and lower power. Wording may be less fluent; switching models also keeps their remembered results separate.",
                    enabled: $lowLatencyTranslation)
            } else {
                ExperimentalOption(
                    title: "Low-latency translation models",
                    explanation: "Requires iOS 26.4 or later. Earlier iOS versions keep the normal translation engine.",
                    enabled: $lowLatencyTranslation,
                    available: false)
            }
            ExperimentalOption(
                title: "Incremental translation recovery",
                explanation: "Save completed speculative sentences in temporary memory even when the rest of their batch is still running. Never displays incomplete captions or saves unconfirmed translations permanently.",
                enabled: $incrementalBatchRecovery)
            ExperimentalOption(
                title: "Predictive model warm-up",
                explanation: "When Automatic has not identified the language yet, prepare a recently confirmed language model before subtitles appear. Live translation takes priority.",
                enabled: $predictiveWarmup)
        } header: {
            Text("Translation model experiments")
        } footer: {
            Text("New model and recovery experiments are off by default. Predictive warm-up already existed; its saved setting has not changed.")
        }
    }

    private var newRecognitionSection: some View {
        Section {
            ExperimentalOption(
                title: "Subtitle-area change detection",
                explanation: "Look more closely for changes within the selected subtitle area so small text changes may trigger OCR sooner. Upright video uses the focused scan; rotated video falls back to the full screen.",
                enabled: $subtitleAwareChangeDetection,
                available: skipUnchanged)
            if !skipUnchanged {
                Text("Enable Skip unchanged frames in Reading & OCR first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ExperimentalOption(
                title: "Multiple nearby lyric groups",
                explanation: "Try to keep separate, aligned lyric or dialogue rows in Movie mode. May accidentally include text unrelated to the subtitle.",
                enabled: $preserveRelatedMovieGroups,
                available: mode == TranslateMode.movie.rawValue)
            if mode != TranslateMode.movie.rawValue {
                Text("Available in Movie mode only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("New OCR and lyrics experiments")
        }
    }

    private var newRenderingSection: some View {
        Section {
            ExperimentalOption(
                title: "Direct PiP pixel-buffer rendering",
                explanation: "Draw translations directly into the floating window's pixel buffer instead of creating an intermediate image. May reduce work, but appearance and compatibility need testing.",
                enabled: $directPiPBuffer)
        } header: {
            Text("Rendering experiment")
        }
    }

    private var existingRecognitionSection: some View {
        Section {
            ExperimentalOption(
                title: "Adaptive OCR detail in Balanced",
                explanation: "Use less image detail for large clear text and more for small or difficult text. Fast and Sharp retain their normal base settings.",
                enabled: $adaptiveOCR)
            ExperimentalOption(
                title: "Confidence-aware confirmation",
                explanation: "Allow very clear text to confirm sooner and uncertain text to receive more readings instead of always using only the fixed read count.",
                enabled: $adaptiveConfirmation)
            VStack(alignment: .leading, spacing: 5) {
                LabeledContent("Confirmation deadline", value: String(format: "%.2f s", confirmationDeadline))
                Slider(value: $confirmationDeadline, in: 0.2...1.2, step: 0.05)
                    .disabled(!adaptiveConfirmation)
                Text("How long the adaptive confirmation logic can wait for reliable text; it does not force low-confidence words through.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Existing recognition options")
        }
    }

    private var existingContinuitySection: some View {
        Section {
            ExperimentalOption(
                title: "Track subtitle position and lifetime",
                explanation: "Follow text as it moves or changes position to keep subtitle groups together.",
                enabled: $subtitleTracking)
            ExperimentalOption(
                title: "Merge duplicate subtitle copies",
                explanation: "Remove repeated OCR copies of the same visible caption without removing genuine repeated lyric lines.",
                enabled: $deduplicateCopies)
            ExperimentalOption(
                title: "Stable caption transitions",
                explanation: "Avoid replacing a confirmed caption with a tentative or incomplete newer reading.",
                enabled: $steadyCaptions)
            ExperimentalOption(
                title: "Protect confirmed captions during handoffs",
                explanation: "Give an already-confirmed caption a short, bounded opportunity to finish before another confirmed caption replaces it.",
                enabled: $protectConfirmedPresentation)
        } header: {
            Text("Existing subtitle continuity")
        }
    }

    private var existingTranslationSection: some View {
        Section {
            ExperimentalOption(
                title: "Selective pre-translation",
                explanation: "Start early translations only for sufficiently clear OCR candidates, reducing wrong guesses and wasted model work.",
                enabled: $selectiveSpeculation)
            VStack(alignment: .leading, spacing: 5) {
                LabeledContent("Minimum early-translation confidence",
                               value: "\(Int(speculationConfidence * 100))%")
                Slider(value: $speculationConfidence, in: 0.65...0.98, step: 0.01)
                    .disabled(!selectiveSpeculation)
                Text("Only affects early guesses; confirmed captions still receive translation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ExperimentalOption(
                title: "Adapt speculative work to usefulness",
                explanation: "Reduce unnecessary early translation when recent predictions are frequently discarded. Keep regular opportunities to recover.",
                enabled: $adaptiveSpeculation)
            ExperimentalOption(
                title: "Use recent context for ambiguous languages",
                explanation: "Use a few seconds of previously confirmed text to help identify ambiguous short subtitles.",
                enabled: $contextualLanguage)
            ExperimentalOption(
                title: "Recover Automatic after repeated failures",
                explanation: "Forget an unreliable automatic-language guess and analyze the next OCR text again after repeated model failures.",
                enabled: $languageRecovery)
        } header: {
            Text("Existing translation intelligence")
        }
    }

    private var existingWorkloadSection: some View {
        Section {
            ExperimentalOption(
                title: "Recheck settled rotation continuously",
                explanation: "Keep watching for strong reading-order evidence of a rotation change after automatic rotation has settled. Can cause extra recalibration.",
                enabled: $continuousRotation)
            ExperimentalOption(
                title: "Smart Cool Mode controller",
                explanation: "When Cool Mode is enabled, adapt OCR frequency and early translation work to the phone's workload and temperature.",
                enabled: $smartCool)
        } header: {
            Text("Existing device and rotation controls")
        }
    }

    private var comparisonSection: some View {
        Section {
            ExperimentalOption(
                title: "Fresh translation test",
                explanation: "Temporarily bypass existing translation memory and early predictions for fair speed comparisons. Does not delete stored translations; may be slower and warmer.",
                enabled: $freshTranslationTest)
        } header: {
            Text("Comparison tools")
        }
    }

    private var builtInSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 5) {
                Text("Pipeline profiling")
                    .font(.subheadline.weight(.medium))
                Text("Automatically records OCR, model and PiP timing markers for developers using Instruments. Does not include your subtitle text in the markers.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("PiP heartbeat backpressure")
                    .font(.subheadline.weight(.medium))
                Text("Automatically avoids sending redundant idle PiP frames when the rendering queue is full. New subtitle frames are still submitted immediately.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Built-in optimizations (no switches)")
        }
    }
}
