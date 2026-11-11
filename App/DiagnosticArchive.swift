import Foundation

/// Metadata only: no source text, translations, cache keys, filenames or model errors.
struct MemoryDiagnosticHealth: Codable {
    var schemaVersion = 2
    var totalEntries = 0
    var readyEntries = 0
    var needsValidation = 0
    var legacyValidated = 0
    var legacySuperseded = 0
    var legacyUnverified = 0
    var suggestedOCRMatches = 0
    var suggestedFragmentMatches = 0
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
        case suggestedOCRMatches, suggestedFragmentMatches
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
        suggestedOCRMatches = try c.decodeIfPresent(Int.self, forKey: .suggestedOCRMatches) ?? 0
        suggestedFragmentMatches = try c.decodeIfPresent(Int.self, forKey: .suggestedFragmentMatches) ?? 0
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
    case bypassed, temporaryMiss
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
        "legacyVerified", "legacySuperseded", "legacyOCRSuggestions",
        "legacyFragmentSuggestions", "legacyIdleStarted", "legacyIdleCompleted",
        "unchangedSkips", "cadenceSkips", "pausedSkips", "emptyOCRPasses",
        "contrastRetries", "movieSelections", "movieTemporalOverrides",
        "movieRejectedSmall", "queueReplacements", "earlyDeferred",
        "unpresentedConfirmed", "capturePackets", "modelBatches",
        "modelFailures", "warmupAttempts", "warmupSucceeded",
        "warmupPredicted", "coldModelBatches", "adaptiveSpeculationSkipped",
            "legacyAdaptiveLowYieldSkips", "legacyAdaptiveSavedSkips",
            "legacyLowConfidenceSkips", "legacyBusySpeculationSkips",
            "legacyDuplicateSpeculationSkips",
        "specPreemptionRequested", "specMatchingConfirmation",
        "specRetainedUnits", "completedConfirmedUnitsRetained", "temporaryMemoryHits",
        "uncachedUnits", "bypassedLookups", "temporaryMemoryMisses",
        "speculativeStopRequests", "speculativeSessionsCreated", "legacySharedSessionCalls", "legacyConfirmedOwnLane", "memoryAwareSpeculationSkipped", "ramCaptionBypasses", "exactCaptionHits", "exactUnitsCoalesced", "sharedConfirmedInFlightUnits", "sharedInFlightUnits", "speculativeUnitsRetained",
        "speculativeUnitsReused", "speculativeUnitsEvictedUnused",
        "handoffDeferred", "slowTailEnqueues", "manualTranslations", "identicalFrameHolds", "warmupsDuringCapture", "handoffReplayed", "handoffExpired", "enqueueFailed",
        "actualModelBatches", "confirmedModelBatches", "speculativeModelBatches",
        "warmupModelBatches", "first30sModelBatches", "cancelledModelBatches",
        "legacyBatchEntries", "legacyBatchVerified", "legacyBatchSkipped",
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

/// Versioned, bounded, metadata-only timeline for the three-mode coordinator.
struct TranslationModeTrace: Codable {
    var mode: String? = nil
    var testMode: String? = nil
    let session: UUID
    let caption: String
    let revision: Int
    let source: String
    let target: String
    let fingerprint: String
    let reason: String
    let monotonicTime: Double
    let firstOCR: Double
    let durationMs: Double?
    let thermal: Int
}

struct TranslationModeReport: Codable {
    var warmups: [InitialWarmupEvent]? = nil
    var effectiveModelIdentity: String? = "unknown"
    var referenceVersion: String? = "1.7.2-58"
    var referenceSDK: String? = "iphoneos26.5"
    var coldSpeculationCeilingMs: Int? = 700
    var modelTimeoutMs: Int? = 4000
    var schemaVersion = 2
    let active: String
    let pending: String
    let referenceSHA: String
    let migration: String
    var events: [TranslationModeTrace]
    let distributions: [String: DiagnosticDistribution]
    let counters: [String: Int]

    /// 2.3.1: where a caption's translation came from, in words that mean the same in every mode.
    /// memory: nothing was translated, the result was stored. early: the translation started before confirmation was used.
    /// confirmed_time: the text was translated after confirmation (Legacy confirmed fresh or text changed; Low
    /// Latency recovery_success). Returns nil for reasons that are not a translation source.
    static func pathGroup(_ reason: String) -> String? {
        switch reason {
        case "pip_enqueue_memory_hit": return "memory"
        case "pip_enqueue_speculation_match_ready", "pip_enqueue_speculation_match_in_flight": return "early"
        case "pip_enqueue_confirmed_fresh", "pip_enqueue_fresh_text_changed", "pip_enqueue_legacy_recovery",
             "pip_enqueue_recovery_success": return "confirmed_time"
        default: return nil
        }
    }

    static let currentModes = ["legacy", "lowLatency"]

    static let reasons: Set<String> = [
        "speculative_model_submitted", "confirmed_model_submitted", "model_batch_failed", "model_batch_completed", "speculative_model_completed", "confirmed_model_completed",
        "cancellation_requested", "cancelled_call_returned",
        "confirmed_memory_probe_reused", "backend_apple_call_entered", "backend_apple_call_returned",
        "mode_plan_reused_ms", "mode_plan_built_ms",
        "mode_commit_to_pip_ms", "mode_confirmation_to_pip_ms", "mode_ready_to_pip_ms",
        "mode_trace_ring_overwritten",
        "strategy_cache_hit_appleDefault", "strategy_cache_hit_lowLatency",
        "strategy_cache_populated_appleDefault", "strategy_cache_populated_lowLatency",
        "memory_probe_reused",
        // 2.4.0
        "speculation_deferred_armed",
        "backend_availability_ms", "backend_task_dispatch_ms", "backend_installed_cache_hit",
        "backend_lane_wait_ms", "backend_lane_admission_rejected", "backend_stale_request_dropped",
        "backend_session_age_ms", "backend_session_reuse_count",
        "pip_held_unchanged",
        "memory_saved_ram_hit", "memory_session_hit", "memory_legacy_hit", "memory_normalized_hit", "memory_persistent_hit",
        "pip_enqueue_legacy_recovery", "pip_enqueue_fresh_text_changed", "pip_enqueue_confirmed_fresh",
        "selected_origin_compatible_memory", "selected_origin_speculation", "selected_origin_recovery",
        "selected_origin_session_low_latency", "selected_origin_session_apple_default",
        "selected_strategy_appleDefault", "selected_strategy_lowLatency", "memory_pressure", "thermal_reduced_speculation",
        "speculation_admitted", "speculation_failed", "speculation_ready", "superseded_missing",
        "speculation_superseded_before_confirmation",
        "source_correction", "speculation_match_unfinished", "memory_lookup_start", "memory_lookup_end",
        "speculative_enqueue", "recovery_enqueue", "same_strategy_retry",
        "stale_rejected", "recovery_failed_missing", "confirmed", "display_failed",
        "unsupported_os", "unsupported_or_uninstalled_pair", "requested_appleDefault", "requested_lowLatency",
        "retained_session_start", "new_session_start", "speculative_queue_ms", "recovery_queue_ms",
        "model_timeout", "model_error", "speculative_service_ms", "recovery_service_ms", "confirmed_service_ms",
        "recovery_decision_speculation_failed", "recovery_decision_matching_deadline",
        "recovery_decision_speculation_absent", "recovery_decision_source_mismatch",
        "selected_memory_hit", "selected_speculation_match_ready", "selected_speculation_match_in_flight", "selected_recovery_success",
        "pip_enqueue_memory_hit", "pip_enqueue_speculation_match_ready", "pip_enqueue_speculation_match_in_flight", "pip_enqueue_recovery_success"
    ]
    func sanitized() -> Self {
        func code(_ value: String, limit: Int = 64) -> Bool {
            !value.isEmpty && value.utf8.count <= limit && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
        }
        let safe = Array(events.suffix(6000)).filter {
            ["legacy", "lowLatency"].contains($0.mode ?? active) &&
            ["normal", "temporaryMemory", "freshRequests"].contains($0.testMode ?? "normal") &&
            Self.reasons.contains($0.reason) && code($0.caption) && code($0.source, limit: 32) && code($0.target, limit: 32) &&
            $0.fingerprint.count == 64 && $0.fingerprint.allSatisfy { $0.isHexDigit } &&
            $0.monotonicTime.isFinite && $0.firstOCR.isFinite && $0.revision >= 0 &&
            ($0.durationMs == nil || ($0.durationMs!.isFinite && $0.durationMs! >= 0)) && (0...3).contains($0.thermal)
        }
        let warmupPhases: Set<String> = ["requested_appleDefault", "requested_lowLatency", "model_submitted", "model_completed",
            "model_batch_completed", "model_batch_failed", "model_error", "model_timeout", "queue_ms", "service_ms",
            "new_session_start", "retained_session_start", "unsupported_os", "unsupported_or_uninstalled_pair",
            "backend_lane_wait_ms", "backend_lane_admission_rejected", "backend_session_age_ms", "backend_session_reuse_count",
            "cancellation_requested", "cancelled_call_returned"]
        // 2.5.0: warm-up records of a removed-mode run decode under another mode name, so they are dropped.
        let safeWarmups = Array((warmups ?? []).suffix(512)).filter {
            $0.system != .legacy && ["normal", "temporaryMemory", "freshRequests"].contains($0.testMode) &&
            code($0.source, limit: 32) && code($0.target, limit: 32) && warmupPhases.contains($0.phase) &&
            $0.monotonicTime.isFinite && $0.monotonicTime >= 0 &&
            ($0.durationMs == nil || ($0.durationMs!.isFinite && $0.durationMs! >= 0))
        }
        var samples: [String: [Double]] = [:], counts: [String: Int] = [:]
        var confirmations: [String: Double] = [:], recoveries: [String: Double] = [:]
        var strategies: [String: String] = [:], residency: [String: String] = [:]
        for event in safe {
            let identity = event.session.uuidString + event.caption + String(event.revision)
            if event.reason == "confirmed" { confirmations[identity] = event.monotonicTime }
            if event.reason.hasPrefix("recovery_decision_") { recoveries[identity] = event.monotonicTime }
            if event.reason.hasPrefix("requested_") { strategies[identity] = String(event.reason.dropFirst(10)) }
            if ["new_session_start", "retained_session_start"].contains(event.reason) { residency[identity] = event.reason }
            let cohort = (event.mode ?? active) + "_" + (event.testMode ?? "normal") + "_" + event.source + "_" + event.target + "_thermal" + String(event.thermal)
            counts[cohort + "_" + event.reason, default: 0] += 1
            if let duration = event.durationMs {
                let key = cohort + "_" + (strategies[identity] ?? "memory_or_unknown") + "_" + (residency[identity] ?? "unobserved") + "_" + event.reason
                samples[key, default: []].append(duration)
            }
            if event.reason.hasPrefix("pip_enqueue_") {
                if let confirmed = confirmations[identity] {
                    samples[cohort + "_" + event.reason + "_confirmationToEnqueue", default: []].append(max(0, event.monotonicTime - confirmed) * 1000)
                }
                if let decision = recoveries[identity] {
                    samples[cohort + "_" + event.reason + "_recoveryDecisionToEnqueue", default: []].append(max(0, event.monotonicTime - decision) * 1000)
                }
                // 2.3.1: the same three groups in every mode, summed over languages (see pathGroup).
                if let group = Self.pathGroup(event.reason) {
                    let groupKey = (event.mode ?? active) + "_" + (event.testMode ?? "normal") + "_path_" + group
                    if let duration = event.durationMs { samples[groupKey, default: []].append(duration) }
                    if let confirmed = confirmations[identity] {
                        samples[groupKey + "_confirmationToEnqueue", default: []].append(max(0, event.monotonicTime - confirmed) * 1000)
                    }
                }
            }
        }
        // Full-session totals survive bounded event-ring eviction. Only known
        // metadata reasons and numeric samples can reach the exported report.
        let sessionReasons = [
            "strategy_cache_hit_appleDefault", "strategy_cache_hit_lowLatency",
            "strategy_cache_populated_appleDefault", "strategy_cache_populated_lowLatency",
            "speculation_superseded_before_confirmation", "speculative_model_submitted", "confirmed_model_submitted",
            "pip_held_unchanged", "backend_availability_ms", "backend_task_dispatch_ms",
            "backend_installed_cache_hit", "backend_lane_wait_ms", "backend_lane_admission_rejected",
            "backend_stale_request_dropped", "backend_session_age_ms", "backend_session_reuse_count",
            "speculative_queue_ms", "recovery_queue_ms", "model_batch_completed",
            "cancelled_call_returned", "mode_trace_ring_overwritten",
            "confirmed_memory_probe_reused",
        "speculation_deferred_armed",
        ]
        // 2.5.0 (item B): a run is cleaned once when it is stored and again when a report is made from it. The first
        // pass renames each total to "session_<reason>"; the second pass looked for "<reason>" only, so every
        // whole-session total of a stored run read 0 (early starts deferred in the 2.4.0 b117 reports).
        let storedTotals = TranslationHotPathAB.reportStoredSessionTotals
        for reason in sessionReasons {
            if let count = counters[reason] ?? (storedTotals ? counters["session_" + reason] : nil), count >= 0 {
                counts["session_" + reason] = min(count, 1_000_000)
            }
        }
        let modes = ["legacy", "lowLatency"]
        for warmup in safeWarmups {
            let cohort = "warmup_" + warmup.system.rawValue + "_" + warmup.testMode + "_" + warmup.source + "_" + warmup.target + "_" + warmup.strategy.rawValue
            counts[cohort + "_" + warmup.phase, default: 0] += 1
            if let ms = warmup.durationMs { samples[cohort + "_" + warmup.phase, default: []].append(ms) }
        }
        var finalDistributions = samples.mapValues(DiagnosticDistribution.init)
        for reason in sessionReasons {
            if let sample = distributions[reason] ?? (storedTotals ? distributions["session_" + reason] : nil), sample.count >= 0,
               sample.mean.isFinite, sample.mean >= 0 {
                finalDistributions["session_" + reason] = sample
            }
        }
        return Self(warmups: safeWarmups, active: modes.contains(active) ? active : "legacy", pending: modes.contains(pending) ? pending : "legacy",
            referenceSHA: referenceSHA.count == 40 && referenceSHA.allSatisfy { $0.isHexDigit } ? referenceSHA : "unknown",
            migration: ["persisted", "explicit_low_latency", "legacy_or_ambiguous", "unknown_value_legacy",
                        TranslationSystem.migratedHybridReason].contains(migration) ? migration : "unknown",
            events: safe, distributions: finalDistributions, counters: counts)
    }
}

struct DiagnosticSessionExport: Codable, Identifiable {
    var translationModes: TranslationModeReport? = nil
    var eventSchemaVersion = 1
    var exportFormatVersion = 4
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
    var events: [StructuredDiagnosticEvent]
    /// Optional for backwards-compatible import of 1.4.0/early 1.4.1 bundles.
    var intervals: [DiagnosticIntervalBucket]? = nil
    /// Recent high-resolution data. Optional so pre-v1.5 archives still decode.
    var oneSecondIntervals: [DiagnosticIntervalBucket]? = nil
    var fiveSecondIntervals: [DiagnosticIntervalBucket]? = nil
    let measurementBoundary: String
    let textCapture: Bool
}

/// Run-level facts for the combined report (metadata only). Defined here so this file stays standalone.
struct RunReportInfo: Equatable {
    var id: UUID
    var testName: String
    var label: String
    var endReason: String
    var completeness: String
    var trimmed: [String]
    var mixedMode: Bool
}

/// Encoding, disk I/O and decode validation run away from the UI actor.
actor DiagnosticExportWriter {
}


extension DiagnosticExportWriter {
    /// Writes one Markdown report for up to six sessions, each redacted first.
    func exportCombinedReport(_ snapshots: [DiagnosticSessionExport], version: String, build: Int,
                              runs: [RunReportInfo] = []) throws -> URL {
        guard !snapshots.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        let safe = snapshots.prefix(CombinedDiagnosticReport.maximumSessions).map { redact($0) }
        let now = Date()
        let text = CombinedDiagnosticReport.markdown(Array(safe), version: version, build: build, generatedAt: now, runs: runs)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(CombinedDiagnosticReport.fileName(version: version, build: build, at: now))
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        return url
    }
}
