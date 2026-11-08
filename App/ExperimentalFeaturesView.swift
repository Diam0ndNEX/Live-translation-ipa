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
    // 2.2.1 (D13): run-time A/B variants. They are copied when a session starts, never changed mid-run.
    @AppStorage("hybridSchedulerVariant") private var hybridSchedulerVariant = "evidenceBounded"
    @AppStorage("hotPathReuseLowLatencyPlan") private var hotPathReuseLowLatencyPlan = true
    @AppStorage("hotPathReuseLegacyUnits") private var hotPathReuseLegacyUnits = true
    @AppStorage("liveWarmupLegacy") private var liveWarmupLegacy = true
    // 2.2.3 (L5): default OFF = current behaviour. Pinned at session start like the other A/B variants.
    @AppStorage("backgroundAvailabilityRefresh") private var backgroundAvailabilityRefresh = false
    // 2.2.3 (L3, L4): Hybrid-only, default OFF = current behaviour.
    @AppStorage("hybridRelaxedBackoff") private var hybridRelaxedBackoff = false
    @AppStorage("hybridShorterGuard") private var hybridShorterGuard = false
    @AppStorage("legacyConfirmedOwnLane") private var legacyConfirmedOwnLane = false

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
            Section {
                Text("Optional features that are still being tested. Some are on by default; you can switch any of them off. Your normal settings are never changed for you.")
                    .font(.subheadline)
                Text("Try one switch at a time on the same video. Switch it off again if captions get slower, less complete or less accurate.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink("Translation system") { TranslationSettings() }
                Text("Pick Legacy, Hybrid or Low Latency in Settings > System, or on Translate.")
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
                    Text("Turn on Skip unchanged frames in Settings > Area and recognition first.")
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
                Picker("Hybrid scheduler", selection: $hybridSchedulerVariant) {
                    Text("Evidence bounded (default)").tag("evidenceBounded")
                    Text("Recovery first").tag("recoveryFirst")
                    Text("Reference 1.9.5").tag("reference195")
                }
                ExperimentalOption(
                    title: "Reuse the Low Latency plan",
                    explanation: "On (default): Low Latency reuses the prepared plan for the same caption. Off prepares it again each time, for comparison.",
                    enabled: $hotPathReuseLowLatencyPlan)
                ExperimentalOption(
                    title: "Reuse Legacy prepared units",
                    explanation: "On (default): Legacy reuses prepared text units. Off prepares them again each time, for comparison.",
                    enabled: $hotPathReuseLegacyUnits)
                ExperimentalOption(
                    title: "Legacy warm-up during capture",
                    explanation: "On (default): Legacy may run a short warm-up translation while capture is live and quiet. Off: no warm-up while capturing, for comparison. Unverified effect.",
                    enabled: $liveWarmupLegacy)
                ExperimentalOption(
                    title: "Refresh language check in background",
                    explanation: "Off (default): the language-pack check is repeated when a translation needs it after 30 seconds, as before. On: it is refreshed in the background while nothing is translating, so a translation does not wait for it. Same translations either way. Unverified effect.",
                    enabled: $backgroundAvailabilityRefresh)
                ExperimentalOption(
                    title: "Hybrid relaxed backoff",
                    explanation: "Hybrid Recovery only. Off (default): after repeated unused early Apple Default work, the next 8 early requests are skipped. On: 4 are skipped, so early work resumes sooner. Same Apple Default text, but more unused calls may compete with confirmed ones. Unverified effect.",
                    enabled: $hybridRelaxedBackoff)
                ExperimentalOption(
                    title: "Hybrid shorter switch guard",
                    explanation: "Hybrid Recovery only. Off (default): Low Latency recovery waits until 1.5 s after an Apple Default call, with a 220 ms settling wait. On: 1.0 s and 120 ms. Same models and text; a slow 900 ms recovery may return. Unverified effect.",
                    enabled: $hybridShorterGuard)
                ExperimentalOption(
                    title: "Legacy confirmed own lane",
                    explanation: "Legacy mode, iOS 26 and later. Off (default): when a caption is confirmed while a different early translation is still running, the confirmed one waits for the early one to stop. On: it starts right away on its own session, so two Apple Default calls can run at once and may slow each other. Same text. Unverified effect.",
                    enabled: $legacyConfirmedOwnLane)
            } header: { Text("A/B test variants") } footer: {
                Text("For comparing builds on the same video. A change applies from the next session, never during one. Each run's report names the variant it used.")
            }

            Section {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Pipeline profiling").font(.subheadline.weight(.medium))
                    Text("Always on: records timing numbers for Xcode Instruments. No caption text is included.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Floating window refresh back-pressure").font(.subheadline.weight(.medium))
                    Text("Always on: skips needless idle frames when the floating window is busy. New captions still appear at once.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Always on") }

            ResetSection(keys: [
                "incrementalBatchRecovery", "directPiPBuffer", "hybridSwitchGuard",
                "pixelConfirmation", "eventDrivenOCR", "fastOCR", "legacySharedSession",
                "subtitleAwareChangeDetection", "preserveRelatedMovieGroups",
                "adaptiveConfirmation", "confirmationDeadline", "continuousRotation",
                "hybridSchedulerVariant", "hotPathReuseLowLatencyPlan", "hotPathReuseLegacyUnits", "liveWarmupLegacy",
                "backgroundAvailabilityRefresh", "hybridRelaxedBackoff", "hybridShorterGuard", "legacyConfirmedOwnLane"
            ])
        }
        .settingsPage("Experimental features")
        .onChange(of: pipelineSignature) { _, _ in engine.pipelineSettingsChanged() }
        .onChange(of: directPiPBuffer) { _, _ in engine.applyStyle() }
    }
}
