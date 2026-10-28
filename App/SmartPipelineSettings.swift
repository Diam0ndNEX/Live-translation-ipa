import SwiftUI

struct SmartPipelineSettings: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @AppStorage("adaptiveOCR") private var adaptiveOCR = true
    @AppStorage("adaptiveConfirmation") private var adaptiveConfirmation = false
    @AppStorage("subtitleTracking") private var tracking = true
    @AppStorage("deduplicateCopies") private var deduplicate = true
    @AppStorage("selectiveSpeculation") private var selective = true
    @AppStorage("adaptiveSpeculation") private var adaptiveSpeculation = true
    @AppStorage("speculationConfidence") private var speculativeConfidence = 0.85
    @AppStorage("confirmationDeadline") private var deadline = 0.6
    @AppStorage("steadyCaptions") private var steady = true
    @AppStorage("protectConfirmedPresentation") private var protectConfirmed = true
    @AppStorage("smartCool") private var smartCool = true
    @AppStorage("contextualLanguage") private var contextualLanguage = true
    @AppStorage("continuousRotation") private var continuousRotation = false
    @AppStorage("languageRecovery") private var recovery = true
    private var signature: String { "\(adaptiveSpeculation)|\(protectConfirmed)|\(adaptiveOCR)|\(adaptiveConfirmation)|\(tracking)|\(deduplicate)|\(selective)|\(speculativeConfidence)|\(deadline)|\(steady)|\(smartCool)|\(recovery)|\(contextualLanguage)|\(continuousRotation)" }
    var body: some View {
        List {
            Section {
                Toggle("Adaptive detail in Balanced", isOn: $adaptiveOCR)
                Text("Balanced can use less detail for large clear text and more for small or uncertain text. Auto always adapts; Fast and Sharp retain their configured base profiles.").font(.footnote).foregroundStyle(.secondary)
                Toggle("Confidence-aware confirmation", isOn: $adaptiveConfirmation)
                LabeledContent("Confirmation deadline", value: String(format: "%.2f s", deadline))
                Slider(value: $deadline, in: 0.2...1.2, step: 0.05).disabled(!adaptiveConfirmation)
                Text("Off uses your fixed Instant/Normal/Careful read count. On permits exceptionally clear text immediately (except Careful), and extends uncertain reads. The deadline requires at least two matching reads and sufficient confidence; it never forces unreliable text through.").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Recognition") }
            Section {
                Toggle("Track subtitle position and lifetime", isOn: $tracking)
                Toggle("Merge duplicate subtitle copies", isOn: $deduplicate)
                Toggle("Stable caption transitions", isOn: $steady)
                Toggle("Protect confirmed captions during short handoffs", isOn: $protectConfirmed)
                Text("Gives an already confirmed subtitle up to 450 ms to complete before processing the newest confirmed replacement; never blocks a fresh subtitle indefinitely.").font(.footnote).foregroundStyle(.secondary)
                Text("Tracking follows the complete visible group, including lyric rows. Duplicate copies are matched by complete region text; repeated rows within a group remain intact. Stable transitions cancel obsolete work when a newer candidate arrives, while keeping the last valid caption until its replacement is ready.").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Subtitle continuity") }
            Section {
                Toggle("Selective pre-translation", isOn: $selective)
                Toggle("Adapt speculative work to observed usefulness", isOn: $adaptiveSpeculation)
                Text("If speculative jobs are repeatedly discarded without being reused, periodically throttle tentative model requests while continuing confirmed subtitles at full priority.").font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Minimum speculative confidence", value: "\(Int(speculativeConfidence*100))%")
                Slider(value: $speculativeConfidence, in: 0.65...0.98, step: 0.01).disabled(!selective)
                Text("Uses the existing Translate ahead switch. Low-confidence early reads are declined, and superseded requests are cancelled where the translation engine supports cancellation. Completed but unused results stay session-only until confirmed input uses them.").font(.footnote).foregroundStyle(.secondary)
                Toggle("Use recent context for ambiguous sources", isOn: $contextualLanguage)
                Text("Confident recent source text can assist an ambiguous reading for up to eight seconds. A clear new language bypasses this context.").font(.footnote).foregroundStyle(.secondary)
                Toggle("Recheck settled rotation continuously", isOn: $continuousRotation)
                Text("Off holds a settled rotation until the device orientation or rotation setting changes, and caps unsuccessful probes. On permits renewed calibration when reading-order evidence reverses.").font(.footnote).foregroundStyle(.secondary)
                Toggle("Recover Automatic after repeated failures", isOn: $recovery)
                Text("Clears source evidence and requests fresh OCR after repeated translation failures. It does not guess whether a successfully returned sentence is semantically correct.").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Translation") }
            Section {
                Toggle("Smart Cool Mode controller", isOn: $smartCool)
                Text("When Cool Mode is enabled, adapts cadence to measured OCR time, unchanged text and recognition failures. It preserves image detail for difficult text and allows only exceptionally confident speculative work when the device is cool and OCR is quick. Off restores the fixed Cool Mode interval policy. Idle model warm-ups remain disabled in both Cool modes.").font(.footnote).foregroundStyle(.secondary)
                Text("Settings may trade response speed, coverage of brief captions and energy use. Device measurements are needed to compare them.").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Workload") }
            Section {
                Button("Use fixed recognition and legacy continuity") {
                    adaptiveOCR = false; adaptiveConfirmation = false; tracking = false; deduplicate = false
                    selective = false; steady = false; smartCool = false
                }
            }
            ResetSection(keys: ["adaptiveOCR", "adaptiveConfirmation", "subtitleTracking", "deduplicateCopies", "selectiveSpeculation", "adaptiveSpeculation", "protectConfirmedPresentation", "speculationConfidence", "confirmationDeadline", "steadyCaptions", "smartCool", "languageRecovery", "contextualLanguage", "continuousRotation"])
        }
        .settingsPage("Smart pipeline")
        .onChange(of: signature) { _, _ in engine.pipelineSettingsChanged() }
    }
}
