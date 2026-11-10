import Foundation

extension DiagnosticExportWriter {
    /// Compact (not pretty-printed) JSON of an already redacted snapshot, for Test Run files.
    nonisolated func encodeCompact(_ snapshot: DiagnosticSessionExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }
    nonisolated func decodeCompact(_ data: Data) throws -> DiagnosticSessionExport {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticSessionExport.self, from: data)
    }
    func encode(_ snapshot: DiagnosticSessionExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let safeSnapshot = redact(snapshot)
        let data = try encoder.encode(safeSnapshot)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticSessionExport.self, from: data)
        guard decoded.id == safeSnapshot.id, decoded.events.count == safeSnapshot.events.count else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
    func export(_ snapshot: DiagnosticSessionExport) throws -> URL {
        let data = try encode(snapshot)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screenlingo-diagnostics-\(UUID().uuidString).json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        return url
    }
    /// Export only metadata-only events with a bounded indexed retention window.
    /// This runs on the archive actor, outside the live OCR and PiP pipeline.
    func encodeIndexedEvents(_ input: [StructuredDiagnosticEvent])
        throws -> [(timestamp: Double, payload: Data)] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var output: [(timestamp: Double, payload: Data)] = []
        var byteCount = 0
        for event in input.suffix(128) where event.privacy == "metadataOnly" {
            let wrapper = DiagnosticSessionExport(id: event.sessionID,
                startedAt: event.timestamp, endedAt: event.timestamp,
                appVersion: "", systemVersion: "", settings: [:],
                health: MemoryDiagnosticHealth(), counters: [:], distributions: [:],
                events: [event], measurementBoundary: "", textCapture: false)
            guard let safeEvent = redact(wrapper).events.first else { continue }
            let encoded = try encoder.encode(safeEvent)
            // Selected events must fit a strict, predictable SQLite budget.
            guard encoded.count <= 4096 else { continue }
            if byteCount + encoded.count > 512 * 1024 { break }
            byteCount += encoded.count
            output.append((timestamp: event.timestamp.timeIntervalSince1970,
                           payload: encoded))
        }
        return output
    }

    /// Portable, versioned diagnostic evidence bundle. All derived files use
    /// ONLY the same redacted snapshot as session.json.
    func exportZIP(_ snapshot: DiagnosticSessionExport) throws -> URL {
        let sessionData = try encode(snapshot)
        // Keep full in-memory Date precision for the per-event CSV. The legacy
        // JSON encoder deliberately retains its older date encoding for readers.
        let safe = redact(snapshot)
        let counterNames = DiagnosticIntervalBucket.allowedCounters.sorted()
        let header = "start_time,elapsed_seconds,thermal_level,low_power,capture_connected,effective_ocr_interval_ms,visual_motion_proxy_ms,ocr_median_ms,ocr_p95_ms,translation_median_ms,translation_p95_ms,enqueue_median_ms,enqueue_p95_ms,model_batch_median_ms," +
            counterNames.joined(separator: ",")
        func intervalCSV(_ intervals: [DiagnosticIntervalBucket]) -> Data {
            let rows = intervals.map { interval -> String in
                var columns: [String] = [
                    String(Int(interval.startedAt.timeIntervalSince1970)),
                    String(interval.elapsedSeconds),
                    String(interval.thermalLevel),
                    interval.lowPower ? "1" : "0",
                    interval.captureConnected ? "1" : "0"
                ]
                let timings: [Double?] = [
                    interval.effectiveOCRIntervalMs, interval.visualChangeProxyMs,
                    interval.ocrMedianMs, interval.ocrP95Ms,
                    interval.translationMedianMs, interval.translationP95Ms,
                    interval.enqueueMedianMs, interval.enqueueP95Ms,
                    interval.modelBatchMedianMs
                ]
                columns.append(contentsOf: timings.map { $0.map { String($0) } ?? "" })
                columns.append(contentsOf: counterNames.map { String(interval.counters[$0, default: 0]) })
                return columns.joined(separator: ",")
            }
            return Data(([header] + rows).joined(separator: "\n").utf8)
        }
        let intervalsCSV = intervalCSV(safe.intervals ?? [])
        let secondsOneCSV = intervalCSV(safe.oneSecondIntervals ?? [])
        let secondsFiveCSV = intervalCSV(safe.fiveSecondIntervals ?? [])

        // Flat, machine-readable timing distributions for spreadsheet-based A/B
        // checks. No source text or full raw screen content is included.
        let metricsHeader = "metric,samples,mean_ms,p50_ms,p90_ms,p95_ms,p99_ms,max_ms"
        var allDistributions = safe.distributions
        for (name, value) in safe.translationModes?.distributions ?? [:] { allDistributions["mode_" + name] = value }
        let metricsRows = allDistributions.keys.sorted().compactMap { name -> String? in
            guard let value = allDistributions[name] else { return nil }
            let cells: [String] = [
                name, String(value.count), String(value.mean),
                value.p50.map { String($0) } ?? "",
                value.p90.map { String($0) } ?? "",
                value.p95.map { String($0) } ?? "",
                value.p99.map { String($0) } ?? "",
                value.maximum.map { String($0) } ?? ""
            ]
            return cells.joined(separator: ",")
        }
        let metricsCSV = Data(([metricsHeader] + metricsRows).joined(separator: "\n").utf8)

        // An event timeline with opaque IDs allows joining a candidate across
        // OCR, translation and enqueue stages; the keys never expose OCR text.
        let eventsHeader = "timestamp_utc,timestamp_unix_ms,session_id,candidate_id,frame_id,unit_id,stage,outcome,reason_code,duration_ms"
        let eventsRows = safe.events.map { event -> String in
            [
                event.timestamp.ISO8601Format(),
                String(Int64((event.timestamp.timeIntervalSince1970 * 1000).rounded())),
                event.sessionID.uuidString,
                event.candidateID?.uuidString ?? "",
                event.frameID?.uuidString ?? "",
                event.unitID?.uuidString ?? "",
                event.stage, event.outcome, event.reasonCode,
                event.durationMs.map { String($0) } ?? ""
            ].joined(separator: ",")
        }
        let eventsCSV = Data(([eventsHeader] + eventsRows).joined(separator: "\n").utf8)

        let findings = DiagnosticIssueDetector.assess(safe)
        let findingsEncoder = JSONEncoder()
        findingsEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let findingsData = try findingsEncoder.encode(findings)

        let count: (String) -> Int = { safe.counters[$0, default: 0] }
        let metric: (String) -> String = { name in
            guard let d = safe.distributions[name], d.count > 0 else { return "unavailable (0 samples)" }
            let median = d.p50.map { String(format: "%.0f", $0) } ?? "–"
            let p90 = d.p90.map { String(format: "%.0f", $0) } ?? "–"
            let p95 = d.p95.map { String(format: "%.0f", $0) } ?? "–"
            return "median \(median) ms, mean \(String(format: "%.0f", d.mean)) ms, P90 \(p90) ms, P95 \(p95) ms (\(d.count) samples)"
        }
        let settingsLines = safe.settings.keys.sorted().map {
            "- \($0): \(safe.settings[$0] ?? "")"
        }
        let issueLines = findings.map {
            "- [\($0.classification)] \($0.code): \($0.explanation)"
        }
        let summary = Data("""
            # ScreenLingo diagnostic summary

            ## Measurement boundary
            First OCR sighting to **PiP sample-buffer enqueue**, not physical display or
            a ground-truth measure of when a subtitle first appeared in a video.
            Many processing stages overlap; their averages must not be added together.
            No subtitle text, video frames, audio or user file paths are exported.

            ## Normal performance
            - OCR: \(metric("ocrMs"))
            - Result processing (includes reuse): \(metric("translationMs"))
            - OCR-to-PiP enqueue: \(metric("enqueueLatencyMs"))
            - Confirmed model requests: \(metric("confirmedModelMs"))
            - Speculative model requests: \(metric("speculativeModelMs"))
            - PiP frame preparation: \(metric("renderingMs"))

            ## Legacy model sessions (v2.0.0, diagnostics only)
            - Confirmed model, other session's call running or ended < 1.5 s: \(metric("legacyConfirmedAfterSessionSwitchMs"))
            - Confirmed model, no other session nearby: \(metric("legacyConfirmedNoSwitchMs"))
            - Speculative sessions created: \(count("speculativeSessionsCreated"))
            - Confirmed calls on the shared prediction session: \(count("legacySharedSessionCalls"))
            - Warm-up model calls that started while capture was live (2.2.1, E18): \(count("warmupsDuringCapture"))

            ## OCR (v2.0.0)
            - Pixel-verified confirmations / fell back to OCR: \(count("pixelConfirmations")) / \(count("pixelRejections"))
            - OCR passes skipped while the caption was unchanged: \(count("watchSkippedOCR"))
            - OCR passes started at once on a caption change: \(count("watchTriggeredOCR"))

            ## Subtitle lifecycle (candidates, not sentences)
            - Confirmed packets: \(count("confirmedCandidatePackets"))
            - Successfully enqueued candidate frames: \(count("enqueuedCandidateFrames"))
            - Confirmed but superseded before enqueue: \(count("supersededUnpresentedConfirmed")) (translation already running: \(count("supersededConfirmedInFlight")), not started: \(count("supersededConfirmedNotStarted")))
            - Failed enqueue attempts: \(count("enqueueFailed"))
            - Confirmed handoffs deferred: \(count("handoffDeferred"))
            - Handoffs replayed / expired: \(count("handoffReplayed")) / \(count("handoffExpired"))
            - Queue replacements: \(count("queueReplacements"))
            Enqueue and confirmation counters represent different events and are not
            a denominator for unique-subtitle coverage. The app cannot verify
            subtitles it never recognized or whether iOS visibly displayed a frame.

            ## Work avoided and reuse (different event units)
            - Session RAM cache hits: \(count("sessionCacheHits"))
            - Saved-origin results reused (includes prefetched RAM): \(count("savedMemoryHits"))
            - Direct persistent lookups resolved: \(count("persistentHits"))
            - Temporary-memory hits: \(count("temporaryMemoryHits"))
            - Pre-translated results reused: \(count("speculativeHits"))
            - Uncached translation units: \(count("uncachedUnits"))
            - Actual database misses: \(count("lookupMisses"))
            - Deliberately bypassed lookups: \(count("bypassedLookups"))
            - Temporary-memory misses: \(count("temporaryMemoryMisses"))
            - Speculative requests: \(count("speculativeModelRequests"))
            - Speculative pipelines discarded: \(count("supersededSpeculativePipelines"))
            - Completed speculative units retained: \(count("specRetainedUnits"))
            - Completed confirmed units retained: \(count("completedConfirmedUnitsRetained"))
            - Model batches sent: \(count("actualModelBatches"))
            - Explicit speculative stop requests: \(count("speculativeStopRequests"))
            - Cancelled model batches: \(count("cancelledModelBatches"))
            - Skipped unchanged frames: \(count("unchangedSkippedFrames"))
            - Speculation opportunities skipped with dominant saved reuse: \(count("memoryAwareSpeculationSkipped"))
            - Complete captions assembled from RAM around a busy model lane: \(count("ramCaptionBypasses"))
            - Exact assembled captions reused: \(count("exactCaptionHits"))
            - Exact confirmed in-flight units shared with replacement captions: \(count("sharedConfirmedInFlightUnits"))
            - Exact duplicate units coalesced: \(count("exactUnitsCoalesced"))
            - Speculative units retained / reused / evicted unused: \(count("speculativeUnitsRetained")) / \(count("speculativeUnitsReused")) / \(count("speculativeUnitsEvictedUnused"))

            ## Translation memory
            - Database entries: \(safe.health.totalEntries)
            - Ready for reuse: \(safe.health.readyEntries)
            - Pending writes: \(safe.health.pendingWrites)
            - Failed writes: \(safe.health.failedWrites)
            - Conflicts: \(safe.health.conflicts)

            ## Enabled settings (redacted allowlist)
            \(settingsLines.isEmpty ? "Not recorded" : settingsLines.joined(separator: "\n"))

            ## Evidence-based findings
            \(issueLines.isEmpty ? "No issues identified by current numeric heuristics." : issueLines.joined(separator: "\n"))

            ## Caveats
            - Counts from different processing stages are not interchangeable.
            - Timing distributions are bounded recent samples; 15-second intervals
              provide a broader chronological view, not ground truth of omitted text.
            - Device, OS, source language, workload, cache state and experimental
              toggles must match for a meaningful A/B comparison.
            - Suspected findings are heuristics, never proof of incorrect translation.
            """.utf8)

        let names = [
            "manifest.json", "summary.md", "session.json", "translation_modes.json", "intervals.csv",
            "seconds_1.csv", "seconds_5.csv",
            "metrics.csv", "events.csv", "findings.json", "README.txt"
        ]
        let manifest: [String: Any] = [
            "bundleFormat": "ScreenLingo diagnostics",
            "bundleSchemaVersion": 3,
            "sessionSchemaVersion": safe.eventSchemaVersion,
            "sessionID": safe.id.uuidString,
            "startedAt": safe.startedAt.ISO8601Format(),
            "endedAt": safe.endedAt.ISO8601Format(),
            "fileNames": names,
            "privacy": "metadataOnly",
            "textIncluded": false,
            "boundedEvents": safe.events.count,
            "intervals": safe.intervals?.count ?? 0,
            "oneSecondIntervals": safe.oneSecondIntervals?.count ?? 0,
            "fiveSecondIntervals": safe.fiveSecondIntervals?.count ?? 0,
            "distributionCount": safe.distributions.count,
            "measuredUntil": "PiP sample-buffer enqueue (not physical display)"
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        let readme = Data("""
            ScreenLingo diagnostic ZIP v4 — private, portable, offline
            Start with summary.md: human-readable findings, measured latency and
            candidate continuity. All numbers come from redacted session.json.
            manifest.json: ZIP format and session metadata.
            session.json: versioned canonical metadata (compatible with older readers).
            intervals.csv: chronological 15-second counters (long sessions).
            seconds_1.csv: most recent 5 minutes at ~1s while detailed collection
              is enabled; empty if detailed collection was off.
            seconds_5.csv: most recent 15 minutes at ~5s.
            Buckets record actual elapsed times; iOS scheduling can cause gaps.
            Percentiles are calculated from original measurements in each bucket,
            never averaged from the percentiles of shorter buckets.
            metrics.csv: sample count, mean, median, P90, P95, P99 by timing stage.
            events.csv: recent candidate/frame/unit event timeline with opaque UUIDs
              and millisecond-precision Unix timestamps for exact ordering.
            translation_modes.json: bounded mode/caption/revision/strategy timeline,
              queue/service timings and mode/path/language/thermal cohorts.
              Retained/new session labels do not prove resident model warmth.
              Mode counters/distributions cover retained events, not the entire session.
            findings.json: observed and suspected issues; heuristics, not verified errors.
            README.txt: this file.

            In Hybrid Recovery, deliveryFilteringMs matches confirmation-to-PiP time: it is the wait for the
            Apple Default model, booked under that stage name, not a separate filtering cost. The
            hybrid_switch_guard_* values are the gap since the last Default call returned, not a delay.

            Names (2.3.1): the same three sources are summed in every mode as path_memory (stored result),
            path_early (early translation reused, ready or still running) and path_confirmed_time (translated after
            confirmation). In Hybrid Recovery and Low Latency a translation after confirmation is called a recovery
            (recovery_decision_*, recovery_service_ms, pip_enqueue_recovery_success). Legacy has the same situation and
            calls it confirmed fresh (confirmed_service_ms, pip_enqueue_confirmed_fresh), or pip_enqueue_fresh_text_changed
            when the caption's early text had changed; reports before 2.3.0 called that pip_enqueue_legacy_recovery and
            recovery_service_ms. None of these is a second attempt. All modes also name the model call through
            confirmed_model_completed (confirmedModelMs) and the model-call table lane confirmed.

            Diagnostics are bounded. Structured events cover at most 6000 retained (2.2.3: raised from 2400)
            entries; old events can be evicted. Summary counters span the whole session.
            Model batches, translation units, OCR packets and subtitle candidates
            count different kinds of work; never add or equate those quantities.
            First OCR sighting to PiP enqueue does NOT measure physical display.
            Visual-motion proxies are NOT subtitle ground truth.
            No recognized text, translated text, frames, audio or paths are included.
            This ZIP is only created when you explicitly request export.
            """.utf8)
        let modesData = try JSONEncoder().encode(safe.translationModes)
        let zip = try DiagnosticStoredZIP.make(entries: [
            (name: "manifest.json", contents: manifestData),
            (name: "summary.md", contents: summary),
            (name: "session.json", contents: sessionData),
            (name: "translation_modes.json", contents: modesData),
            (name: "intervals.csv", contents: intervalsCSV),
            (name: "seconds_1.csv", contents: secondsOneCSV),
            (name: "seconds_5.csv", contents: secondsFiveCSV),
            (name: "metrics.csv", contents: metricsCSV),
            (name: "events.csv", contents: eventsCSV),
            (name: "findings.json", contents: findingsData),
            (name: "README.txt", contents: readme)
        ])
        let timestamp = ISO8601DateFormatter().string(from: safe.startedAt)
            .replacingOccurrences(of: ":", with: "-")
        let filename = "ScreenLingo-Diagnostics-" + timestamp + "-" +
            String(safe.id.uuidString.prefix(8)) + ".zip"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
        try zip.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        return url
    }

    func decode(_ data: Data) throws -> DiagnosticSessionExport {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticSessionExport.self, from: data)
    }
}
