// ScreenLingo – Modular settings and backup controls
import SwiftUI
import UIKit

// MARK: - Settings
struct SettingsView: View {
    private func translationModeOption(_ item: TranslateMode) -> some View {
        Text(item.title).tag(item.rawValue)
    }

    private func ocrAreaOption(_ item: OCRArea) -> some View {
        Text(item.title).tag(item.rawValue)
    }

    private func windowSizeOption(_ item: WindowSize) -> some View {
        Text(item.title).tag(item.rawValue)
    }

    private func themeOption(_ item: PiPTheme) -> some View {
        Text(item.title).tag(item.rawValue)
    }

    private func speedPresetOption(_ item: SpeedPreset) -> some View {
        Text(item.title).tag(item.rawValue)
    }

    private func textSizeOption(_ item: PiPTextSize) -> some View {
        Text(item.title).tag(item.rawValue)
    }


    private var confidencePercentage: String { String(Int(ocrConfidence * 100)) + "%" }

    @EnvironmentObject var engine: TranslatorEngine
    @AppStorage("includeDiagnosticText") private var includeDiagnosticText = true
    @State private var diagnosticExportURL: URL?
    @State private var showingDiagnosticExport = false
    @State private var newProfileName = ""
    @State private var showingProfileNamePrompt = false
    @State private var showingImportResult = false
    @State private var importResultMessage = ""
    @AppStorage("theme") private var theme = PiPTheme.dark.rawValue
    @AppStorage("textSize") private var textSize = PiPTextSize.auto.rawValue
    @AppStorage("speak") private var speak = false
    @AppStorage("mode") private var mode = TranslateMode.movie.rawValue
    @AppStorage("area") private var area = OCRArea.smart.rawValue
    @AppStorage("winSize") private var winSize = WindowSize.normal.rawValue
    @AppStorage("showOriginal") private var showOriginal = false
    @AppStorage("speed") private var speed = SpeedPreset.balanced.rawValue
    @AppStorage("autoClear") private var autoClear = true
    @AppStorage("textHoldDuration") private var textHoldDuration: Double = 2.0
    @AppStorage("ocrConfidence") private var ocrConfidence: Double = 0.30
    @AppStorage("languageCorrection") private var languageCorrection = true
    @AppStorage("rightToLeftReading") private var rightToLeftReading = false
    @AppStorage("cleanOCR") private var cleanOCR = true
    @AppStorage("slang") private var slang = true
    @AppStorage("speakerDetect") private var speakerDetect = true
    @AppStorage("langLock") private var langLock = true
    @AppStorage("neverTranslate") private var neverTranslate = ""
    @AppStorage("sourceFixes") private var sourceFixes = ""
    @AppStorage("glossary") private var glossary = ""
    @AppStorage("pipFont") private var pipFont = PiPFont.standard.rawValue
    @AppStorage("highlightNames") private var highlightNames = true
    @AppStorage("customY0") private var customY0 = 0.0
    @AppStorage("customY1") private var customY1 = 0.5
    @AppStorage("frameRot") private var frameRot = "auto"
    @AppStorage("minTextH") private var minTextH = 0.0
    @AppStorage("ignoreList") private var ignoreList = ""
    @AppStorage("dropNoise") private var dropNoise = true
    @AppStorage("boost") private var boost = 1
    @AppStorage("stability") private var stability = 1
    @AppStorage("skipUnchanged") private var skipUnchanged = true

    var body: some View {
        NavigationStack {
            List {
                appBuildSection
                translationPerformanceSection
                textIntelligenceSection
                profilesBackupSection
                floatingWindowSection
                automationSection
                diagnosticsSection
                changelogSection
                privacySection
                resetSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .sheet(isPresented: $showingDiagnosticExport) {
                NavigationStack {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text").font(.largeTitle)
                        Text("Diagnostic report ready").font(.headline)
                        Text("Share or save the full report as a .txt file. It follows your recognized-text privacy setting.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if let diagnosticExportURL {
                            ShareLink(item: diagnosticExportURL) {
                                Label("Share / Save .txt", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent)
                        }
                        Spacer()
                    }.padding()
                    .navigationTitle("Export diagnostics")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showingDiagnosticExport = false } } }
                }.presentationDetents([.medium])
            }
            .alert("Save settings profile", isPresented: $showingProfileNamePrompt) {
                TextField("Profile name", text: $newProfileName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    engine.saveProfile(newProfileName)
                    newProfileName = ""
                }
            } message: {
                Text("Save the current translation, OCR and floating-window settings.")
            }
            .alert("Settings import", isPresented: $showingImportResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importResultMessage)
            }
            .onChange(of: theme) { _, _ in engine.applyStyle() }
            .onChange(of: textSize) { _, _ in engine.applyStyle() }
            .onChange(of: pipFont) { _, _ in engine.applyStyle() }
            .onChange(of: highlightNames) { _, _ in engine.applyStyle() }
            .onChange(of: winSize) { _, _ in engine.applyWindowSize() }
            .onChange(of: speed) { _, _ in engine.syncConfig() }
            .onChange(of: area) { _, _ in engine.syncConfig() }
            .onChange(of: mode) { _, _ in engine.syncConfig() }
            .onChange(of: ocrConfidence) { _, _ in engine.syncConfig() }
            .onChange(of: languageCorrection) { _, _ in engine.syncConfig() }
            .onChange(of: customY0) { _, _ in engine.syncConfig() }
            .onChange(of: customY1) { _, _ in engine.syncConfig() }
            .onChange(of: minTextH) { _, _ in engine.syncConfig() }
            .onChange(of: ignoreList) { _, _ in engine.syncConfig() }
            .onChange(of: dropNoise) { _, _ in engine.syncConfig() }
            .onChange(of: boost) { _, _ in engine.syncConfig() }
            .onChange(of: stability) { _, _ in engine.syncConfig() }
            .onChange(of: skipUnchanged) { _, _ in engine.syncConfig() }
            .onChange(of: frameRot) { _, _ in engine.syncConfig() }
        }
    }

    private var appBuildSection: some View {
            Section("App & build") {
                LabeledContent("App", value: "ScreenLingo")
                LabeledContent("Version", value: AppVersion.full)
                LabeledContent("Bundle ID", value: "com.diam0ndnex.screenlingo")
                LabeledContent("Capture extension",
                               value: engine.extensionVersion == "–" ? "Not connected" : "v\(engine.extensionVersion)")
                LabeledContent("Capture", value: engine.captureAlive ? "Connected" : "Idle")
            }
    }

    private var translationPerformanceSection: some View {
            Section {
                Picker("Translation mode", selection: $mode) {
                    ForEach(TranslateMode.allCases) { item in
                        translationModeOption(item)
                    }
                }
                Picker("Text capture area", selection: $area) {
                    ForEach(OCRArea.allCases) { item in
                        ocrAreaOption(item)
                    }
                }
                if area == OCRArea.custom.rawValue {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Read from \(Int(customY0 * 100))% to \(Int(customY1 * 100))% of screen height (0% = bottom)")
                            .font(.footnote).foregroundStyle(.secondary)
                        Slider(value: $customY0, in: 0...0.9)
                        Slider(value: $customY1, in: 0.1...1)
                    }
                }
                Picker("Performance profile", selection: $speed) {
                    ForEach(SpeedPreset.allCases) { item in
                        speedPresetOption(item)
                    }
                }
                Text(speedDescription)
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Language-aware OCR correction", isOn: $languageCorrection)
                Toggle("Right-to-left manga reading", isOn: $rightToLeftReading)
                Text("Use this for Japanese manga layouts that read right-to-left. Leave it off for subtitles, games, and left-to-right comics.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Minimum OCR confidence")
                        Spacer()
                        Text(confidencePercentage).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $ocrConfidence, in: 0.15...0.75, step: 0.05)
                    Text("Lower values catch faint or stylized text but may include more mistakes. Higher values are stricter and can miss difficult text.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ignore text smaller than \(Int(minTextH * 100))% of screen height")
                    Slider(value: $minTextH, in: 0...0.08, step: 0.005)
                }
                TextField("Ignore text containing… (comma separated)", text: $ignoreList, axis: .vertical)
                    .lineLimit(1...3)
                Toggle("Ignore numbers and symbol noise", isOn: $dropNoise)
                Picker("Contrast boost", selection: $boost) {
                    Text("Off").tag(0)
                    Text("Only when text is hard to find").tag(1)
                    Text("Always").tag(2)
                }
                Picker("Wait for stable text", selection: $stability) {
                    Text("Instant").tag(1)
                    Text("Normal").tag(2)
                    Text("Careful").tag(3)
                }
                Toggle("Skip unchanged frames", isOn: $skipUnchanged)
                Picker("Frame rotation", selection: $frameRot) {
                    Text("Automatic").tag("auto")
                    Text("None").tag("0")
                    Text("90° clockwise").tag("90")
                    Text("180° (upside down)").tag("180")
                    Text("270° clockwise").tag("270")
                }
            } header: {
                Text("Translation & performance")
            } footer: {
                Text("Fast reduces OCR work for lower latency. Sharp processes larger frames for small text but may use more memory and battery.")
            }
    }

    private var textIntelligenceSection: some View {
        Section {
            Toggle("Clean up OCR mistakes", isOn: $cleanOCR)
            Toggle("Expand chat slang", isOn: $slang)
            Toggle("Preserve speaker names", isOn: $speakerDetect)
            Toggle("Lock detected language", isOn: $langLock)
            VStack(alignment: .leading, spacing: 6) {
                Text("Never translate").font(.subheadline.weight(.medium))
                TextEditor(text: $neverTranslate)
                    .frame(minHeight: 58, maxHeight: 110)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                Text("Names or terms separated by commas or new lines.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Fix OCR source text").font(.subheadline.weight(.medium))
                TextEditor(text: $sourceFixes)
                    .frame(minHeight: 58, maxHeight: 110)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                Text("One correction per line: wrong=right.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Translation glossary").font(.subheadline.weight(.medium))
                TextEditor(text: $glossary)
                    .frame(minHeight: 58, maxHeight: 110)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                Text("One replacement per line: translated term=preferred term.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Text intelligence")
        } footer: {
            Text("These rules run on recognized content before or after translation. They do not change what the screen recorder captures.")
        }
    }

    private var profilesBackupSection: some View {
        Section {
            Button { showingProfileNamePrompt = true } label: {
                Label("Save current settings as profile", systemImage: "square.and.arrow.down")
            }
            if engine.profileNames.isEmpty {
                Text("No saved profiles yet.").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(engine.profileNames, id: \.self) { profile in
                    HStack {
                        Button(profile) { engine.applyProfile(profile) }
                        Spacer()
                        Button(role: .destructive) { engine.deleteProfile(profile) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            ShareLink(item: engine.exportSettings()) {
                Label("Export settings backup", systemImage: "square.and.arrow.up")
            }
            Button {
                let clipboard = UIPasteboard.general.string ?? ""
                let success = engine.importSettings(clipboard)
                importResultMessage = success ? "Settings imported successfully." : "No valid ScreenLingo settings backup was found on the clipboard."
                showingImportResult = true
            } label: {
                Label("Import backup from clipboard", systemImage: "doc.on.clipboard")
            }
        } header: {
            Text("Profiles & backup")
        } footer: {
            Text("Backups contain preferences and saved profiles, not translation history or screen content.")
        }
    }

    private var floatingWindowSection: some View {
            Section("Floating window") {
                Picker("Window size", selection: $winSize) {
                    ForEach(WindowSize.allCases) { item in
                        windowSizeOption(item)
                    }
                }
                Picker("Appearance", selection: $theme) {
                    ForEach(PiPTheme.allCases) { item in
                        themeOption(item)
                    }
                }
                Picker("Text size", selection: $textSize) {
                    ForEach(PiPTextSize.allCases) { item in
                        textSizeOption(item)
                    }
                }
                Picker("Translation font", selection: $pipFont) {
                    ForEach(PiPFont.allCases) { font in Text(font.title).tag(font.rawValue) }
                }
                Toggle("Highlight speaker names", isOn: $highlightNames)
                Toggle("Show original above translation", isOn: $showOriginal)
                Toggle("Speak translations aloud", isOn: $speak)
            }
    }

    private var automationSection: some View {
        Section {
            Toggle("Clear when text disappears", isOn: $autoClear)
            if autoClear {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Keep text visible after it disappears")
                        Spacer()
                        Text(textHoldDuration == 0 ? "Immediately" : String(format: "%.1f s", textHoldDuration))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $textHoldDuration, in: 0...10, step: 0.5)
                    Text("Keeps the last translation on screen briefly after the source text vanishes. New text cancels the countdown.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Pause translation", isOn: $engine.paused)
        } header: {
            Text("Automation")
        } footer: {
            Text("Pause keeps the broadcast connected but stops new translation work. Your selected options are saved on this device.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            LabeledContent("Pipeline phase", value: engine.capturePhase)
            LabeledContent("App UDP listener", value: engine.serverReady ? "Ready" : "Not ready")
            LabeledContent("Capture extension", value: engine.captureAlive ? "Connected" : "No packets")
            LabeledContent("PiP state", value: engine.pipActive ? "Active" : "Inactive")
            LabeledContent("Extension version", value: engine.extensionVersion)
            LabeledContent("Last packet kind", value: engine.lastPacketKind)
            LabeledContent("Last packet", value: engine.lastPacketSummary)
            LabeledContent("Last packet age", value: engine.lastPacketAge < 0 ? "Never" : String(format: "%.2f s", engine.lastPacketAge))
            LabeledContent("Packets received", value: "\(engine.totalPackets)")
            LabeledContent("Ping / OCR / clear", value: "\(engine.pingPackets) / \(engine.ocrPackets) / \(engine.clearPackets)")
            LabeledContent("Frames reported", value: "\(engine.frames)")
            LabeledContent("OCR passes", value: "\(engine.ocrCount)")
            LabeledContent("Raw OCR lines", value: "\(engine.lastOCRLineCount)")
            LabeledContent("OCR latency", value: String(format: "%.1f ms", engine.ocrMs))
            LabeledContent("Translation latency", value: String(format: "%.1f ms", engine.translateMs))
            LabeledContent("Extension free memory", value: String(format: "%.1f MB", engine.extFreeMB))
            LabeledContent("Source language", value: engine.lastDetectedLanguage)
            LabeledContent("Target language", value: engine.targetCode)
            LabeledContent("Selected blocks", value: "\(engine.selectedBlockCount)")
            LabeledContent("OCR filter counts", value: engine.lastFilterSummary)
            LabeledContent("Accepted inputs", value: "\(engine.acceptedInputCount)")
            LabeledContent("Waiting for stabilization", value: "\(engine.stabilizationWaitCount)")
            LabeledContent("Stale results discarded", value: "\(engine.discardedStaleCount)")
            LabeledContent("Translation cache hits", value: "\(engine.cacheHits)")
            LabeledContent("Translation failures", value: "\(engine.translationFailures)")
            LabeledContent("Output quality", value: engine.lastOutputQuality)
            LabeledContent("Last translation error", value: engine.lastTranslationError)
            LabeledContent("Current status", value: engine.status)

            DisclosureGroup("Last raw OCR text") {
                Text(engine.lastRaw.isEmpty ? "No OCR received yet." : engine.lastRaw)
                    .font(.footnote).textSelection(.enabled)
            }
            DisclosureGroup("Latest candidate text") {
                Text(engine.lastCandidateText.isEmpty ? "No candidate yet." : engine.lastCandidateText)
                    .font(.footnote).textSelection(.enabled)
            }
            DisclosureGroup("Selected blocks / reading order") {
                Text(engine.lastSelectedBlocks.isEmpty ? "No blocks selected." : engine.lastSelectedBlocks)
                    .font(.footnote).textSelection(.enabled)
            }
            DisclosureGroup("Translation input") {
                Text(engine.lastTranslationInput.isEmpty ? "No translation input yet." : engine.lastTranslationInput)
                    .font(.footnote).textSelection(.enabled)
            }
            DisclosureGroup("Current original") {
                Text(engine.original.isEmpty ? "No original text yet." : engine.original)
                    .font(.footnote).textSelection(.enabled)
            }
            DisclosureGroup("Current translation") {
                Text(engine.translated.isEmpty ? "No translation yet." : engine.translated)
                    .font(.footnote).textSelection(.enabled)
            }
            DisclosureGroup("Processing trace — last 60 seconds") {
                Text(engine.processingTrace.isEmpty ? "No processing trace yet. Start capture and wait for text to appear." : engine.processingTrace.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("Recent diagnostic events (latest first)") {
                if engine.diagnosticEvents.isEmpty {
                    Text("No diagnostic events yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(engine.diagnosticEvents.reversed().enumerated()), id: \.offset) { item in
                        Text(item.element).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).padding(.vertical, 2)
                    }
                }
            }

            Button("Run translation test") { engine.runTest() }
            Button("Refresh language availability") {
                Task { await engine.refreshStatus() }
            }
            Button("Clear translation cache") { engine.clearTranslationCache() }
            Button("Clear diagnostic event log", role: .destructive) { engine.clearDiagnosticEvents() }
            Toggle("Include recognized text in reports", isOn: $includeDiagnosticText)
            Text(includeDiagnosticText
                 ? "Reports include actual OCR, source dialogue, and translated text. Check before sharing."
                 : "Text content is redacted. Coordinates, timestamps, block geometry, filter decisions, and language scores remain available.")
                .font(.footnote).foregroundStyle(.secondary)
            Button {
                let report = engine.copyDetailedDiagnosticReport(
                    includeRecognizedText: includeDiagnosticText,
                    compact: true
                )
                let chatPrompt = """
                Please diagnose this ScreenLingo live-translation issue using the report below. Base conclusions on evidence in the trace; do not assume a fix worked unless the report verifies it.

                Focus on:
                1. OCR reading ScreenLingo UI/PiP output (for example Home, Settings, History, or "pt → en") instead of only the video.
                2. Duplicate subtitle copies at different positions producing overlapping blocks sent for translation.
                3. PiP/self-output feedback filtering that appears ineffective.
                4. In movie mode, suppress interface text and choose one clearest, most complete source-language subtitle block.
                5. Concrete fixes at the correct pipeline stage and diagnostics to verify them, without regressing games, manga, or other OCR modes.

                DIAGNOSTIC REPORT
                ----------------
                \(report)
                """
                UIPasteboard.general.string = chatPrompt
                engine.status = "ChatGPT-ready diagnostic report copied"
            } label: {
                Label("Copy report for ChatGPT", systemImage: "text.bubble")
            }
            Button("Copy compact report (last 60 seconds)") {
                UIPasteboard.general.string = engine.copyDetailedDiagnosticReport(includeRecognizedText: includeDiagnosticText, compact: true)
                engine.status = "Compact diagnostic report copied"
            }
            Button("Export full diagnostic report (.txt)") {
                let report = engine.copyDetailedDiagnosticReport(includeRecognizedText: includeDiagnosticText, compact: false)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenLingo-Diagnostics-\(stamp).txt")
                do {
                    try Data(report.utf8).write(to: url, options: .atomic)
                    diagnosticExportURL = url
                    showingDiagnosticExport = true
                    engine.status = "Full diagnostic report ready to share"
                } catch {
                    engine.status = "Could not export report: \(error.localizedDescription)"
                }
            }
        } header: {
            Text("Live diagnostics")
        } footer: {
            Text("Compact reports include only the last 60 seconds and are capped at 15,000 characters. Export the fuller trace history as a .txt file for deeper debugging. The recognized-text toggle applies to both exports.")
        }
    }

    private var changelogSection: some View {
            Section("Changelog") {
                ForEach(AppVersion.changelog, id: \.0) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("v\(v.0)").bold()
                        Text(v.1).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
    }

    private var privacySection: some View {
            Section("Privacy") {
                Label("On-device translation", systemImage: "iphone")
                Text("ScreenLingo uses Apple's on-device Translation framework and stores translation history in local app preferences. This project does not upload your recognized text to a translation server.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
    }

    private var resetSection: some View {
            Section("Reset") {
                Button("Reset all settings", role: .destructive) {
                    for key in ["source", "target", "mode", "area", "winSize", "showOriginal", "speed", "autoClear", "ocrConfidence", "languageCorrection", "rightToLeftReading", "theme", "textSize", "speak"] {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                    engine.sourceCode = "auto"
                    engine.targetCode = "en"
                    mode = TranslateMode.movie.rawValue
                    area = OCRArea.smart.rawValue
                    winSize = WindowSize.normal.rawValue
                    showOriginal = false
                    speed = SpeedPreset.balanced.rawValue
                    autoClear = true
                    theme = PiPTheme.dark.rawValue
                    textSize = PiPTextSize.auto.rawValue
                    speak = false
                    engine.paused = false
                    engine.syncConfig()
                    engine.applyWindowSize()
                    engine.applyStyle()
                }
            }
    }
    private var speedDescription: String {
        switch SpeedPreset(rawValue: speed) ?? .balanced {
        case .fast: "Lowest latency and lighter CPU use; best for fast dialogue."
        case .balanced: "Recommended balance between text detail, responsiveness, and battery."
        case .sharp: "Higher OCR resolution for small subtitles and dense game text; more demanding."
        }
    }
}
