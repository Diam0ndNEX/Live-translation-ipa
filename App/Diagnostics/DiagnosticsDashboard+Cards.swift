import SwiftUI
import Charts

extension DiagnosticsBody {
    func eventListCard(limit: Int) -> some View {
        let all = Array(diag.events.reversed())
        let shown = all.filter { e in
            (kinds.isEmpty || kinds.contains(e.kind))
                && (query.isEmpty || e.text.localizedCaseInsensitiveContains(query)
                    || (e.detail ?? "").localizedCaseInsensitiveContains(query))
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What happened").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(shown.count) event\(shown.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            kindChips
            if shown.isEmpty {
                Text("Nothing matches.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(shown.prefix(limit))) { e in eventRow(e) }
        }
        .kitSurface()
    }

    // MARK: Pipeline
    var subtitleLifecycleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Per-subtitle timeline").font(.headline)
            if diag.subtitleTraces.isEmpty { Text("Waiting for tracked candidates. Enable Detailed diagnostics and subtitle tracking.").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(diag.subtitleTraces.suffix(18))) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(String(item.candidate.suffix(12))) · \(item.stage) · \(item.time.formatted(date: .omitted, time: .standard))").font(.caption.monospaced())
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Times measure app processing and frame enqueue, not physical screen presentation. Full bounded timeline is in CSV.").font(.caption).foregroundStyle(.secondary)
        }.kitSurface()
    }

    var adaptivePipelineCard: some View {
        let s = diag.s
        return VStack(alignment: .leading, spacing: 10) {
            Text("Recognition & work accounting").font(.headline)
            Text("OCR: \(Int(s.ocrConfidence*100))% · Source: \(s.sourceOrigin == "Selected" ? "selected" : "\(Int(s.languageConfidence*100))% confidence")").font(.footnote)
            Text(s.languageContextUsed ? "Recent source context assisted this ambiguous reading" : "Source evidence uses the current reading").font(.caption).foregroundStyle(.secondary)
            Text("\(s.recognitionReason) · \(s.confirmationReason)").font(.caption).foregroundStyle(.secondary)
            Text("Cache sentences · session \(s.cacheHits) · saved \(s.savedHits) · pre-translated \(s.specHits)").font(.footnote)
            Text("Speculative jobs · admitted \(s.specStarted) · ready \(s.specCompleted) · failed \(s.specDiscarded) · declined \(s.specSkipped)").font(.footnote)
            if facts.system == .legacy {
                Text("Spec throttled \(s.adaptiveSpeculationSkipped) · confirmed handoffs \(s.confirmedHandoffDeferred) · slow tails \(s.slowTailEnqueues)").font(.footnote)
                Text("Legacy declines · low confidence \(s.legacyLowConfidenceSkips) · low yield \(s.legacyAdaptiveLowYieldSkips) · saved memory \(s.legacyAdaptiveSavedSkips) · model busy \(s.legacyBusySpeculationSkips) · duplicate \(s.legacyDuplicateSpeculationSkips)").font(.caption).foregroundStyle(.secondary)
                Text("Discarded work: \(Int(s.specDiscardedMs)) ms · unconsumed cached results: \(facts.unconsumedSpeculation).").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Actual speculative model requests: \(s.specModelRequests) · slow enqueues: \(s.slowTailEnqueues)").font(.footnote)
                Text("Low Latency early translations and confirmed recoveries have separate model lanes. A cache-only result is not counted as model execution. Captions may reuse completed obsolete work.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Skipped frames · unchanged \(s.unchangedSkipped) · cadence \(s.cadenceSkipped) · paused \(s.pausedSkipped)").font(.caption)
            Text("Early OCR visual-change wakes: \(s.earlyVisualWakes) · derived from visual motion only, not confirmed text.").font(.caption).foregroundStyle(.secondary)
            Text("Capture packets over 8 KB: \(s.largePackets) · failed sends: \(s.packetSendErrors)").font(.caption).foregroundStyle(.secondary)
            Text("Pixel-verified confirmations: \(s.pixelConfirmations) · fell back to OCR: \(s.pixelRejections) · OCR skipped while caption unchanged: \(s.watchSkippedOCR) · OCR started on caption change: \(s.watchTriggeredOCR)").font(.caption).foregroundStyle(.secondary)
            Text("Recorder self-time · simple \(String(format: "%.1f", diag.recorderCosts.simpleMs)) ms · detailed \(String(format: "%.1f", diag.recorderCosts.detailedMs)) ms. Excludes chart drawing and model work; these are different workloads.").font(.caption).foregroundStyle(.secondary)
        }.kitSurface()
    }

    var pipelinePage: some View {
        let s = diag.s
        let inArea = Swift.max(0, s.linesIn - s.dropArea)
        let afterRules = Swift.max(0, inArea - s.dropSmall - s.dropIgnore)
        let notOwn = Swift.max(0, afterRules - s.dropSelf)
        let needs = Swift.max(0, notOwn - s.dropTarget)
        let lines = [
            BarRow(name: "Lines read", value: s.linesIn),
            BarRow(name: "In the OCR area", value: inArea),
            BarRow(name: "Big enough & allowed", value: afterRules),
            BarRow(name: "Not our own window", value: notOwn),
            BarRow(name: "Need translating", value: needs)
        ]
        let realBlocks = Swift.max(0, s.blocksKept - s.dropNoise - s.dropLanguage)
        let blocks = [
            BarRow(name: "Text blocks found", value: s.blocksIn),
            BarRow(name: "Blocks kept", value: s.blocksKept),
            BarRow(name: "Real text", value: realBlocks),
            BarRow(name: "Sentences translated", value: s.sentences)
        ]
        let parts = [
            DonutPart(name: "Translated", value: needs, color: Color.green),
            DonutPart(name: "Outside area", value: s.dropArea, color: Color.gray),
            DonutPart(name: "Too small", value: s.dropSmall, color: Color.yellow),
            DonutPart(name: "Ignore list", value: s.dropIgnore, color: Color.orange),
            DonutPart(name: "Own window", value: s.dropSelf, color: Color.pink),
            DonutPart(name: "Already target", value: s.dropTarget, color: Color.blue)
        ]
        return VStack(spacing: 14) {
            BarListCard(title: "Where lines go", rows: lines, color: Color.blue)
            DonutCard(title: "What happens to every line", parts: parts)
            BarListCard(title: "Blocks and sentences", rows: blocks, color: Color.purple)
            LineCard(title: "Lines per read", samples: Array(diag.lineCounts.suffix(120)), color: Color.mint, unit: "lines")
            VStack(alignment: .leading, spacing: 8) {
                Text("Details").font(.subheadline.weight(.semibold))
                LabeledContent("Numbers / noise dropped", value: "\(s.dropNoise)")
                LabeledContent("Other-language blocks dropped", value: "\(s.dropLanguage)")
                LabeledContent("Floating window position", value: s.pipRegion)
                LabeledContent("Unchanged frames skipped", value: "\(s.skippedFrames)")
            }
            .font(.footnote)
            .kitSurface()
            if diag.detailedCollection {
                candidateTraceCard
            }
        }
    }

    /// Unlike a plain timeline, this groups all observed stages by the same
    /// privacy-safe candidate identity. Missing stages are never synthesized.
    private var candidateTraceCard: some View {
        let candidates = DiagnosticTraceReview.review(diag.structuredEvents, limit: 12)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Translation decision traces").font(.subheadline.weight(.semibold))
            Text("Correlated metadata from this session. An absent stage was not necessarily executed or skipped; PiP timings end at buffer enqueue.")
                .font(.caption).foregroundStyle(.secondary)
            if candidates.isEmpty {
                Text("No correlated events yet. Enable detailed collection and translate a subtitle.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { candidate in
                    DisclosureGroup("Candidate \(candidate.id.uuidString.prefix(8)) · \(candidate.stages.count) events") {
                        Text(candidate.status)
                            .font(.caption.weight(.medium))
                        LabeledContent("Observed frames", value: String(candidate.frameCount))
                        ForEach(candidate.stages) { stage in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stage.stage.replacingOccurrences(of: "_", with: " "))
                                        .font(.caption.weight(.medium))
                                    Text(stage.reason.replacingOccurrences(of: "_", with: " "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let ms = stage.durationMs {
                                    Text(String(format: "%.2f ms", ms))
                                        .font(.caption.monospacedDigit())
                                }
                            }
                        }
                    }
                    .font(.footnote)
                }
            }
        }
        .kitSurface()
    }

    // MARK: Language
    var languagePage: some View {
        let s = diag.s
        let counts = diag.sourceUsage.counts.sorted { $0.value > $1.value }.prefix(8).map { BarRow(name: $0.key.uppercased(), value: $0.value) }
        let pair: String = facts.sourceCode == "auto" ? "Auto"
            : (facts.sourceReady ? "Ready" : "Needs pack")
        let cache = [
            DonutPart(name: "Session cache", value: s.cacheHits, color: Color.green),
            DonutPart(name: "Pre-translated", value: s.specHits, color: Color.cyan),
            DonutPart(name: "Saved memory", value: s.savedHits, color: Color.purple),
            DonutPart(name: "Translated fresh", value: s.cacheMisses, color: Color.orange)
        ]
        return VStack(spacing: 14) {
            VStack(spacing: 0) {
                StatTile(title: "Source used", value: s.sourceUsed == "–" ? "–" : s.sourceUsed.uppercased(), icon: "sparkle.magnifyingglass")
                StatTile(title: "Locked to", value: s.lockedLang == "–" ? "none" : s.lockedLang.uppercased(), tint: Color.purple, icon: "lock")
                StatTile(title: "Language pack", value: pair, tint: pair == "Needs pack" ? Color.orange : Color.green, icon: "arrow.down.circle")
                StatTile(title: "Engine", value: facts.system == .legacy
                         ? (s.sessionKind == "–" ? "Default" : (s.sessionKind.contains("iOS 26") ? "Direct" : "Hosted"))
                         : facts.system.shortName, icon: "cpu")
            }
            .kitSurface()
            VStack(alignment: .leading, spacing: 6) {
                Text(facts.sourceCode == "auto" ? "Source: Automatic" : "Source: \(facts.sourceCode.uppercased()) selected")
                    .font(.subheadline.weight(.semibold))
                Text(facts.sourceCode == "auto" ? "With language lock enabled, four confident matching detections within six qualifying readings lock the source. Clear language changes translate immediately; three mismatches release the lock. The target language is never locked." : "Automatic detection is off. Selected-language inputs still count in the graph.")
                    .font(.caption).foregroundStyle(.secondary)
            }.kitSurface()
            BarListCard(title: "Source languages used · session", rows: Array(counts), color: Color.purple)
            BarListCard(title: "How the source was chosen", rows: SourceLanguageOrigin.allCases.map {
                BarRow(name: $0.title, value: diag.sourceUsage.origins[$0, default: 0])
            }, color: Color.teal)
            DonutCard(title: "Where translations come from", parts: cache)
            LineCard(title: "Cache hit rate over time", samples: slice(diag.cacheRate), color: Color.green, unit: "%")
            VStack(alignment: .leading, spacing: 10) {
                Text("Recognized speaker labels · session").font(.subheadline.weight(.semibold))
                Text("This session list is local and clears on reset or app restart. Exporting names still requires text-sharing consent.").font(.caption).foregroundStyle(.secondary)
                if diag.names.isEmpty {
                    Text("Private sessions hide names. Otherwise, enable speaker recognition and session speaker labels; names appear for visible text such as \"Name: line\". Voices and unlabeled people are not identified.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(diag.names, id: \.self) { n in
                            Text(n).font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.25), in: Capsule())
                        }
                    }
                }
            }
            .kitSurface()
        }
    }

    // MARK: Device
    private var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot (throttling)"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
    private var thermalColor: Color {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: Color.green
        case .fair: Color.yellow
        case .serious: Color.orange
        case .critical: Color.red
        @unknown default: Color.gray
        }
    }

    private var thermalCard: some View {
        let data = slice(diag.thermal)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Phone temperature").font(.subheadline.weight(.semibold))
                Spacer()
                Text(thermalName).font(.subheadline.weight(.bold)).foregroundStyle(thermalColor)
            }
            Text("App performance: " + ThermalPerformancePolicy.tier(for: ProcessInfo.processInfo.thermalState).rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Reduction reasons: " + diag.captureReductionReasons.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
            if data.count < 2 {
                Text(data.isEmpty ? "No thermal samples in this range. Detailed collection is required." :
                     "One thermal sample recorded. The second sample will establish a trend.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart(data) { s in
                    AreaMark(x: .value("Time", s.t), y: .value("Level", s.v))
                        .foregroundStyle(Color.orange.opacity(0.35))
                        .interpolationMethod(.stepEnd)
                    LineMark(x: .value("Time", s.t), y: .value("Level", s.v))
                        .foregroundStyle(Color.orange)
                        .interpolationMethod(.stepEnd)
                }
                .chartYScale(domain: 0.0...3.0)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0.0, 1.0, 2.0, 3.0]) { v in
                        AxisGridLine()
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(["Normal", "Warm", "Hot", "Critical"][Swift.min(3, Swift.max(0, Int(d)))])
                                    .font(.caption)
                            }
                        }
                    }
                }
                .frame(height: 110)
            }
        }
        .kitSurface()
    }

    var devicePage: some View {
        let s = diag.s
        let b = UIDevice.current.batteryLevel
        return VStack(spacing: 14) {
            LineCard(title: "Extension memory headroom", samples: slice(diag.extMem), color: Color.teal, unit: "MB", rule: 15)
            LineCard(title: "Main app memory headroom", samples: slice(diag.appMem), color: Color.indigo, unit: "MB")
            thermalCard
            LineCard(title: "Battery", samples: slice(diag.battery), color: Color.green, unit: "%")
            VStack(alignment: .leading, spacing: 8) {
                Text("Details").font(.subheadline.weight(.semibold))
                LabeledContent("Capture extension", value: facts.extensionVersion == "–" ? "not seen yet" : "v\(facts.extensionVersion)")
                LabeledContent("Frame size", value: s.bufferSize)
                LabeledContent("Orientation from iOS", value: s.orientation)
                LabeledContent("Read area size", value: s.cropSize)
                LabeledContent("Rotation applied", value: "\(s.rotation * 90)°")
                LabeledContent("Lowest extension headroom", value: s.minExtFreeMB > 9000 ? "–" : "\(Int(s.minExtFreeMB)) MB")
                LabeledContent("Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
                LabeledContent("Battery now", value: b < 0 ? "–" : "\(Int(b * 100))%")
            }
            .font(.footnote)
            .kitSurface()
        }
    }

    // MARK: Log
    var logPage: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search the log", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            .padding(12)
            .background(KitColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            eventListCard(limit: 400)
        }
    }
}
