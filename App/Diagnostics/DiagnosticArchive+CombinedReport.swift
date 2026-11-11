import Foundation

/// v2.0.0: one plain-text Markdown report for several saved sessions, so a
/// three-mode test is a single file. Built only from redacted snapshots (the
/// same data as session.json): no subtitle text, OCR text or frames. Caption
/// identities are replaced by per-session sequence numbers.
enum CombinedDiagnosticReport {
    static let maximumSessions = 6

    static func fileName(version: String, build: Int, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let safeVersion = version.filter { $0.isNumber || $0 == "." }
        return "ScreenLingo-Report-\(safeVersion)-b\(build)-\(formatter.string(from: date)).md"
    }

    private static func ms(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return String(format: "%.0f", value)
    }

    /// 2.2.1 (D10): share of persistent-memory lookups that hit the 8 ms deadline, as "n of m (x%)".
    static func memoryTimeoutShare(_ session: DiagnosticSessionExport) -> String {
        let outcomes = ["ramHit", "persistentHit", "legacyHit", "normalizedHit", "speculativeHit", "miss", "timeout",
                        "compatibilityRejected", "databaseUnavailable"]
        let total = outcomes.reduce(0) { $0 + max(0, session.counters[$1, default: 0]) }
        guard total > 0 else { return "–" }
        let timeouts = max(0, session.counters["timeout", default: 0])
        return "\(timeouts) of \(total) (\(Int((Double(timeouts) / Double(total) * 100).rounded()))%)"
    }

    private static func thermalName(_ level: Int) -> String {
        switch level {
        case 0: return "nominal"
        case 1: return "fair"
        case 2: return "serious"
        default: return "critical"
        }
    }

    private static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[sorted.count / 2]
    }

    struct ModelCall {
        let session: String
        let mode: String
        let lane: String
        let strategy: String
        let speculative: Bool
        let startMs: Double
        let endMs: Double
        let serviceMs: Double
        let queueMs: Double?
        let warm: String
        let caption: String
    }

    struct CaptionRow {
        let session: String
        let caption: String
        var firstOCRMs: Double?
        var confirmedMs: Double?
        var selectedMs: Double?
        var pipMs: Double?
        var reason = ""
        var origin = ""
        var strategy = ""
        var recoveryStrategy = ""
    }

    struct DecisionRow {
        let session: String
        let caption: String
        let timeMs: Double
        let reason: String
        let valueMs: Double?
    }

    struct Parsed {
        var calls: [ModelCall] = []
        var captions: [CaptionRow] = []
        var decisions: [DecisionRow] = []
        var fingerprints = Set<String>()
    }

    /// Rebuild model calls, caption timelines and recovery decisions from the
    /// bounded mode trace. Times are milliseconds from the first trace time.
    static func parse(_ report: TranslationModeReport?, label: String) -> Parsed {
        var parsed = Parsed()
        guard let report, !report.events.isEmpty else { return parsed }
        // Stable: events from one synchronous step can share a timestamp.
        let events = report.events.enumerated()
            .sorted { ($0.element.monotonicTime, $0.offset) < ($1.element.monotonicTime, $1.offset) }
            .map { $0.element }
        let origin = events.reduce(Double.infinity) { min($0, $1.monotonicTime, $1.firstOCR) }
        func at(_ time: Double) -> Double { max(0, (time - origin) * 1000) }
        var captionIndex: [String: String] = [:]
        var captionOrder: [String] = []
        var rows: [String: CaptionRow] = [:]
        var requested: [String: String] = [:]
        struct Open { var lane: String; var strategy: String; var submittedMs: Double; var queueMs: Double?; var warm: String }
        var open: [String: [Open]] = [:]
        for event in events {
            parsed.fingerprints.insert(event.fingerprint)
            let ref: String
            if let known = captionIndex[event.caption] { ref = known } else {
                ref = "c\(captionIndex.count + 1)"; captionIndex[event.caption] = ref; captionOrder.append(event.caption)
            }
            let mode = event.mode ?? report.active
            let t = at(event.monotonicTime)
            var row = rows[event.caption] ?? CaptionRow(session: label, caption: ref)
            if row.firstOCRMs == nil { row.firstOCRMs = at(event.firstOCR) }
            let reason = event.reason
            switch reason {
            case "requested_appleDefault": requested[event.caption] = "appleDefault"
            case "requested_lowLatency": requested[event.caption] = "lowLatency"
            case "speculative_model_submitted", "confirmed_model_submitted":
                let lane = reason.hasPrefix("speculative") ? "speculative" : "confirmed"
                open[event.caption, default: []].append(Open(lane: lane,
                    strategy: requested[event.caption] ?? "unknown", submittedMs: t, queueMs: nil, warm: ""))
            case "retained_session_start", "new_session_start":
                if var list = open[event.caption], !list.isEmpty {
                    list[list.count - 1].warm = reason == "retained_session_start" ? "retained" : "new"
                    open[event.caption] = list
                }
            case "speculative_queue_ms", "recovery_queue_ms":
                let lane = reason.hasPrefix("speculative") ? "speculative" : "confirmed"
                if var list = open[event.caption], let index = list.lastIndex(where: { $0.lane == lane }) {
                    list[index].queueMs = event.durationMs
                    open[event.caption] = list
                }
            case "speculative_service_ms", "recovery_service_ms", "confirmed_service_ms":
                let lane = reason.hasPrefix("speculative") ? "speculative" : "confirmed"
                let service = event.durationMs ?? 0
                var call = Open(lane: lane, strategy: requested[event.caption] ?? "unknown",
                                submittedMs: t - service, queueMs: nil, warm: "")
                if var list = open[event.caption], let index = list.firstIndex(where: { $0.lane == lane }) {
                    call = list.remove(at: index)
                    open[event.caption] = list
                }
                parsed.calls.append(ModelCall(session: label, mode: mode, lane: lane, strategy: call.strategy,
                    speculative: lane == "speculative", startMs: max(0, t - service), endMs: t,
                    serviceMs: service, queueMs: call.queueMs, warm: call.warm, caption: ref))
            case "confirmed":
                if row.confirmedMs == nil { row.confirmedMs = t }
            case "recovery_enqueue":
                if row.recoveryStrategy.isEmpty { row.recoveryStrategy = requested[event.caption] ?? "" }
            default:
                if reason.hasPrefix("selected_origin_") {
                    if row.origin.isEmpty { row.origin = String(reason.dropFirst("selected_origin_".count)) }
                } else if reason.hasPrefix("selected_strategy_") {
                    if row.strategy.isEmpty { row.strategy = String(reason.dropFirst("selected_strategy_".count)) }
                } else if reason.hasPrefix("selected_") {
                    if row.selectedMs == nil {
                        row.selectedMs = t; row.reason = String(reason.dropFirst("selected_".count))
                    }
                } else if reason.hasPrefix("pip_enqueue_") {
                    if row.pipMs == nil { row.pipMs = t }
                }
            }
            if reason.hasPrefix("recovery_decision_") {
                parsed.decisions.append(DecisionRow(session: label, caption: ref, timeMs: t,
                                                    reason: reason, valueMs: event.durationMs))
            }
            rows[event.caption] = row
        }
        parsed.captions = captionOrder.compactMap { rows[$0] }
            .filter { $0.confirmedMs != nil || $0.pipMs != nil }
        return parsed
    }

    /// Share of the smaller session's caption fingerprints also seen in the other.
    static func fingerprintOverlap(_ a: Set<String>, _ b: Set<String>) -> Double? {
        let smaller = min(a.count, b.count)
        guard smaller > 0 else { return nil }
        return Double(a.intersection(b).count) / Double(smaller)
    }

    static func markdown(_ sessions: [DiagnosticSessionExport], version: String, build: Int,
                         generatedAt: Date, runs: [RunReportInfo] = []) -> String {
        // 2.5.0: Hybrid Recovery was removed. Its saved runs stay readable in the app, but a report compares only
        // the two current modes, so those runs are left out here and counted in one line.
        let ordered = sessions.sorted { $0.startedAt < $1.startedAt }
        let removedModeRuns = ordered.filter { $0.translationModes?.isRemovedMode == true }.count
        let selected = Array(ordered.filter { $0.translationModes?.isRemovedMode != true }.prefix(maximumSessions))
        let labels = selected.indices.map { "S\($0 + 1)" }
        let parsed = selected.indices.map { parse(selected[$0].translationModes, label: labels[$0]) }
        var out: [String] = []
        out.append("# ScreenLingo test report")
        out.append("")
        out.append("App \(version) build \(build) · generated \(generatedAt.ISO8601Format()) · \(selected.count) session(s)")
        out.append("Boundary: first OCR sighting → PiP enqueue (not physical display). Metadata only: no subtitle, OCR or translated text.")
        if removedModeRuns > 0 {
            out.append("\(removedModeRuns) run(s) of the removed Hybrid Recovery mode were left out of this report.")
        }
        out.append("")
        out.append("## 1. Sessions")
        out.append("")
        out.append("| | mode | started | min | device | iOS | pair | preset | speed | memory | RAM at start | rapid/join/focus | pixel/watch/fast OCR |")
        out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for (i, session) in selected.enumerated() {
            let s = session.settings
            let pair = session.translationModes?.events.first.map { "\($0.source)>\($0.target)" } ??
                "\(s["source"] ?? "?")>\(s["target"] ?? "?")"
            let minutes = max(0, session.endedAt.timeIntervalSince(session.startedAt)) / 60
            let ram = Int(s["startingRAMEntries"] ?? "") ?? 0
            let switches = ["effectiveRapidTextTracking", "effectiveJoinAdjacentText", "effectiveActiveTextFocus"]
                .map { s[$0] ?? "?" }.joined(separator: "/")
            out.append("| \(labels[i]) | \(session.translationModes?.active ?? "unknown") | \(session.startedAt.ISO8601Format()) | \(String(format: "%.1f", minutes)) | \(session.hardwareModel ?? "?") | \(session.systemVersion) | \(pair) | \(s["mode"] ?? "?") | \(s["speed"] ?? "?") | \(s["translationTestMode"] ?? "?") | \(ram)\(ram > 0 ? " ⚠️" : "") | \(switches) | \(s["pixelConfirmation"] ?? "-")/\(s["eventDrivenOCR"] ?? "-")/\(s["fastOCR"] ?? "-") |")
        }
        if !runs.isEmpty {
            // Run facts (v2.0.0 build 84): metadata only, matched to sessions by id.
            func clean(_ text: String) -> String {
                String(text.unicodeScalars.filter { $0.value >= 32 && $0 != "|" }.map(Character.init).prefix(40))
            }
            out.append("")
            out.append("| | test | run label | end reason | completeness | notes |")
            out.append("|---|---|---|---|---|---|")
            for (i, session) in selected.enumerated() {
                guard let run = runs.first(where: { $0.id == session.id }) else { continue }
                var notes: [String] = []
                if run.mixedMode { notes.append("⚠️ mode may be mixed") }
                if !run.trimmed.isEmpty { notes.append("trimmed: " + run.trimmed.map(clean).joined(separator: ", ")) }
                out.append("| \(labels[i]) | \(clean(run.testName)) | \(clean(run.label)) | \(clean(run.endReason)) | \(clean(run.completeness)) | \(notes.joined(separator: "; ")) |")
            }
        }
        if selected.count >= 2 {
            out.append("")
            out.append("Same-content check (share of the smaller session's caption fingerprints seen in the other):")
            for i in selected.indices { for j in selected.indices where j > i {
                let value = fingerprintOverlap(parsed[i].fingerprints, parsed[j].fingerprints)
                out.append("- \(labels[i])–\(labels[j]): \(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")")
            } }
        }
        if selected.contains(where: { (Int($0.settings["startingRAMEntries"] ?? "") ?? 0) > 0 }) {
            out.append("")
            out.append("⚠️ A session started with test memory already filled; its reuse numbers are not comparable.")
        }

        // 2.2.1 (D8): the variables the next A/B tests change, and a warning for sessions with no timing.
        out.append("")
        out.append("| | hot path | detailed | thermal start/end/max | focused/strict | identical-frame holds | manual | memory wait P50/P95 | health P50/P95 | memory timeouts | switches on |")
        out.append("|---|---|---|---|---|---|---|---|---|---|---|")
        for (i, session) in selected.enumerated() {
            let s = session.settings
            // 2.3.0: these keys are written only when ON, so a missing key means OFF. Names the 2.2.3 switches that were on.
            let armsOn = [("legacyOwnLaneAB", "Legacy own lane"), ("availabilityRefreshAB", "background language check"),
                          ("heartbeatAB", "independent capture heartbeat"), ("armedDeferAB", "deferred early start")]
                .filter { s[$0.0] == "on" }.map { $0.1 }
            // 2.5.0: items A to F and the quiet re-warm (default on; a run saved before 2.5.0 has none).
            let v250On = TranslationHotPathAB.v250ReportLabels.filter { s[$0.key] == "on" }.map { $0.label }
            let armsText = (armsOn + v250On).isEmpty ? "none" : (armsOn + v250On).joined(separator: ", ")
            out.append("| \(labels[i]) | \(s["hotPathAB"] ?? "?") | \(s["detailedCollection"] ?? "?")\(s["detailSuspended"] == "true" ? " (suspended: thermal)" : "") | \(s["thermalStart"] ?? "?")/\(s["thermalEnd"] ?? "?")/\(s["thermalMax"] ?? "?") | \(s["focusedCaptionOCR"] ?? "?")/\(s["strictCaptionIdentity"] ?? "?") | \(session.counters["identicalFrameHolds", default: 0]) | \(session.counters["manualTranslations", default: 0]) | \(ms(session.distributions["memoryLookupWaitMs"]?.p50))/\(ms(session.distributions["memoryLookupWaitMs"]?.p95)) | \(ms(session.distributions["memoryHealthMs"]?.p50))/\(ms(session.distributions["memoryHealthMs"]?.p95)) | \(memoryTimeoutShare(session)) | \(armsText) |")
        }
        for (i, session) in selected.enumerated() where (session.distributions["enqueueLatencyMs"]?.count ?? 0) == 0 {
            out.append("")
            out.append("⚠️ \(labels[i]) has n = 0: no latency samples (Detailed collection was off or no caption was enqueued). Its row in the comparison is empty, not fast.")
        }

        out.append("")
        out.append("## 2. Comparison (ms)")
        out.append("")
        out.append("| | mode | thermal seen | n | P50 | P90 | P95 | P99 | max | OCR P50 | confirm P50 | conf. model P50 | spec. model P50 | mem hits | misses | PiP fails |")
        out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for (i, session) in selected.enumerated() {
            let d = session.distributions
            let e = d["enqueueLatencyMs"]
            let thermal = Set((session.intervals ?? []).map { $0.thermalLevel }).sorted().map(thermalName).joined(separator: "+")
            let c = session.counters
            out.append("| \(labels[i]) | \(session.translationModes?.active ?? "unknown") | \(thermal.isEmpty ? "?" : thermal) | \(e?.count ?? 0) | \(ms(e?.p50)) | \(ms(e?.p90)) | \(ms(e?.p95)) | \(ms(e?.p99)) | \(ms(e?.maximum)) | \(ms(d["ocrMs"]?.p50)) | \(ms(d["confirmationMs"]?.p50)) | \(ms(d["confirmedModelMs"]?.p50)) | \(ms(d["speculativeModelMs"]?.p50)) | \(c["sessionCacheHits", default: 0] + c["savedMemoryHits", default: 0]) | \(c["uncachedUnits", default: 0]) | \(c["enqueueFailed", default: 0]) |")
        }
        out.append("")
        out.append("Model service median by lane and strategy (from the retained trace):")
        out.append("")
        out.append("| | lane | strategy | n | median | max |")
        out.append("|---|---|---|---|---|---|")
        for i in selected.indices {
            let groups = Dictionary(grouping: parsed[i].calls) { "\($0.lane)|\($0.strategy)" }
            for key in groups.keys.sorted() {
                let calls = groups[key] ?? []
                let parts = key.split(separator: "|").map(String.init)
                out.append("| \(labels[i]) | \(parts.first ?? "") | \(parts.last ?? "") | \(calls.count) | \(ms(median(calls.map { $0.serviceMs }))) | \(ms(calls.map { $0.serviceMs }.max())) |")
            }
        }

        // 2.4.0 and 2.5.0: what the switches did and what a confirmation needed. Counts are whole-session totals.
        func pair(_ d: [String: DiagnosticDistribution], _ name: String) -> String { "\(ms(d[name]?.p50))/\(ms(d[name]?.p95))" }
        func timed(_ d: [String: DiagnosticDistribution], _ name: String) -> String {
            guard let v = d[name], v.count > 0 else { return "0" }
            return "\(v.count) (\(ms(v.p50)) ms)"
        }
        out.append("")
        out.append("Paths and capture (counts; reads and waits as P50/P95):")
        out.append("")
        out.append("| | early starts deferred | focused reads repeated | trusted band reads | confirmations with a pixel rejection | OCR reads per confirmation | frame wait after OCR ms | overlap of confirmed Legacy calls ms |")
        out.append("|---|---|---|---|---|---|---|---|")
        for (i, session) in selected.enumerated() {
            let m = session.translationModes?.counters ?? [:]
            let c = session.counters
            let d = session.distributions
            out.append("| \(labels[i]) | \(m["session_speculation_deferred_armed", default: 0]) | \(c["focusRediscoveries", default: 0]) | \(c["trustedBandReads", default: 0]) | \(c["confirmedWithPixelRejection", default: 0]) | \(pair(d, "confirmationOCRReads")) | \(pair(d, "confirmationFrameWaitMs")) | \(pair(d, "legacyConfirmedOverlapMs")) |")
        }
        out.append("")
        out.append("Warm-up and Legacy head start (2.5.0; warm-ups as count and median ms):")
        out.append("")
        out.append("| | warm-ups at capture start | quiet re-warms | fast passes | fast pass P50/P95 ms | head starts sent | fast pass right | fast pass wrong |")
        out.append("|---|---|---|---|---|---|---|---|")
        for (i, session) in selected.enumerated() {
            let c = session.counters
            let d = session.distributions
            out.append("| \(labels[i]) | \(timed(d, "captureStartWarmupMs")) | \(timed(d, "quietRewarmMs")) | \(c["headStartPrePasses", default: 0]) | \(pair(d, "headStartPrePassMs")) | \(c["headStartSent", default: 0]) | \(c["headStartConfirmed", default: 0]) | \(c["headStartMissed", default: 0]) |")
        }
        out.append("")
        out.append("Why a confirmation needed another OCR read (2.5.0; whole-session counts):")
        out.append("")
        out.append("| | " + V250Names.extraReadLabels.joined(separator: " | ") + " |")
        out.append("|---|" + V250Names.extraReadLabels.map { _ in "---|" }.joined())
        for (i, session) in selected.enumerated() {
            let c = session.counters
            out.append("| \(labels[i]) | " + V250Names.extraReadCounters.map { String(c[$0, default: 0]) }.joined(separator: " | ") + " |")
        }
        out.append("")
        out.append("Model call ms by characters translated (2.5.0; n, P50/P95):")
        out.append("")
        out.append("| | " + ModelLengthBucket.allCases.map { $0.label }.joined(separator: " | ") + " |")
        out.append("|---|" + ModelLengthBucket.allCases.map { _ in "---|" }.joined())
        for (i, session) in selected.enumerated() {
            let d = session.distributions
            let cells = ModelLengthBucket.allCases.map { bucket -> String in
                guard let v = d[bucket.metric], v.count > 0 else { return "–" }
                return "\(v.count): \(ms(v.p50))/\(ms(v.p95))"
            }
            out.append("| \(labels[i]) | " + cells.joined(separator: " | ") + " |")
        }
        out.append("")
        out.append("Reading notes: confirmationMs runs from the start of the caption's first OCR read to its confirmation, so it contains that read (finalOCRMs); the two are not added. An early (speculative) call is one started for a first sighting; sections 4 and 5 show when it started relative to confirmed_ms.")

        out.append("")
        out.append("## 3. Stage timings per session (ms)")
        for (i, session) in selected.enumerated() {
            out.append("")
            out.append("### \(labels[i]) · \(session.translationModes?.active ?? "unknown")")
            out.append("")
            out.append("| stage | n | mean | P50 | P90 | P95 | P99 | max |")
            out.append("|---|---|---|---|---|---|---|---|")
            var all = session.distributions
            for (name, value) in session.translationModes?.distributions ?? [:] { all["mode_" + name] = value }
            for name in all.keys.sorted() {
                guard let v = all[name], v.count > 0 else { continue }
                out.append("| \(name) | \(v.count) | \(ms(v.mean)) | \(ms(v.p50)) | \(ms(v.p90)) | \(ms(v.p95)) | \(ms(v.p99)) | \(ms(v.maximum)) |")
            }
        }

        out.append("")
        out.append("## 4. Model calls")
        out.append("")
        out.append("Times in ms from the session's first trace event. Start = end − service.")
        out.append("")
        out.append("```csv")
        out.append("session,mode,lane,strategy,speculative,start_ms,end_ms,service_ms,queue_ms,warm,caption_ref")
        for call in parsed.flatMap({ $0.calls }) {
            out.append("\(call.session),\(call.mode),\(call.lane),\(call.strategy),\(call.speculative ? 1 : 0),\(ms(call.startMs)),\(ms(call.endMs)),\(ms(call.serviceMs)),\(call.queueMs.map { ms($0) } ?? ""),\(call.warm),\(call.caption)")
        }
        out.append("```")

        out.append("")
        out.append("## 5. Captions")
        out.append("")
        out.append("```csv")
        out.append("session,caption_ref,first_ocr_ms,confirmed_ms,selected_ms,pip_ms,ocr_to_pip_ms,reason,origin,strategy,recovery_strategy")
        for row in parsed.flatMap({ $0.captions }) {
            let total: String
            if let pip = row.pipMs, let first = row.firstOCRMs { total = ms(pip - first) } else { total = "" }
            out.append("\(row.session),\(row.caption),\(row.firstOCRMs.map { ms($0) } ?? ""),\(row.confirmedMs.map { ms($0) } ?? ""),\(row.selectedMs.map { ms($0) } ?? ""),\(row.pipMs.map { ms($0) } ?? ""),\(total),\(row.reason),\(row.origin),\(row.strategy),\(row.recoveryStrategy)")
        }
        out.append("```")

        out.append("")
        out.append("## 6. Recovery decisions")
        out.append("")
        out.append("```csv")
        out.append("session,caption_ref,t_ms,reason,value_ms")
        for row in parsed.flatMap({ $0.decisions }) {
            out.append("\(row.session),\(row.caption),\(ms(row.timeMs)),\(row.reason),\(row.valueMs.map { ms($0) } ?? "")")
        }
        out.append("```")

        out.append("")
        out.append("## 7. Findings")
        for (i, session) in selected.enumerated() {
            let findings = DiagnosticIssueDetector.assess(session)
            out.append("")
            out.append("**\(labels[i])**" + (findings.isEmpty ? ": none from current heuristics." : ""))
            for finding in findings {
                out.append("- [\(finding.classification)] \(finding.code) ×\(finding.occurrences): \(finding.explanation)")
            }
        }

        out.append("")
        out.append("## 8. Truncation")
        out.append("")
        for (i, session) in selected.enumerated() {
            let retained = session.translationModes?.events.count ?? 0
            let overwritten = session.translationModes?.counters["session_mode_trace_ring_overwritten"] ?? 0
            out.append("- \(labels[i]): \(retained) mode events retained\(retained >= 6000 ? " (6,000 cap reached; early events missing)" : ""), \(overwritten) overwritten; \(session.events.count) structured events retained. Whole-session counters are not truncated.")
            // 2.2.1 (D6): what the bounded buffers dropped, so a short event list is never mistaken for a quiet run.
            let c = session.counters
            out.append("  - dropped: \(c["structured_events_dropped", default: 0]) structured events, \(c["id_map_resets", default: 0]) correlation-ID map resets, \(c["legacy_context_resets", default: 0]) Legacy context resets, \(c["subtitle_traces_dropped", default: 0]) subtitle traces.")
        }
        out.append("")
        return out.joined(separator: "\n")
    }
}
