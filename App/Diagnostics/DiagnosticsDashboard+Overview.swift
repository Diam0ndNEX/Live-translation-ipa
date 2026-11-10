import SwiftUI
import Charts

extension DiagnosticsBody {
    /// Only shown when there is evidence: an issue the recorder actually found.
    /// Before any capture it stays neutral: no red without evidence.
    @ViewBuilder private var attentionSection: some View {
        let a = diag.assessment(alive: facts.captureAlive, paused: facts.paused)
        let evidence = facts.captureAlive || diag.s.translations > 0
        if collectionEnabled && !a.issues.isEmpty {
            VStack(alignment: .leading, spacing: KitSpace.tight) {
                Text("Needs attention").font(.headline)
                ForEach(Array(a.issues.prefix(3))) { issue in
                    HStack(alignment: .top, spacing: KitSpace.row) {
                        Image(systemName: !evidence ? "info.circle.fill" : (issue.severity == 2 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"))
                            .foregroundStyle(!evidence ? Color.secondary : (issue.severity == 2 ? Color.red : Color.orange))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title).font(.subheadline.weight(.semibold))
                            Text(issue.detail).font(.footnote).foregroundStyle(.secondary)
                            // 2.2.2: at accessibility sizes the button goes under the text. Beside it, it was squeezed
                            // into a round blob and the title shrank to "Cap-".
                            if typeSize.isAccessibilitySize, let fix = issue.fix {
                                Button(fix.label) { apply(fix) }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.regular)
                                    .padding(.top, KitSpace.unit)
                            }
                        }
                        if !typeSize.isAccessibilitySize {
                            Spacer(minLength: KitSpace.tight)
                            if let fix = issue.fix {
                                Button(fix.label) { apply(fix) }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder var pageBody: some View {
        if !collectionEnabled {
            VStack(alignment: .leading, spacing: KitSpace.row) {
                Text("Diagnostics collection is off. Translation and capture continue.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Turn on") { $collectionEnabled.guardedByActiveRun(diag, pending: $pendingCollection).wrappedValue = true }.buttonStyle(.borderedProminent)
            }
        } else {
            if page.ranged { rangePicker }
            if page.needsDetails && !collectDetails {
                HStack(spacing: KitSpace.row) {
                    Text("Graphs and the event log need Detailed collection.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: KitSpace.tight)
                    Button("Turn on") { $collectDetails.guardedByActiveRun(diag, pending: $pendingCollection).wrappedValue = true }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            pageContent(page)
                .id(page)
                .transition(.opacity.combined(with: .offset(y: 10)))
        }
    }

    /// Everything the old Live page showed: headline, attention, what is read and shown, pipeline, evidence, counters.
    var livePage: some View {
        VStack(alignment: .leading, spacing: KitSpace.group) {
            PhaseHeader(phase: facts.phase, mode: facts.system.shortName)
            OverviewAnswer(diag: diag, captureAlive: facts.captureAlive).kitSurface()
            attentionSection
            LiveFeedSection(active: facts.captureAlive)
            pipelineStrip
            evidenceCard
            sessionGrid
            systemCard
        }
    }

    private var statusLine: String {
        facts.captureAlive
            ? "Capture connected · \(diag.s.translations) translation\(diag.s.translations == 1 ? "" : "s") this session"
            : "Waiting for capture to start"
    }

    /// Delay evidence plus the export button. Counters that explain it are under Advanced.
    private var evidenceCard: some View {
        let delay = Diagnostics.summarize(diag.latency)
        return VStack(alignment: .leading, spacing: KitSpace.row) {
            HStack {
                Text("Test evidence").font(.headline)
                Spacer()
                Text(AppVersion.full).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if delay.n > 0 {
                HStack(alignment: .top, spacing: KitSpace.row) {
                    evidenceNumber("Typical", delay.p50)
                    evidenceNumber("Average", delay.avg)
                    evidenceNumber("Slow tail · P95", delay.p95)
                }
            } else {
                Hint("No complete OCR-to-PiP enqueue samples yet.")
            }
            Hint("Measured from first OCR sighting to PiP buffer enqueue; physical display is not measured. \(delay.n) matched samples.")
            PrimaryButton(title: diag.exportInProgress ? "Preparing evidence ZIP…" : "Export complete diagnostic ZIP",
                          symbol: "archivebox", enabled: !diag.exportInProgress) { Task { await diag.exportZIP() } }
            Hint(diag.archiveStatus)
        }
        .kitSurface()
    }

    private func evidenceNumber(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(Int(value)) ms").font(.title3.weight(.semibold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The counters behind the headline numbers (shown on the Pipeline page).
    var evidenceDetails: some View {
        let stats = diag.s
        let model = Diagnostics.summarize(diag.translate)
        return VStack(alignment: .leading, spacing: KitSpace.tight) {
            Text("Counters").font(.headline)
            LabeledContent("Confirmed candidate packets", value: "\(stats.confirmedCandidatePackets)")
            LabeledContent("Successful PiP candidate enqueues", value: "\(stats.enqueuedCandidateFrames)")
            LabeledContent("Confirmed but superseded before enqueue", value: "\(stats.supersededUnpresentedConfirmed)")
            if stats.supersededUnpresentedConfirmed > 0 {
                LabeledContent("  translation had started", value: "\(stats.supersededConfirmedInFlight)")
                LabeledContent("  translation not started", value: "\(stats.supersededConfirmedNotStarted)")
                let age = diag.confirmedSupersededAges
                if age.n > 0 {
                    Hint("Replaced captions had been confirmed for a median \(Int(age.p50)) ms (P95 \(Int(age.p95)) ms, \(age.n) samples). Cause of the replacement is not measured.")
                }
            }
            LabeledContent("Speculative pipelines discarded", value: "\(stats.specDiscarded)")
            if facts.system == .legacy {
                LabeledContent("Superseded units retained in RAM", value: "\(stats.specRetainedUnits)")
            } else {
                LabeledContent("Speculative model requests", value: "\(stats.specModelRequests)")
                Hint("Strategy-specific session-cache reuse appears in memory counts; Legacy retained-unit accounting does not apply.")
            }
            LabeledContent("Pre-translated sentence hits", value: "\(stats.specHits)")
            if model.n > 0 {
                Hint("Measured model processing: median \(Int(model.p50)) ms · mean \(Int(model.avg)) ms · P95 \(Int(model.p95)) ms (\(model.n) batches).")
            } else if !collectDetails {
                Hint("Model timing charts require Detailed collection. Translation counters remain active in Simple mode.")
            } else if stats.translations > 0 {
                Hint("Translations selected, but no model timings recorded. The captions may have come from memory.")
            } else {
                Hint("No model timing samples yet. Start capture and translate text to collect measurements.")
            }
            Hint("Latency covers successful frame enqueues. Replaced work is excluded, so lower latency alone does not establish better subtitle continuity. Candidates, sentence hits and model requests count different events.")
        }
        .font(.footnote)
        .kitSurface()
    }

    func apply(_ f: Fix) {
        let ud = UserDefaults.standard
        switch f {
        case .fastSpeed: ud.set("fast", forKey: "speed")
        case .instantStability: ud.set(1, forKey: "stability")
        case .immediateDisplay: ud.set("immediate", forKey: "displayPolicy"); engine.timingSettingsChanged()
        case .fixedRotation:
            ud.set("0", forKey: "frameRot")
            engine.rotationSettingChanged()
        case .narrowArea: ud.set("bottom", forKey: "area")
        case .openLanguages: router.openLanguages(); return
        case .startCapture: router.go(.translate); return
        case .translateAhead: ud.set(true, forKey: "translateAhead")
        }
        engine.syncConfig()
        engine.tap()
        engine.toast("Applied: \(f.label)")
    }

    // MARK: Pages
    private var rangePicker: some View {
        Picker("Range", selection: $rangeRaw) {
            ForEach(DiagRange.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
    }
}
