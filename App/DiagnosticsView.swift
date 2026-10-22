// ScreenLingo – Live pipeline diagnostics
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @AppStorage("includeDiagnosticText") private var includeDiagnosticText = true
    @State private var compactReport = true
    @State private var showClearConfirmation = false

    private func metric(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Live status") {
                    metric("Capture", engine.captureAlive ? "Connected" : "Disconnected")
                    metric("Pipeline", engine.capturePhase)
                    metric("UDP listener", engine.serverReady ? "Ready" : "Unavailable")
                    metric("Picture-in-Picture", engine.pipActive ? "Active" : "Inactive")
                    metric("Capture extension", engine.extensionVersion)
                    metric("Last packet", engine.lastPacketKind)
                    metric("Packet age", engine.lastPacketAge < 0 ? "Never" : String(format: "%.2f s", engine.lastPacketAge))
                    Text(engine.status).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Capture and translation") {
                    metric("Packets: all / ping / OCR / clear", "\(engine.totalPackets) / \(engine.pingPackets) / \(engine.ocrPackets) / \(engine.clearPackets)")
                    metric("Frames", "\(engine.frames)")
                    metric("OCR passes / raw lines", "\(engine.ocrCount) / \(engine.lastOCRLineCount)")
                    metric("OCR latency", String(format: "%.1f ms", engine.ocrMs))
                    metric("Translation latency", String(format: "%.1f ms", engine.translateMs))
                    metric("Extension free memory", String(format: "%.1f MB", engine.extFreeMB))
                    metric("Selected blocks", "\(engine.selectedBlockCount)")
                    metric("Filter summary", engine.lastFilterSummary)
                    metric("Accepted / stabilized", "\(engine.acceptedInputCount) / \(engine.stabilizationWaitCount)")
                    metric("Stale results discarded", "\(engine.discardedStaleCount)")
                    metric("Cache hits / failures", "\(engine.cacheHits) / \(engine.translationFailures)")
                    metric("Output quality", engine.lastOutputQuality)
                    metric("Last translation error", engine.lastTranslationError)
                }
                Section("Current text path") {
                    DisclosureGroup("Raw OCR") {
                        Text(engine.lastRaw.isEmpty ? "No OCR received yet." : engine.lastRaw)
                            .font(.footnote).textSelection(.enabled)
                    }
                    DisclosureGroup("Candidate text") {
                        Text(engine.lastCandidateText.isEmpty ? "No candidate yet." : engine.lastCandidateText)
                            .font(.footnote).textSelection(.enabled)
                    }
                    DisclosureGroup("Selected blocks") {
                        Text(engine.lastSelectedBlocks.isEmpty ? "No selected blocks." : engine.lastSelectedBlocks)
                            .font(.footnote).textSelection(.enabled)
                    }
                    DisclosureGroup("Translation input") {
                        Text(engine.lastTranslationInput.isEmpty ? "No translation input yet." : engine.lastTranslationInput)
                            .font(.footnote).textSelection(.enabled)
                    }
                    DisclosureGroup("Last translation output") {
                        Text(engine.translated.isEmpty ? "No translation output yet." : engine.translated)
                            .font(.footnote).textSelection(.enabled)
                    }
                }
                Section("Diagnostic export") {
                    Toggle("Include recognized text (privacy-sensitive)", isOn: $includeDiagnosticText)
                    Toggle("Compact rolling report (60 seconds)", isOn: $compactReport)
                    ShareLink(item: engine.copyDetailedDiagnosticReport(includeRecognizedText: includeDiagnosticText, compact: compactReport)) {
                        Label("Share diagnostic report", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) { showClearConfirmation = true } label: {
                        Label("Clear diagnostic history", systemImage: "trash")
                    }
                }
                Section("Recent events") {
                    if engine.diagnosticEvents.isEmpty {
                        Text("No diagnostic events yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(engine.diagnosticEvents.suffix(60).enumerated()), id: \.offset) { _, event in
                            Text(event).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                Section("Processing trace") {
                    if engine.processingTrace.isEmpty {
                        Text("No OCR processing trace yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(engine.processingTrace.suffix(100).enumerated()), id: \.offset) { _, event in
                            Text(event).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Diagnostics")
            .confirmationDialog("Clear diagnostic history?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
                Button("Clear diagnostics", role: .destructive) { engine.clearDiagnosticEvents() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears event and processing traces, not your translation history.")
            }
        }
    }
}
