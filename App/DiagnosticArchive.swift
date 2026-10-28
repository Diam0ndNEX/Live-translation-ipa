import Foundation

/// Metadata only: no source text, translations, cache keys, filenames or model errors.
struct MemoryDiagnosticHealth: Codable {
    var schemaVersion = 1
    var totalEntries = 0
    var readyEntries = 0
    var needsValidation = 0
    var legacyValidated = 0
    var legacySuperseded = 0
    var legacyUnverified = 0
    var conflicts = 0
    var databaseBytes: Int64 = 0
    var migrationStatus = "not started"
    var integrity = "not verified"
    var pendingWrites = 0
    var failedWrites = 0
    var ramEntries = 0
    var categoryCounts: [String: Int] = [:]

    // Old saved sessions lack categoryCounts. Keep them readable after upgrades.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, totalEntries, readyEntries, needsValidation, conflicts
        case legacyValidated, legacySuperseded, legacyUnverified
        case databaseBytes, migrationStatus, integrity, pendingWrites, failedWrites
        case ramEntries, categoryCounts
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        totalEntries = try c.decodeIfPresent(Int.self, forKey: .totalEntries) ?? 0
        readyEntries = try c.decodeIfPresent(Int.self, forKey: .readyEntries) ?? 0
        needsValidation = try c.decodeIfPresent(Int.self, forKey: .needsValidation) ?? 0
        legacyValidated = try c.decodeIfPresent(Int.self, forKey: .legacyValidated) ?? 0
        legacySuperseded = try c.decodeIfPresent(Int.self, forKey: .legacySuperseded) ?? 0
        legacyUnverified = try c.decodeIfPresent(Int.self, forKey: .legacyUnverified) ?? 0
        conflicts = try c.decodeIfPresent(Int.self, forKey: .conflicts) ?? 0
        databaseBytes = try c.decodeIfPresent(Int64.self, forKey: .databaseBytes) ?? 0
        migrationStatus = try c.decodeIfPresent(String.self, forKey: .migrationStatus) ?? "not started"
        integrity = try c.decodeIfPresent(String.self, forKey: .integrity) ?? "not verified"
        pendingWrites = try c.decodeIfPresent(Int.self, forKey: .pendingWrites) ?? 0
        failedWrites = try c.decodeIfPresent(Int.self, forKey: .failedWrites) ?? 0
        ramEntries = try c.decodeIfPresent(Int.self, forKey: .ramEntries) ?? 0
        categoryCounts = try c.decodeIfPresent([String: Int].self, forKey: .categoryCounts) ?? [:]
    }
}

enum MemoryDiagnosticOutcome: String, Codable, CaseIterable {
    case ramHit, persistentHit, legacyHit, speculativeHit, miss, timeout
    case compatibilityRejected, normalizedHit, databaseUnavailable, persisted, writeFailed, ramEviction, cancelled
}

struct StructuredDiagnosticEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let sessionID: UUID
    let candidateID: UUID?
    // Null means this boundary was not instrumented, rather than inferred.
    var frameID: UUID? = nil
    var unitID: UUID? = nil
    let stage: String
    let outcome: String
    let reasonCode: String
    let durationMs: Double?
    let privacy: String
}

struct DiagnosticDistribution: Codable {
    let count: Int
    let mean: Double
    let p50: Double?
    let p90: Double?
    let p95: Double?
    let p99: Double?
    let maximum: Double?
    init(_ values: [Double]) {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        count = sorted.count
        mean = sorted.isEmpty ? 0 : sorted.reduce(0,+) / Double(sorted.count)
        func percentile(_ p: Double) -> Double? {
            guard !sorted.isEmpty else { return nil }
            return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1))]
        }
        p50 = percentile(0.5)
        p90 = sorted.count >= 10 ? percentile(0.9) : nil
        p95 = sorted.count >= 20 ? percentile(0.95) : nil
        p99 = sorted.count >= 100 ? percentile(0.99) : nil
        maximum = sorted.last
    }
}

/// Fifteen-second, metadata-only summaries cover the full captured session instead
/// of only the last few thousand events. Keys are strict counters, never OCR text.
struct DiagnosticIntervalBucket: Codable {
    let startedAt: Date
    let elapsedSeconds: Double
    let counters: [String: Int]
    let thermalLevel: Int
    let lowPower: Bool
    let captureConnected: Bool
    /// The current effective cadence in the extension. Not actual capture FPS.
    var effectiveOCRIntervalMs: Double? = nil
    /// Last coarse image-motion-to-first-OCR proxy; NOT subtitle acquisition latency.
    var visualChangeProxyMs: Double? = nil
    var ocrMedianMs: Double? = nil
    var ocrP95Ms: Double? = nil
    var translationMedianMs: Double? = nil
    var translationP95Ms: Double? = nil
    var enqueueMedianMs: Double? = nil
    var enqueueP95Ms: Double? = nil
    var modelBatchMedianMs: Double? = nil

    static let allowedCounters: Set<String> = [
        "captureFrames", "capturePasses", "ocrPackets", "candidateConfirmed",
        "candidateEnqueued", "candidateSuperseded", "candidateCancelled",
        "candidateFirstSeen", "speculativeRequests", "speculativeDiscarded",
        "ramHits", "persistentHits", "speculativeHits", "lookupMisses",
        "unchangedSkips", "cadenceSkips", "pausedSkips", "emptyOCRPasses",
        "contrastRetries", "movieSelections", "movieTemporalOverrides",
        "movieRejectedSmall", "queueReplacements", "earlyDeferred",
        "unpresentedConfirmed", "capturePackets", "modelBatches",
        "modelFailures", "warmupAttempts", "warmupSucceeded",
        "runtimeTransitions", "visualChanges",
        "ocrMeasurementCount", "translationMeasurementCount", "enqueueMeasurementCount"
    ]

    func sanitized() -> DiagnosticIntervalBucket {
        func safe(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && $0 >= 0 ? min($0, 60000) : nil }
        }
        return DiagnosticIntervalBucket(startedAt: startedAt,
            elapsedSeconds: elapsedSeconds.isFinite ? max(0, min(elapsedSeconds, 1800)) : 0,
            counters: counters.filter { Self.allowedCounters.contains($0.key) && $0.value >= 0 },
            thermalLevel: max(0, min(thermalLevel, 3)),
            lowPower: lowPower, captureConnected: captureConnected,
            effectiveOCRIntervalMs: safe(effectiveOCRIntervalMs),
            visualChangeProxyMs: safe(visualChangeProxyMs).map { min($0, 6000) },
            ocrMedianMs: safe(ocrMedianMs), ocrP95Ms: safe(ocrP95Ms),
            translationMedianMs: safe(translationMedianMs),
            translationP95Ms: safe(translationP95Ms),
            enqueueMedianMs: safe(enqueueMedianMs), enqueueP95Ms: safe(enqueueP95Ms),
            modelBatchMedianMs: safe(modelBatchMedianMs))
    }
}

struct DiagnosticSessionExport: Codable, Identifiable {
    var eventSchemaVersion = 1
    var exportFormatVersion = 2
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let appVersion: String
    let systemVersion: String
    /// Hardware model code only (not a device name or unique identifier).
    /// Older diagnostic exports decode as nil and are not compared as controlled runs.
    var hardwareModel: String? = nil
    let settings: [String: String]
    let health: MemoryDiagnosticHealth
    let counters: [String: Int]
    let distributions: [String: DiagnosticDistribution]
    let events: [StructuredDiagnosticEvent]
    /// Optional for backwards-compatible import of 1.4.0/early 1.4.1 bundles.
    var intervals: [DiagnosticIntervalBucket]? = nil
    let measurementBoundary: String
    let textCapture: Bool
}

/// Encoding, disk I/O and decode validation run away from the UI actor.
actor DiagnosticExportWriter {
    /// Defense in depth: diagnostic event labels are fixed reason codes, never
    /// raw OCR or translated text, even if a future producer calls us incorrectly.
    private func redact(_ snapshot: DiagnosticSessionExport) -> DiagnosticSessionExport {
        let stageCodes: Set<String> = [
            "memory", "segmentation", "first OCR", "seen", "confirmed", "processing",
            "speculating", "cache", "ready", "enqueued", "superseded", "cancelled",
            "ocrCorrection", "language", "freshTranslation", "translationResult",
            "frame_arrival", "rotation", "ocr_execution", "duplicate_detection", "ocr_filtering",
            "stability", "text_grouping", "ocr_correction", "language_detection",
            "memory_lookup", "translation", "pip_preparation", "pip_enqueue", "runtime_state",
            "model_state", "cancellation"
        ]
        let eventCodes: Set<String> = Set(MemoryDiagnosticOutcome.allCases.map { $0.rawValue })
            .union([
                "observed", "cache_hit", "computed", "accepted", "rejected_duplicate",
                "rejected_recent_fragment", "rejected_empty", "rejected_revision",
                "rejected_unstable", "rejected_low_confidence", "rejected_stale",
                "filtered", "confirmed", "speculative", "ready", "enqueued",
                "cancelled", "redacted", "completed", "deferred_early_candidate",
                "heartbeat_timeout", "capture_connected", "idle_auto_pause", "session_time_limit",
                "thermal_nominal", "thermal_fair", "thermal_serious", "thermal_critical",
                "changing_group_preferred", "dominant_group", "queue_replaced",
                "preserved_confirmed_work",
                "warmup_started", "warmup_succeeded", "warmup_failed",
                "model_session_created", "model_batch_completed", "model_batch_failed",
                "warmup_source_unresolved", "app_started", "capture_config_changed",
                "capture_idle", "capture_live", "capture_paused", "capture_frozen"
            ]).union(stageCodes)
        let safeEvents = snapshot.events.suffix(2400).map { event in
            StructuredDiagnosticEvent(id: event.id, timestamp: event.timestamp,
                sessionID: event.sessionID, candidateID: event.candidateID,
                frameID: event.frameID, unitID: event.unitID,
                stage: stageCodes.contains(event.stage) ? event.stage : "other",
                outcome: eventCodes.contains(event.outcome) ? event.outcome : "redacted",
                reasonCode: eventCodes.contains(event.reasonCode) ? event.reasonCode : "redacted",
                durationMs: event.durationMs.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                privacy: "metadataOnly")
        }
        let settingsKeys: Set<String> = [
            "mode", "speed", "stability", "frameRot", "area", "adaptiveOCR",
            "source", "target", "customY0", "customY1", "minTextH", "dropNoise",
            "boost", "ocrCorrection", "adaptive", "displayPolicy", "minDisplay",
            "clearHold", "autoClear", "keepWarm", "langLock",
            "selectiveSpeculation", "speculationConfidence", "confirmationDeadline",
            "remember", "privateSession", "diagnosticsEnabled", "detailedCollection",
            "skipUnchanged", "idleBackoff", "adaptiveConfirmation", "subtitleTracking",
            "translateAhead", "coolMode", "steadyCaptions", "ocrConfidence", "freshTranslationTest"
        ]
        let safeSettings = snapshot.settings.filter { pair in
            settingsKeys.contains(pair.key) && pair.value.utf8.count <= 48 &&
            pair.value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
            }
        }
        let reason = snapshot.measurementBoundary
        let safeBoundary = reason.utf8.count <= 512 &&
            (reason.hasPrefix("First OCR sighting") || reason == "OCR through PiP enqueue") ?
            reason : "OCR to PiP enqueue; detailed measurement boundary redacted"
        let safeHardware = snapshot.hardwareModel.flatMap { model -> String? in
            guard model.utf8.count <= 32,
                  model.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.contains($0) || $0 == "," ||
                      $0 == "-" || $0 == "_"
                  }) else { return nil }
            return model
        }
        return DiagnosticSessionExport(id: snapshot.id, startedAt: snapshot.startedAt,
            endedAt: snapshot.endedAt, appVersion: snapshot.appVersion,
            systemVersion: snapshot.systemVersion, hardwareModel: safeHardware,
            settings: safeSettings,
            health: snapshot.health, counters: snapshot.counters,
            distributions: snapshot.distributions, events: safeEvents,
            intervals: snapshot.intervals.map { Array($0.suffix(960)).map { $0.sanitized() } },
            measurementBoundary: safeBoundary, textCapture: false)
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

    /// Portable user-initiated ZIP bundle; no background uploads. The contained
    /// session.json uses exactly the privacy policy applied to structured JSON.
    func exportZIP(_ snapshot: DiagnosticSessionExport) throws -> URL {
        let json = try encode(snapshot)
        let readme = Data("""
        ScreenLingo offline diagnostics — 1.4.1
        session.json: bounded recent metadata-only candidate events, timing distributions,
        configuration, memory diagnostics and whole-session interval summaries.
        intervals.csv: chronological 15-second counters, thermal and capture state.
        Empty/missing intervals indicate this older version did not record interval data.
        Counts are OCR/processing events, NOT a count of spoken sentences or missed captions.
        Visual-change timestamps are only coarse image-motion proxies, not a video subtitle
        ground truth. A caption invisible to OCR cannot be recovered from these statistics.
        No screen frames, recognized words, translated words, audio or identifying file paths.
        Physical PiP presentation time is NOT measured; 'enqueued' is a buffer enqueue.
        Settings, OS version, cache history and source content affect A/B comparisons.
        Nothing is automatically uploaded. This ZIP is generated at user request.
        """.utf8)
        let safe = redact(snapshot)
        let names = DiagnosticIntervalBucket.allowedCounters.sorted()
        let header = "start_time,elapsed_seconds,thermal_level,low_power,capture_connected,effective_ocr_interval_ms,visual_motion_proxy_ms,ocr_median_ms,ocr_p95_ms,translation_median_ms,translation_p95_ms,enqueue_median_ms,enqueue_p95_ms,model_batch_median_ms," +
                     names.joined(separator: ",")
        let lines: [String] = (safe.intervals ?? []).map { interval in
            var fields: [String] = [
                String(Int(interval.startedAt.timeIntervalSince1970)),
                String(interval.elapsedSeconds),
                String(interval.thermalLevel),
                interval.lowPower ? "1" : "0",
                interval.captureConnected ? "1" : "0"
            ]
            let durations: [Double?] = [
                interval.effectiveOCRIntervalMs, interval.visualChangeProxyMs,
                interval.ocrMedianMs, interval.ocrP95Ms,
                interval.translationMedianMs, interval.translationP95Ms,
                interval.enqueueMedianMs, interval.enqueueP95Ms,
                interval.modelBatchMedianMs
            ]
            fields.append(contentsOf: durations.map { value in
                guard let value else { return "" }
                return String(value)
            })
            fields.append(contentsOf: names.map { String(interval.counters[$0, default: 0]) })
            return fields.joined(separator: ",")
        }
        let csv = Data(([header] + lines).joined(separator: "\n").utf8)
        let zip: Data = try DiagnosticStoredZIP.make(entries: [
            (name: "session.json", contents: json),
            (name: "intervals.csv", contents: csv),
            (name: "README.txt", contents: readme)
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlingo-diagnostics-" + UUID().uuidString + ".zip")
        try zip.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        return url
    }
    func decode(_ data: Data) throws -> DiagnosticSessionExport {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticSessionExport.self, from: data)
    }
}


/// Controlled comparison is permitted only for matching diagnostic boundaries,
/// device OS, settings and adequate sample counts. It is not a causal claim.
struct DiagnosticPerformanceComparison {
    let comparable: Bool
    let reason: String
    let p95Changes: [String: Double]

    init(baseline: DiagnosticSessionExport, current: DiagnosticSessionExport) {
        guard let baselineModel = baseline.hardwareModel, !baselineModel.isEmpty,
              baselineModel == current.hardwareModel,
              baseline.systemVersion == current.systemVersion,
              baseline.measurementBoundary == current.measurementBoundary,
              baseline.settings == current.settings
        else {
            comparable = false
            reason = "Hardware model, OS, settings or measurement boundaries differ or are unavailable; comparison withheld"
            p95Changes = [:]
            return
        }
        var differences: [String: Double] = [:]
        for name in baseline.distributions.keys.sorted() {
            guard let before = baseline.distributions[name],
                  let after = current.distributions[name],
                  before.count >= 20, after.count >= 20,
                  let baselineP95 = before.p95, baselineP95 > 0,
                  let currentP95 = after.p95, currentP95.isFinite else { continue }
            differences[name] = 100 * (currentP95 - baselineP95) / baselineP95
        }
        p95Changes = differences
        comparable = !differences.isEmpty
        reason = comparable ? "Comparable settings; different subtitles may affect results"
            : "At least 20 samples per session are required to compare p95"
    }
}

 
/// Evidence-based findings derived exclusively from bounded, redacted session metadata.
/// "Observed" means a recorded fact, not proof that a translation was wrong.
/// "Suspected" is a rate-based warning whose threshold can produce false positives.
struct DiagnosticIssueFinding: Codable, Identifiable {
    let code: String
    let classification: String
    let occurrences: Int
    let explanation: String
    var id: String { code }
}

enum DiagnosticIssueDetector {
    static func assess(_ session: DiagnosticSessionExport) -> [DiagnosticIssueFinding] {
        var findings: [DiagnosticIssueFinding] = []
        func add(_ code: String, _ classification: String, _ occurrences: Int, _ explanation: String) {
            findings.append(DiagnosticIssueFinding(code: code, classification: classification,
                occurrences: occurrences, explanation: explanation))
        }
        let failures = max(session.health.failedWrites, session.counters["writeFailed", default: 0])
        if failures > 0 {
            add("memory_write_failure", "observed", failures,
                "SQLite write failures were reported. Confirm whether pending translations were persisted.")
        }
        if session.health.conflicts > 0 {
            add("memory_conflict", "observed", session.health.conflicts,
                "Multiple translations share a memory identity; ambiguous alternatives are not reused.")
        }
        let migration = session.health.migrationStatus
        if migration == "partial_recovery" || migration == "failed_recoverably" {
            add("migration_recovery", "observed", 1,
                "Legacy migration did not fully complete. Protected originals may require inspection.")
        }
        let lookups = ["ramHit", "persistentHit", "legacyHit", "normalizedHit", "speculativeHit",
                       "miss", "timeout", "compatibilityRejected", "databaseUnavailable"]
            .reduce(0) { $0 + max(0, session.counters[$1, default: 0]) }
        let timeouts = max(0, session.counters["timeout", default: 0])
        if lookups >= 20 && timeouts >= 3 && Double(timeouts) / Double(lookups) >= 0.05 {
            add("memory_lookup_timeouts", "suspected", timeouts,
                "At least 5% of observed lookups timed out. Test the lookup deadline and database pressure.")
        }
        let cancelled = max(0, session.counters["cancelled", default: 0])
        if cancelled >= 10 && lookups >= 20 && Double(cancelled) / Double(lookups) > 0.25 {
            add("high_cancellation_rate", "suspected", cancelled,
                "Many units were cancelled. Screen motion and changing subtitles may explain the pattern.")
        }
        return findings
    }
}

/// Minimal ZIP writer using uncompressed entries, avoiding network dependencies.
/// Fixed entry names prevent path traversal; 4 MiB cap keeps export bounded.
/// The ZIP CRC32 and central directory are verified by standard ZIP readers.
enum DiagnosticStoredZIP {
    static func make(entries: [(name: String, contents: Data)]) throws -> Data {
        guard !entries.isEmpty, entries.count <= 8 else { throw CocoaError(.fileWriteUnknown) }
        var body = Data()
        var central = Data()
        func write16(_ v: UInt16, to d: inout Data) {
            let n = v.littleEndian
            withUnsafeBytes(of: n) { d.append(contentsOf: $0) }
        }
        func write32(_ v: UInt32, to d: inout Data) {
            let n = v.littleEndian
            withUnsafeBytes(of: n) { d.append(contentsOf: $0) }
        }
        func checksum(_ bytes: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFFFFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB88320 : 0)
                }
            }
            return ~crc
        }
        for entry in entries {
            let name = Data(entry.name.utf8)
            guard entry.contents.count <= 4 * 1024 * 1024,
                  body.count + entry.contents.count < 8 * 1024 * 1024,
                  name.count > 0, name.count < 200, !entry.name.contains("/"),
                  !entry.name.contains("\\"), !entry.name.contains("..")
            else { throw CocoaError(.fileWriteUnknown) }
            let offset = UInt32(body.count)
            let count = UInt32(entry.contents.count)
            let crc = checksum(entry.contents)

            write32(0x04034B50, to: &body) // Local file header
            write16(20, to: &body)
            write16(0, to: &body) // No data descriptor
            write16(0, to: &body) // Stored, not compressed
            write16(0, to: &body)
            write16(0, to: &body)
            write32(crc, to: &body)
            write32(count, to: &body)
            write32(count, to: &body)
            write16(UInt16(name.count), to: &body)
            write16(0, to: &body)
            body.append(name)
            body.append(entry.contents)

            write32(0x02014B50, to: &central) // Central file header
            write16(20, to: &central)
            write16(20, to: &central)
            write16(0, to: &central)
            write16(0, to: &central)
            write16(0, to: &central)
            write16(0, to: &central)
            write32(crc, to: &central)
            write32(count, to: &central)
            write32(count, to: &central)
            write16(UInt16(name.count), to: &central)
            write16(0, to: &central)
            write16(0, to: &central)
            write16(0, to: &central)
            write16(0, to: &central)
            write32(0, to: &central)
            write32(offset, to: &central)
            central.append(name)
        }
        let centralOffset = UInt32(body.count)
        body.append(central)
        write32(0x06054B50, to: &body)
        write16(0, to: &body)
        write16(0, to: &body)
        write16(UInt16(entries.count), to: &body)
        write16(UInt16(entries.count), to: &body)
        write32(UInt32(central.count), to: &body)
        write32(centralOffset, to: &body)
        write16(0, to: &body)
        return body
    }
}

/// A view model derived from the existing structured diagnostic recorder.
/// Candidate and frame identities are random UUIDs, not OCR source strings.
struct DiagnosticReviewedStage: Identifiable {
    let id: UUID
    let timestamp: Date
    let stage: String
    let reason: String
    let durationMs: Double?
}
struct DiagnosticReviewedCandidate: Identifiable {
    let id: UUID
    let sessionID: UUID
    let firstAt: Date
    let lastAt: Date
    let frameCount: Int
    let stages: [DiagnosticReviewedStage]
    let status: String
}

/// Off the live path: only process the recorder's bounded last 2400 events.
/// This is an explanation of *instrumented* stages, not a reconstruction of
/// unobserved OCR, model accuracy, or the physical PiP display.
enum DiagnosticTraceReview {
    private static let allowedStages: Set<String> = [
        "frame_arrival", "rotation", "duplicate_detection", "ocr_filtering",
        "stability", "text_grouping", "ocr_correction", "language_detection",
        "segmentation", "memory_lookup", "translation", "pip_preparation",
        "pip_enqueue", "cancellation", "runtime_state", "first OCR", "seen", "confirmed",
        "processing", "speculating", "cache", "ready", "enqueued",
        "superseded", "memory", "cancelled", "ocrCorrection", "language",
        "freshTranslation", "translationResult"
    ]
    private static let allowedReasons: Set<String> = [
        "accepted", "rejected_duplicate", "rejected_recent_fragment",
        "rejected_empty", "rejected_revision", "rejected_unstable",
        "rejected_low_confidence", "rejected_stale", "filtered", "deferred_early_candidate",
        "heartbeat_timeout", "capture_connected", "idle_auto_pause", "session_time_limit",
        "thermal_nominal", "thermal_fair", "thermal_serious", "thermal_critical",
        "confirmed", "speculative", "ready", "enqueued", "cancelled",
        "observed", "cache_hit", "computed", "ramHit", "persistentHit",
        "legacyHit", "normalizedHit", "speculativeHit", "miss", "timeout",
        "compatibilityRejected", "databaseUnavailable", "persisted",
        "writeFailed", "ramEviction", "other", "incompatible", "conflict"
    ]
    static func review(_ input: [StructuredDiagnosticEvent], limit: Int = 12)
        -> [DiagnosticReviewedCandidate] {
        let bounded = input.suffix(2400)
            .filter { $0.privacy == "metadataOnly" && $0.candidateID != nil }
        var byCandidate: [UUID: [StructuredDiagnosticEvent]] = [:]
        for event in bounded {
            guard let id = event.candidateID else { continue }
            byCandidate[id, default: []].append(event)
        }
        return byCandidate.compactMap { id, events in
            guard let first = events.min(by: { $0.timestamp < $1.timestamp }),
                  let last = events.max(by: { $0.timestamp < $1.timestamp })
            else { return nil }
            let sorted = events.sorted { $0.timestamp < $1.timestamp }
            let stages = sorted.suffix(64).map { event in
                DiagnosticReviewedStage(id: event.id, timestamp: event.timestamp,
                    stage: allowedStages.contains(event.stage) ? event.stage : "other",
                    reason: allowedReasons.contains(event.reasonCode) ?
                        event.reasonCode : "unclassified",
                    durationMs: event.durationMs.flatMap {
                        $0.isFinite && $0 >= 0 ? $0 : nil
                    })
            }
            let stageNames = Set(stages.map(\.stage))
            let state: String
            if stageNames.contains("enqueued") || stageNames.contains("pip_enqueue") {
                state = "PiP buffer enqueued (physical display unverified)"
            } else if stageNames.contains("cancelled") || stageNames.contains("cancellation") ||
                      stageNames.contains("superseded") {
                state = "Superseded or cancelled"
            } else {
                state = "Partial trace (unobserved stages unknown)"
            }
            return DiagnosticReviewedCandidate(id: id, sessionID: first.sessionID,
                firstAt: first.timestamp, lastAt: last.timestamp,
                frameCount: Set(events.compactMap(\.frameID)).count,
                stages: stages, status: state)
        }
        .sorted { $0.lastAt > $1.lastAt }
        .prefix(max(1, min(limit, 20)))
        .map { $0 }
    }
}
