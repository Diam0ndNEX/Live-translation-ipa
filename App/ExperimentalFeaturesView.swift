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
    @AppStorage("pixelConfirmation") private var pixelConfirmation = true
    @AppStorage("eventDrivenOCR") private var eventDrivenOCR = true
    @AppStorage("fastOCR") private var fastOCR = false
    @AppStorage("legacySharedSession") private var legacySharedSession = true
    @AppStorage("subtitleAwareChangeDetection") private var subtitleAwareChangeDetection = false
    @AppStorage("preserveRelatedMovieGroups") private var preserveRelatedMovieGroups = false
    // 2.2.1 (D13): run-time A/B variants. They are copied when a session starts, never changed mid-run.
    @AppStorage("hotPathReuseLowLatencyPlan") private var hotPathReuseLowLatencyPlan = true
    @AppStorage("hotPathReuseLegacyUnits") private var hotPathReuseLegacyUnits = true
    @AppStorage("liveWarmupLegacy") private var liveWarmupLegacy = true
    // 2.2.3 (L5), default ON since 2.4.0. Pinned at session start like the other A/B variants.
    @AppStorage("backgroundAvailabilityRefresh") private var backgroundAvailabilityRefresh = true
    // 2.4.0: default ON; off gives the 2.3.9 behaviour.
    @AppStorage("deferArmedSpeculation") private var deferArmedSpeculation = true
    // 2.5.0 (items A to F and the quiet re-warm): all default ON; off gives the 2.4.0 behaviour.
    @AppStorage("warmAtCaptureStart") private var warmAtCaptureStart = true
    @AppStorage("reportStoredSessionTotals") private var reportStoredSessionTotals = true
    @AppStorage("confirmationReadReasons") private var confirmationReadReasons = true
    @AppStorage("modelLengthBuckets") private var modelLengthBuckets = true
    @AppStorage("trustedCaptionBand") private var trustedCaptionBand = true
    @AppStorage("legacyHeadStart") private var legacyHeadStart = true
    @AppStorage("quietRewarm") private var quietRewarm = true
    @AppStorage("legacyConfirmedOwnLane") private var legacyConfirmedOwnLane = false
    @AppStorage("independentCaptureHeartbeat") private var independentCaptureHeartbeat = false

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
                Text("Pick Legacy or Low Latency in Settings > System, or on Translate.")
                    .font(.footnote).foregroundStyle(.secondary)
                ExperimentalOption(
                    title: "Incremental translation recovery",
                    explanation: "Keeps sentences that were already translated ahead of time, even if the rest of the batch was interrupted, so they can be reused. Never shows an unfinished caption.",
                    enabled: $incrementalBatchRecovery)
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
                    explanation: "On (default since 2.4.0): the language-pack check is refreshed in the background while nothing is translating, so a translation does not wait for it. Off: the check is repeated when a translation needs it after 30 seconds, as before 2.4.0. Same translations either way. Unverified effect.",
                    enabled: $backgroundAvailabilityRefresh)
                ExperimentalOption(
                    title: "Wait for confirmation before early Apple Default work",
                    explanation: "Legacy only. On (default): when a new caption can be confirmed on the next frame, no early translation is started for it; the confirmed caption starts the translation. Off: an early translation is started for every first reading, as in 2.3.9. Same model and same text either way. Unverified effect.",
                    enabled: $deferArmedSpeculation)
                ExperimentalOption(
                    title: "Legacy confirmed own lane",
                    explanation: "Legacy mode, iOS 26 and later. Off (default): when a caption is confirmed while a different early translation is still running, the confirmed one waits for the early one to stop. On: it starts right away on its own session, so two Apple Default calls can run at once and may slow each other. Same text. Unverified effect.",
                    enabled: $legacyConfirmedOwnLane)
                ExperimentalOption(
                    title: "Independent capture heartbeat",
                    explanation: "All modes. Off (default): ScreenLingo decides capture has stopped after 5 seconds without a message, and the capture extension only sends its keep-alive while screen frames arrive. On: the extension also sends a small keep-alive from a timer, but only when 1.5 seconds have passed without any other message, so with normal frames nothing extra is sent. Meant for a false \"stopped\" while the screen-recording icon is still on. Does not change reading, confirmation or translation. Unverified effect.",
                    enabled: $independentCaptureHeartbeat)
            } header: { Text("A/B test variants") } footer: {
                Text("For comparing builds on the same video. A change applies from the next session, never during one. Each run's report names the variant it used.")
            }

            Section {
                ExperimentalOption(
                    title: "Warm up when capture starts",
                    explanation: "Both modes. On (default): one short practice translation runs when capture starts, so the first caption does not wait for the model to load. Its result is thrown away. Off: the model loads with the first caption, as in 2.4.0. Same captions and wording either way. UNVERIFIED effect.",
                    enabled: $warmAtCaptureStart)
                ExperimentalOption(
                    title: "Trusted caption band",
                    explanation: "Low Latency only. CHANGES WHAT IS READ. On (default): once captions have appeared in the same band of the screen, a new caption is read in that band only, without reading the whole area again. Text outside the band is found up to 0.75 s later. Off: every new caption is read in the whole area, as in 2.4.0. Turn off if captions are missed, cut short or flicker. UNVERIFIED effect.",
                    enabled: $trustedCaptionBand)
                ExperimentalOption(
                    title: "Legacy head start",
                    explanation: "Legacy only. CHANGES WHAT IS READ WHEN. On (default): a quick first read of a new caption may start its translation while the normal read is still running. The normal read still decides what is shown. It is used only while the quick read keeps matching the confirmed text, and stops by itself when it does not. Off: the translation starts after the normal read, as in 2.4.0. Turn off if Legacy gets slower. UNVERIFIED effect.",
                    enabled: $legacyHeadStart)
                ExperimentalOption(
                    title: "Re-warm after a quiet stretch",
                    explanation: "Low Latency only. On (default): after 15 seconds without a caption, at most once a minute, one short practice translation keeps the model ready. Its result is thrown away. Off: no practice translations during capture, as in 2.4.0. Same captions and wording. UNVERIFIED effect; may use a little more battery.",
                    enabled: $quietRewarm)
                ExperimentalOption(
                    title: "Report: reasons for extra reads",
                    explanation: "All modes, Diagnostics only. On (default): when a caption needed another read before it was confirmed, the report says why (fixed codes, no text). Off: not recorded, as in 2.4.0.",
                    enabled: $confirmationReadReasons)
                ExperimentalOption(
                    title: "Report: model time by caption length",
                    explanation: "All modes, Diagnostics only. On (default): translation times are also grouped by how many characters were translated (a number, no text). Off: not recorded, as in 2.4.0.",
                    enabled: $modelLengthBuckets)
                ExperimentalOption(
                    title: "Report: keep totals of saved runs",
                    explanation: "Diagnostics only. On (default): a report made from a saved run keeps its whole-session totals, for example early starts deferred. Off: those totals read 0 for saved runs, as in 2.4.0 (a fault, kept only for comparison).",
                    enabled: $reportStoredSessionTotals)
            } header: { Text("New in 2.5.0") } footer: {
                Text("All on by default and not measured yet. A change applies from the next session. Each run's report names the switches that were on.")
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
                "incrementalBatchRecovery", "directPiPBuffer",
                "pixelConfirmation", "eventDrivenOCR", "fastOCR", "legacySharedSession",
                "subtitleAwareChangeDetection", "preserveRelatedMovieGroups",
                "adaptiveConfirmation", "confirmationDeadline", "continuousRotation",
                "hotPathReuseLowLatencyPlan", "hotPathReuseLegacyUnits", "liveWarmupLegacy",
                "backgroundAvailabilityRefresh", "legacyConfirmedOwnLane", "independentCaptureHeartbeat",
                "deferArmedSpeculation",
                "warmAtCaptureStart", "reportStoredSessionTotals", "confirmationReadReasons", "modelLengthBuckets",
                "trustedCaptionBand", "legacyHeadStart", "quietRewarm"
            ])
        }
        .settingsPage("Experimental features")
        .onChange(of: pipelineSignature) { _, _ in engine.pipelineSettingsChanged() }
        .onChange(of: directPiPBuffer) { _, _ in engine.applyStyle() }
    }
}
