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
        "speculativeStopRequests", "speculativeSessionsCreated", "legacySharedSessionCalls", "memoryAwareSpeculationSkipped", "ramCaptionBypasses", "exactCaptionHits", "exactUnitsCoalesced", "sharedConfirmedInFlightUnits", "sharedInFlightUnits", "speculativeUnitsRetained",
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

    static let reasons: Set<String> = [
        "speculative_model_submitted", "confirmed_model_submitted", "model_batch_failed", "model_batch_completed", "speculative_model_completed", "confirmed_model_completed",
        "cancellation_requested", "cancelled_call_returned",
        "hybrid_speculation_throttled", "hybrid_speculation_useful", "hybrid_speculation_wasted",
        "hybrid_speculation_unexecuted",
        "hybrid_speculation_backend_busy", "hybrid_speculation_yielded_to_confirmed",
        "hybrid_matching_wait_ms", "hybrid_unsubmitted_hedge_ms",
        "confirmed_memory_probe_reused", "backend_apple_call_entered", "backend_apple_call_returned",
        "hybrid_previous_default_exit_gap_ms", "hybrid_recovery_post_default_service_ms",
        "hybrid_recovery_no_recent_overlap_service_ms", "hybrid_unexplained_slow_recovery_ms",
        "mode_plan_reused_ms", "mode_plan_built_ms",
        "mode_commit_to_pip_ms", "mode_confirmation_to_pip_ms", "mode_ready_to_pip_ms",
        "mode_trace_ring_overwritten",
        "strategy_cache_hit_appleDefault", "strategy_cache_hit_lowLatency",
        "strategy_cache_populated_appleDefault", "strategy_cache_populated_lowLatency",
        "hybrid_cross_strategy_overlap", "hybrid_default_default_overlap", "hybrid_overlapped_recovery_ms", "hybrid_simultaneous_model_overlap_ms",
        "hybrid_preserve_confirmed_session", "hybrid_hedged_recovery",
        "hybrid_obsolete_speculation_draining", "hybrid_losing_request_draining",
        "hybrid_no_fast_pack_fallback",
        "memory_probe_reused",
        "hybrid_switch_guard_default", "hybrid_switch_guard_low_latency",
        "hybrid_hedge_suppressed", "hybrid_suppressed_hedge_deadline",
        "hybrid_physical_default_drain_wait_ms", "hybrid_default_drain_completed",
        "hybrid_default_drain_budget_exceeded", "hybrid_post_default_settlement_wait_ms",
        "hybrid_slow_post_default_ms", "hybrid_default_reentered_during_settlement",
        "backend_availability_ms", "backend_task_dispatch_ms", "backend_installed_cache_hit",
        "backend_lane_wait_ms", "backend_lane_admission_rejected", "backend_stale_request_dropped",
        "backend_session_age_ms", "backend_session_reuse_count",
        "pip_held_unchanged",
        "memory_saved_ram_hit", "memory_session_hit", "memory_legacy_hit", "memory_normalized_hit", "memory_persistent_hit",
        "pip_enqueue_legacy_recovery", "pip_enqueue_confirmed_fresh",
        "selected_origin_compatible_memory", "selected_origin_speculation", "selected_origin_recovery",
        "selected_origin_session_low_latency", "selected_origin_session_apple_default",
        "selected_strategy_appleDefault", "selected_strategy_lowLatency", "memory_pressure", "thermal_reduced_speculation",
        "speculation_admitted", "speculation_failed", "speculation_ready", "superseded_missing",
        "speculation_superseded_before_confirmation",
        "source_correction", "speculation_match_unfinished", "memory_lookup_start", "memory_lookup_end",
        "speculative_enqueue", "recovery_enqueue", "same_strategy_retry", "hybrid_default_fallback",
        "stale_rejected", "recovery_failed_missing", "confirmed", "display_failed",
        "unsupported_os", "unsupported_or_uninstalled_pair", "requested_appleDefault", "requested_lowLatency",
        "retained_session_start", "new_session_start", "speculative_queue_ms", "recovery_queue_ms",
        "model_timeout", "model_error", "speculative_service_ms", "recovery_service_ms",
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
        let safe = Array(events.suffix(2400)).filter {
            ["legacy", "hybridRecovery", "lowLatency"].contains($0.mode ?? active) &&
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
            }
        }
        // Full-session totals survive bounded event-ring eviction. Only known
        // metadata reasons and numeric samples can reach the exported report.
        let sessionReasons = [
            "hybrid_speculation_throttled", "hybrid_speculation_useful", "hybrid_speculation_wasted",
        "hybrid_speculation_unexecuted",
            "hybrid_speculation_backend_busy", "hybrid_speculation_yielded_to_confirmed",
            "strategy_cache_hit_appleDefault", "strategy_cache_hit_lowLatency",
            "strategy_cache_populated_appleDefault", "strategy_cache_populated_lowLatency",
            "speculation_superseded_before_confirmation", "speculative_model_submitted", "confirmed_model_submitted",
            "hybrid_cross_strategy_overlap", "hybrid_default_default_overlap", "hybrid_overlapped_recovery_ms", "hybrid_simultaneous_model_overlap_ms",
        "hybrid_no_fast_pack_fallback",
            "pip_held_unchanged", "backend_availability_ms", "backend_task_dispatch_ms",
            "backend_installed_cache_hit", "backend_lane_wait_ms", "backend_lane_admission_rejected",
            "backend_stale_request_dropped", "backend_session_age_ms", "backend_session_reuse_count",
            "speculative_queue_ms", "recovery_queue_ms", "model_batch_completed",
            "cancelled_call_returned", "mode_trace_ring_overwritten",
            "confirmed_memory_probe_reused", "hybrid_unsubmitted_hedge_ms",
            "hybrid_previous_default_exit_gap_ms", "hybrid_recovery_post_default_service_ms",
            "hybrid_recovery_no_recent_overlap_service_ms", "hybrid_unexplained_slow_recovery_ms",
            "hybrid_switch_guard_default", "hybrid_switch_guard_low_latency",
        "hybrid_hedge_suppressed", "hybrid_suppressed_hedge_deadline",
        "hybrid_physical_default_drain_wait_ms", "hybrid_default_drain_completed",
        "hybrid_default_drain_budget_exceeded", "hybrid_post_default_settlement_wait_ms",
        "hybrid_slow_post_default_ms", "hybrid_default_reentered_during_settlement"
        ]
        for reason in sessionReasons {
            if let count = counters[reason], count >= 0 {
                counts["session_" + reason] = min(count, 1_000_000)
            }

        }
        let modes = ["legacy", "hybridRecovery", "lowLatency"]
        for warmup in safeWarmups {
            let cohort = "warmup_" + warmup.system.rawValue + "_" + warmup.testMode + "_" + warmup.source + "_" + warmup.target + "_" + warmup.strategy.rawValue
            counts[cohort + "_" + warmup.phase, default: 0] += 1
            if let ms = warmup.durationMs { samples[cohort + "_" + warmup.phase, default: []].append(ms) }
        }
        var finalDistributions = samples.mapValues(DiagnosticDistribution.init)
        for reason in sessionReasons {
            if let sample = distributions[reason], sample.count >= 0,
               sample.mean.isFinite, sample.mean >= 0 {
                finalDistributions["session_" + reason] = sample
            }
        }
        return Self(warmups: safeWarmups, active: modes.contains(active) ? active : "legacy", pending: modes.contains(pending) ? pending : "legacy",
            referenceSHA: referenceSHA.count == 40 && referenceSHA.allSatisfy { $0.isHexDigit } ? referenceSHA : "unknown",
            migration: ["persisted", "explicit_hybrid", "explicit_low_latency", "legacy_or_ambiguous", "unknown_value_legacy"].contains(migration) ? migration : "unknown",
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
            "model_state", "cancellation", "queue_wait"
        ]
        let eventCodes: Set<String> = Set(MemoryDiagnosticOutcome.allCases.map { $0.rawValue })
            .union([
                "scheduling", "observed", "cache_hit", "computed", "accepted", "rejected_duplicate",
                "rejected_recent_fragment", "rejected_empty", "rejected_revision",
                "rejected_unstable", "rejected_low_confidence", "rejected_stale",
                "filtered", "confirmed", "speculative", "ready", "enqueued",
                "cancelled", "redacted", "completed", "deferred_early_candidate",
                "heartbeat_timeout", "capture_connected", "idle_auto_pause", "session_time_limit",
                "thermal_nominal", "thermal_fair", "thermal_serious", "thermal_critical", "detail_suspended_thermal", "pip_auto_open_skipped_not_active", "pip_start_unsupported", "pip_start_not_possible", "pip_start_not_hosted", "pip_start_failed", "pip_audio_session_failed",
                "changing_group_preferred", "dominant_group", "queue_replaced",
                "preserved_confirmed_work", "confirmed_handoff_deferred",
                "adaptive_speculation_backoff", "slow_tail", "handoff_expired", "handoff_replayed", "enqueue_failed",
                "warmup_started", "warmup_succeeded", "warmup_failed",
                "warmup_model_submitted", "speculative_model_submitted", "confirmed_model_submitted", "model_batch_cancelled",
                "warmup_model_completed", "speculative_model_completed", "confirmed_model_completed",
                "model_session_created", "model_batch_completed", "model_batch_failed",
                "speculative_session_created", "speculative_stop_requested", "speculative_stop_released",
                "warmup_source_unresolved", "warmup_predicted_source", "warmup_preempted",
                "model_batch_first_30s", "legacy_batch_committed", "legacy_idle_started", "legacy_idle_completed",
                "legacy_idle_deferred", "app_interface_visible", "external_capture_period", "app_started", "capture_config_changed",
                "capture_idle", "capture_live", "capture_paused", "capture_frozen",
                "legacy_queued_speculation_superseded", "legacy_speculation_low_confidence",
                "legacy_speculation_saved_memory_backoff", "legacy_speculation_low_yield_backoff",
                // found by guard C2 in 2.2.1: emitted by the engine, accepted by Diagnostics, dropped here
                "legacy_shared_session_used", "speculative_lease_conflict"
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
            "legacyInventorySource", "legacyInventoryTarget",
            "mode", "speed", "stability", "frameRot", "area", "adaptiveOCR",
            "source", "target", "customY0", "customY1", "minTextH", "dropNoise",
            "boost", "ocrCorrection", "adaptive", "displayPolicy", "minDisplay",
            "clearHold", "autoClear", "keepWarm", "langLock",
            "selectiveSpeculation", "speculationConfidence", "confirmationDeadline",
            "remember", "privateSession", "diagnosticsEnabled", "detailedCollection",
            "skipUnchanged", "idleBackoff", "adaptiveConfirmation", "subtitleTracking",
            "translateAhead", "coolMode", "steadyCaptions", "ocrConfidence", "freshTranslationTest",
            "adaptiveSpeculation", "protectConfirmedPresentation", "predictiveWarmup",
            "lowLatencyTranslation", "incrementalBatchRecovery", "directPiPBuffer", "hybridSwitchGuard", "pixelConfirmation", "eventDrivenOCR", "fastOCR", "legacySharedSession",
            "subtitleAwareChangeDetection", "preserveRelatedMovieGroups",
            "deduplicateCopies", "contextualLanguage", "languageRecovery",
            "continuousRotation", "smartCool", "testRunSaving",
            "diagSamples", "heartbeatInterval", "keepAwake", "suppressOwnInterface",
            "temporaryMemoryTest", "translationTestMode", "startingRAMEntries",
            "rapidTextTracking", "joinAdjacentText", "activeTextFocus",
            "effectiveRapidTextTracking", "effectiveJoinAdjacentText", "effectiveActiveTextFocus",
            "thermalState", "performanceTier", "reductionReasons",
            "hotPathAB", "hybridSchedulerAB", "availabilityRefreshAB", "hybridBackoffAB", "hybridGuardAB", "detailSuspended",
            // 2.2.1 (D4, E12)
            "idleMinutes", "sessionLimit", "autoOpenPiP", "winSize", "textSize", "pipFont", "theme", "showOriginal",
            "highlightNames", "pipScale", "pipWeight", "pipAlignment", "pipPadding",
            "focusedCaptionOCR", "strictCaptionIdentity", "thermalStart", "thermalEnd", "thermalMax", "cjkSingleCharacters", "liveWarmupLegacy",
            "appRequestedCaptureIntervalMs", "appRequestedCaptureEdgePx"
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
        // Defense in depth for all top-level counters too. The live producer
        // currently uses fixed keys, but the archive boundary must not rely
        // on future callers never accidentally supplying a source-text key.
        let extraCounters: Set<String> = [
            "structured_events_dropped", "id_map_resets", "legacy_context_resets", "subtitle_traces_dropped",
            "runCheckpointCaptureMicros", "legacyInventoryPending", "legacyInventoryOtherTarget", "legacyInventoryOtherSource",
            "legacyInventoryOutsideLength", "legacyInventoryCandidates", "legacySkipKeyContext",
            "legacySkipCleanup", "legacySkipSegmentation", "legacySkipModel",
            "sessionCacheHits", "savedMemoryHits", "speculativeModelRequests",
            "supersededSpeculativePipelines", "confirmedCandidatePackets",
            "deferredEarlyCandidates", "supersededUnpresentedConfirmed",
            "enqueuedCandidateFrames", "unchangedSkippedFrames",
            "cadenceSkippedFrames", "earlyVisualWakes", "earlyVisualWakesSuppressed", "largePackets", "packetSendErrors",
            "pixelConfirmations", "pixelRejections", "watchSkippedOCR", "watchTriggeredOCR", "pausedSkippedFrames", "emptyReads",
            "contrastRetries", "emptyOCRPasses"
        ]
        let allowedCounters = DiagnosticIntervalBucket.allowedCounters
            .union(MemoryDiagnosticOutcome.allCases.map { $0.rawValue })
            .union(extraCounters)
        let safeCounters = snapshot.counters.filter {
            allowedCounters.contains($0.key) && $0.value >= 0
        }
        // The archive must not silently accept arbitrary distribution keys or
        // nonfinite caller-supplied measurements. Reconstruct from bounded,
        // known timing statistics instead of copying potentially private labels.
        let allowedMetrics: Set<String> = [
            "memoryLookupMs", "memoryWriteMs", "historySaveMs", "memoryLookupWaitMs", "memoryHealthMs", "ocrMs", "translationMs",
            "enqueueLatencyMs", "finalOCRMs", "transportMs", "confirmationMs",
            "deliveryFilteringMs", "queueMs", "processingMs", "displayHoldMs",
            "renderingMs", "speculativeModelMs", "confirmedModelMs", "modelBatchMs",
            "modeAvailabilityCheckMs", "modeTaskDispatchMs", "modeSpeculativeQueueMs", "modeRecoveryQueueMs",
            "modeBackendLaneWaitMs", "modeSessionAgeMs", "modeSessionCompletedCalls",
            "hybridDefaultWarmupMs", "hybridLowLatencyWarmupMs",
            "hybridOverlappedRecoveryMs", "hybridMeasuredOverlapMs", "modeCancellationReleaseMs",
            "modePlanBuiltMs", "modePlanReusedMs", "modeCommitToPiPMs",
            "modeConfirmationToPiPMs", "modeReadyToPiPMs", "hybridMatchingWaitMs",
            "speculativeStopReleaseMs", "queueBehindSpeculationMs", "queueBehindConfirmedMs", "queueSchedulingMs",
            "legacyConfirmedAfterSessionSwitchMs", "legacyConfirmedNoSwitchMs",
            "hybridUnsubmittedHedgeMs", "hybridPreviousDefaultExitGapMs", "hybridPostDefaultRecoveryServiceMs",
            "hybridNoOverlapRecoveryServiceMs", "hybridUnexplainedSlowRecoveryMs"
        ]
        let safeMetrics = snapshot.distributions.filter { key, value in
            allowedMetrics.contains(key) && value.count >= 0 &&
                value.mean.isFinite && value.mean >= 0 &&
                [value.p50, value.p90, value.p95, value.p99, value.maximum].allSatisfy {
                    $0 == nil || ($0!.isFinite && $0! >= 0)
                }
        }
        return DiagnosticSessionExport(translationModes: snapshot.translationModes?.sanitized(), id: snapshot.id, startedAt: snapshot.startedAt,
            endedAt: snapshot.endedAt, appVersion: snapshot.appVersion,
            systemVersion: snapshot.systemVersion, hardwareModel: safeHardware,
            settings: safeSettings,
            health: snapshot.health, counters: safeCounters,
            distributions: safeMetrics, events: safeEvents,
            intervals: snapshot.intervals.map { Array($0.suffix(960)).map { $0.sanitized() } },
            oneSecondIntervals: snapshot.oneSecondIntervals.map {
                Array($0.suffix(300)).map { $0.sanitized() }
            },
            fiveSecondIntervals: snapshot.fiveSecondIntervals.map {
                Array($0.suffix(180)).map { $0.sanitized() }
            },
            measurementBoundary: safeBoundary, textCapture: false)
    }

    /// Redacted copy for on-device storage (same allowlists as every export).
    func redactedForStorage(_ snapshot: DiagnosticSessionExport) -> DiagnosticSessionExport { redact(snapshot) }
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
            - Confirmed but superseded before enqueue: \(count("supersededUnpresentedConfirmed"))
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

            Diagnostics are bounded. Structured events cover at most 2400 retained
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


/// Controlled comparison is permitted only for matching diagnostic boundaries,
/// device OS, settings and adequate sample counts. It is not a causal claim.
struct DiagnosticPerformanceComparison {
    let comparable: Bool
    let reason: String
    let p95Changes: [String: Double]
    let medianChanges: [String: Double]
    let meanChanges: [String: Double]
    let p90Changes: [String: Double]
    /// Differences that are shown but never block a comparison (thermal path, start state, window size, ...).
    let notes: [String]

    /// 2.2.1 (D3): two runs are comparable when these settings are equal. Everything else that differs is a note.
    /// Before 2.2.1 the whole settings dictionary had to match, which included the end thermal state and the
    /// starting RAM entries, so almost every comparison was withheld.
    static let cohortKeys = [
        "mode", "speed", "stability", "area", "customY0", "customY1", "translationTestMode",
        "effectiveRapidTextTracking", "effectiveJoinAdjacentText", "effectiveActiveTextFocus",
        "hybridSwitchGuard", "pixelConfirmation", "eventDrivenOCR", "fastOCR", "legacySharedSession",
        "hotPathAB", "hybridSchedulerAB", "availabilityRefreshAB", "hybridBackoffAB", "hybridGuardAB", "detailedCollection", "performanceTier",
        "focusedCaptionOCR", "strictCaptionIdentity", "cjkSingleCharacters", "liveWarmupLegacy"
    ]
    static let noteKeys = [
        "thermalStart", "thermalEnd", "thermalMax", "appRequestedCaptureIntervalMs", "appRequestedCaptureEdgePx",
        "startingRAMEntries", "winSize", "showOriginal"
    ]

    /// The cohort keys whose values differ between two runs (a missing value counts as "–").
    static func cohortMismatches(_ a: DiagnosticSessionExport, _ b: DiagnosticSessionExport) -> [String] {
        cohortKeys.filter { (a.settings[$0] ?? "–") != (b.settings[$0] ?? "–") }
    }

    static func differenceNotes(_ a: DiagnosticSessionExport, _ b: DiagnosticSessionExport) -> [String] {
        var notes = noteKeys.compactMap { key -> String? in
            let x = a.settings[key] ?? "–", y = b.settings[key] ?? "–"
            return x == y ? nil : "\(key): \(x) -> \(y)"
        }
        if a.appVersion != b.appVersion { notes.append("app version: \(a.appVersion) -> \(b.appVersion)") }
        return notes
    }

    init(baseline: DiagnosticSessionExport, current: DiagnosticSessionExport) {
        notes = Self.differenceNotes(baseline, current)
        guard let baselineModel = baseline.hardwareModel, !baselineModel.isEmpty,
              baselineModel == current.hardwareModel,
              baseline.systemVersion == current.systemVersion,
              baseline.measurementBoundary == current.measurementBoundary,
              Self.cohortMismatches(baseline, current).isEmpty
        else {
            comparable = false
            let mismatches = Self.cohortMismatches(baseline, current)
            reason = mismatches.isEmpty
                ? "Hardware model, OS or measurement boundaries differ or are unavailable; comparison withheld"
                : "Settings that change the result differ (" + mismatches.joined(separator: ", ") + "); comparison withheld"
            p95Changes = [:]
            medianChanges = [:]; meanChanges = [:]; p90Changes = [:]
            return
        }
        var differences: [String: Double] = [:]
        var medians: [String: Double] = [:], means: [String: Double] = [:], p90s: [String: Double] = [:]
        func change(_ before: Double?, _ after: Double?) -> Double? {
            guard let before, let after, before.isFinite, before > 0, after.isFinite else { return nil }
            return 100 * (after - before) / before
        }
        for name in baseline.distributions.keys.sorted() {
            guard let before = baseline.distributions[name],
                  let after = current.distributions[name],
                  before.count >= 20, after.count >= 20,
                  let baselineP95 = before.p95, baselineP95 > 0,
                  let currentP95 = after.p95, currentP95.isFinite else { continue }
            differences[name] = 100 * (currentP95 - baselineP95) / baselineP95
            medians[name] = change(before.p50, after.p50)
            means[name] = change(before.mean, after.mean)
            p90s[name] = change(before.p90, after.p90)
        }
        p95Changes = differences
        medianChanges = medians; meanChanges = means; p90Changes = p90s
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
        // Evidence is limited to recognized candidates. We cannot measure
        // subtitles that OCR never saw or whether iOS actually painted a frame.
        let confirmed = max(0, session.counters["confirmedCandidatePackets", default: 0])
        let unpresented = max(0, session.counters["supersededUnpresentedConfirmed", default: 0])
        if confirmed >= 20 && unpresented >= 3 &&
           Double(unpresented) / Double(confirmed) >= 0.05 {
            add("confirmed_continuity_loss", "suspected", unpresented,
                "Confirmed candidate work was superseded before PiP enqueue. This is not a ground-truth missed-subtitle rate.")
        }
        // 2.2.1 (D7): findings about how trustworthy the run itself is.
        let captionsShown = session.counters["enqueuedCandidateFrames", default: 0]
        let hasTiming = session.distributions["enqueueLatencyMs"] != nil
        if captionsShown > 0, !hasTiming, session.settings["detailedCollection"] != "true" {
            add("detailed_collection_off", "observed", captionsShown,
                "Detailed collection was off, so this run has no latency distribution. Turn it on in Diagnostics and run again.")
        }
        if session.settings["detailSuspended"] == "true" {
            add("detail_suspended_thermal", "observed", 1,
                "Detailed collection was requested but the phone reached Serious or Critical thermal state and switched it off. Later parts of the run have no timing.")
        }
        let manualCount = session.counters["manualTranslations", default: 0]
        if manualCount > 0 {
            add("manual_translations_in_run", "observed", manualCount,
                "Compose, photo/file or language-pair translations ran during this run. They are counted apart and not in the latency totals.")
        }
        let runSeconds = session.endedAt.timeIntervalSince(session.startedAt)
        // A zero length means the export carries no duration at all, which is not the same as a short run.
        if (captionsShown > 0 || hasTiming), runSeconds > 0, runSeconds < 180 {
            add("short_run", "observed", Int(runSeconds),
                "The run was shorter than 3 minutes. Percentiles from so little time move a lot between runs.")
        }
        let failedEnqueues = max(0, session.counters["enqueueFailed", default: 0])
        if failedEnqueues > 0 {
            add("pip_enqueue_failure", "observed", failedEnqueues,
                "The PiP renderer rejected one or more buffer enqueue attempts. A successful retry may have followed.")
        }
        // 2.2.1 (D7, suspected): the old rule (P95 > max(1800, 2.5 x median)) never flagged Hybrid's 1.5 s tail.
        if let enqueue = session.distributions["enqueueLatencyMs"], enqueue.count >= 20,
           let median = enqueue.p50, median > 0,
           let p95 = enqueue.p95, p95 > max(1000, median * 2) {
            add("enqueue_slow_tail", "suspected", enqueue.count,
                "OCR-to-PiP enqueue P95 is high relative to the median. Examine slow intervals and candidate handoffs.")
        }
        if let enqueue = session.distributions["enqueueLatencyMs"], enqueue.count >= 20,
           let median = enqueue.p50, median >= 1200 {
            add("enqueue_typical_latency", "suspected", enqueue.count,
                "Typical OCR-to-PiP enqueue time is high, even if the slowest tail has improved.")
        }
        // Detect sustained expensive Hybrid recovery separately from physical
        // overlap; the two values answer different performance questions.
        let recovery = session.distributions["hybridOverlappedRecoveryMs"]
        if let recovery, recovery.count >= 3,
           let measured = recovery.p95 ?? recovery.p50, measured >= 1000 {
            let statistic = recovery.p95 == nil ? "median" : "P95"
            add("hybrid_slow_recovery", "observed", recovery.count,
                "Hybrid full recovery \(statistic) is >=1000ms over \(recovery.count) observed samples. Percentiles below 20 samples are unavailable; these are service durations, not simultaneous model occupancy.")
        }
        // A confirmed Hybrid long tail can occur without an overlap-at-start
        // flag, so examine all Hybrid confirmed calls separately as well.
        if session.translationModes?.active == "hybridRecovery",
           let confirmed = session.distributions["confirmedModelMs"],
           confirmed.count >= 20, let tail = confirmed.p95, tail >= 1000 {
            add("hybrid_confirmed_long_tail", "observed", confirmed.count,
                "Hybrid confirmed-model P95 exceeds 1000ms with at least 20 measured calls. This does not by itself establish physical model contention.")
        }
        let fallbacks = session.translationModes?.counters["hybrid_default_fallback"] ?? 0
        let recoveryDecisions = session.translationModes?.counters
            .filter { $0.key.hasPrefix("recovery_decision_") }
            .values.reduce(0, +) ?? 0
        if fallbacks >= 3 && recoveryDecisions >= 6 &&
           Double(fallbacks) / Double(recoveryDecisions) >= 0.25 {
            add("hybrid_fallback_storm", "suspected", fallbacks,
                "At least a quarter of the observed Hybrid recovery decisions needed Apple Default fallback. Verify fast-language assets and error events.")
        }
        let defaultDefault = session.translationModes?.counters["hybrid_default_default_overlap"] ?? 0
        if defaultDefault > 0 {
            add("hybrid_default_default_overlap", "observed", defaultDefault,
                "A confirmed Apple Default request started while the speculative lane was also running Apple Default. Compare the confirmation time of these captions with the others.")
        }
        let observedOverlap = session.translationModes?.counters["hybrid_cross_strategy_overlap"] ?? 0
        let measuredOverlap = session.distributions["hybridMeasuredOverlapMs"]?.count ?? 0
        if observedOverlap >= 3 && measuredOverlap == 0 {
            add("hybrid_missing_overlap_measurement", "observed", observedOverlap,
                "Hybrid cross-strategy overlap was reported but no physical-overlap duration was measured. Inspect backend telemetry.")
        }
        return findings
    }
}

/// Minimal ZIP writer using uncompressed entries, avoiding network dependencies.
/// Fixed entry names prevent path traversal; 4 MiB cap keeps export bounded.
/// The ZIP CRC32 and central directory are verified by standard ZIP readers.
enum DiagnosticStoredZIP {
    static func make(entries: [(name: String, contents: Data)]) throws -> Data {
        guard !entries.isEmpty, entries.count <= 12 else { throw CocoaError(.fileWriteUnknown) }
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
        "freshTranslation", "translationResult", "model_state", "queue_wait"
    ]
    private static let allowedReasons: Set<String> = [
        "accepted", "rejected_duplicate", "rejected_recent_fragment",
        "rejected_empty", "rejected_revision", "rejected_unstable",
        "rejected_low_confidence", "rejected_stale", "filtered", "deferred_early_candidate",
        "heartbeat_timeout", "capture_connected", "idle_auto_pause", "session_time_limit",
        "thermal_nominal", "thermal_fair", "thermal_serious", "thermal_critical", "detail_suspended_thermal", "pip_auto_open_skipped_not_active", "pip_start_unsupported", "pip_start_not_possible", "pip_start_not_hosted", "pip_start_failed", "pip_audio_session_failed",
        "confirmed", "speculative", "ready", "enqueued", "cancelled",
        "legacy_queued_speculation_superseded", "legacy_speculation_low_confidence",
        "legacy_speculation_saved_memory_backoff", "legacy_speculation_low_yield_backoff",
        // found by guard C2 in 2.2.1: recorded by Diagnostics but missing from the trace review
        "confirmed_handoff_deferred", "handoff_expired", "handoff_replayed", "preserved_confirmed_work",
        "observed", "cache_hit", "computed", "ramHit", "persistentHit",
        "legacyHit", "normalizedHit", "speculativeHit", "miss", "timeout",
        "compatibilityRejected", "databaseUnavailable", "persisted",
        "writeFailed", "ramEviction", "other", "incompatible", "conflict",
        "enqueue_failed", "slow_tail", "confirmed_model_submitted", "confirmed_model_completed",
        "speculative_model_submitted", "speculative_model_completed", "model_batch_completed",
        "model_batch_failed", "model_batch_cancelled", "scheduling", "app_interface_visible", "external_capture_period"
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
            let successfulEnqueue = stages.contains {
                $0.stage == "enqueued" || ($0.stage == "pip_enqueue" &&
                    ["enqueued", "completed", "slow_tail"].contains($0.reason))
            }
            if successfulEnqueue {
                state = "PiP buffer enqueued (physical display unverified)"
            } else if stages.contains(where: { $0.stage == "pip_enqueue" && $0.reason == "enqueue_failed" }) {
                state = "PiP frame preparation or enqueue failed"
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
        var guardGapMs: Double?
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
        /// 2.2.1 (D9): per caption ref, the gap since the previous Default call ended and whether Low Latency
        /// started while a Default call was still running. Both come from events that already exist.
        var exitGaps: [String: Double] = [:]
        var overlapped = Set<String>()
    }

    /// 2.2.1 (D9): bands for the Hybrid question "does the Low Latency recovery cost more right after Default?".
    static let hybridBandNames = ["in flight", "0-150 ms", "150-500 ms", "500-1500 ms", "none/older"]

    static func hybridBand(overlapped: Bool, gapMs: Double?) -> String {
        if overlapped { return "in flight" }
        guard let gap = gapMs, gap >= 0 else { return "none/older" }
        if gap < 150 { return "0-150 ms" }
        if gap < 500 { return "150-500 ms" }
        if gap < 1500 { return "500-1500 ms" }
        return "none/older"
    }

    /// Low Latency confirmed-lane service time per band, paired by caption.
    static func hybridBands(_ parsed: Parsed) -> [(band: String, n: Int, median: Double?, max: Double?)] {
        let calls = parsed.calls.filter { $0.lane == "confirmed" && $0.strategy == "lowLatency" }
        var byBand: [String: [Double]] = [:]
        for call in calls {
            let band = hybridBand(overlapped: parsed.overlapped.contains(call.caption), gapMs: parsed.exitGaps[call.caption])
            byBand[band, default: []].append(call.serviceMs)
        }
        return hybridBandNames.map { name in
            let values = byBand[name] ?? []
            return (name, values.count, median(values), values.max())
        }
    }

    /// Rebuild model calls, caption timelines and Hybrid decisions from the
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
            case "speculative_service_ms", "recovery_service_ms":
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
            case "hybrid_previous_default_exit_gap_ms":
                if let gap = event.durationMs { parsed.exitGaps[ref] = gap }
            case "hybrid_cross_strategy_overlap":
                parsed.overlapped.insert(ref)
            case "hybrid_switch_guard_default":
                row.recoveryStrategy = "appleDefault"; row.guardGapMs = event.durationMs
            case "hybrid_switch_guard_low_latency":
                row.recoveryStrategy = "lowLatency"; row.guardGapMs = event.durationMs
            case "hybrid_no_fast_pack_fallback":
                row.recoveryStrategy = "appleDefault"
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
            if reason.hasPrefix("hybrid_") || reason.hasPrefix("recovery_decision_") {
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
        let selected = Array(sessions.sorted { $0.startedAt < $1.startedAt }.prefix(maximumSessions))
        let labels = selected.indices.map { "S\($0 + 1)" }
        let parsed = selected.indices.map { parse(selected[$0].translationModes, label: labels[$0]) }
        var out: [String] = []
        out.append("# ScreenLingo test report")
        out.append("")
        out.append("App \(version) build \(build) · generated \(generatedAt.ISO8601Format()) · \(selected.count) session(s)")
        out.append("Boundary: first OCR sighting → PiP enqueue (not physical display). Metadata only: no subtitle, OCR or translated text.")
        out.append("")
        out.append("## 1. Sessions")
        out.append("")
        out.append("| | mode | started | min | device | iOS | pair | preset | speed | memory | RAM at start | rapid/join/focus | switch guard | pixel/watch/fast OCR |")
        out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for (i, session) in selected.enumerated() {
            let s = session.settings
            let pair = session.translationModes?.events.first.map { "\($0.source)>\($0.target)" } ??
                "\(s["source"] ?? "?")>\(s["target"] ?? "?")"
            let minutes = max(0, session.endedAt.timeIntervalSince(session.startedAt)) / 60
            let ram = Int(s["startingRAMEntries"] ?? "") ?? 0
            let switches = ["effectiveRapidTextTracking", "effectiveJoinAdjacentText", "effectiveActiveTextFocus"]
                .map { s[$0] ?? "?" }.joined(separator: "/")
            out.append("| \(labels[i]) | \(session.translationModes?.active ?? "unknown") | \(session.startedAt.ISO8601Format()) | \(String(format: "%.1f", minutes)) | \(session.hardwareModel ?? "?") | \(session.systemVersion) | \(pair) | \(s["mode"] ?? "?") | \(s["speed"] ?? "?") | \(s["translationTestMode"] ?? "?") | \(ram)\(ram > 0 ? " ⚠️" : "") | \(switches) | \(s["hybridSwitchGuard"] ?? "default") | \(s["pixelConfirmation"] ?? "-")/\(s["eventDrivenOCR"] ?? "-")/\(s["fastOCR"] ?? "-") |")
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
        out.append("| | hot path | Hybrid scheduler | detailed | thermal start/end/max | focused/strict | identical-frame holds | manual | memory wait P50/P95 | health P50/P95 | memory timeouts |")
        out.append("|---|---|---|---|---|---|---|---|---|---|---|")
        for (i, session) in selected.enumerated() {
            let s = session.settings
            out.append("| \(labels[i]) | \(s["hotPathAB"] ?? "?") | \(s["hybridSchedulerAB"] ?? "?") | \(s["detailedCollection"] ?? "?")\(s["detailSuspended"] == "true" ? " (suspended: thermal)" : "") | \(s["thermalStart"] ?? "?")/\(s["thermalEnd"] ?? "?")/\(s["thermalMax"] ?? "?") | \(s["focusedCaptionOCR"] ?? "?")/\(s["strictCaptionIdentity"] ?? "?") | \(session.counters["identicalFrameHolds", default: 0]) | \(session.counters["manualTranslations", default: 0]) | \(ms(session.distributions["memoryLookupWaitMs"]?.p50))/\(ms(session.distributions["memoryLookupWaitMs"]?.p95)) | \(ms(session.distributions["memoryHealthMs"]?.p50))/\(ms(session.distributions["memoryHealthMs"]?.p95)) | \(memoryTimeoutShare(session)) |")
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
        out.append("session,caption_ref,first_ocr_ms,confirmed_ms,selected_ms,pip_ms,ocr_to_pip_ms,reason,origin,strategy,recovery_strategy,guard_gap_ms")
        for row in parsed.flatMap({ $0.captions }) {
            let total: String
            if let pip = row.pipMs, let first = row.firstOCRMs { total = ms(pip - first) } else { total = "" }
            out.append("\(row.session),\(row.caption),\(row.firstOCRMs.map { ms($0) } ?? ""),\(row.confirmedMs.map { ms($0) } ?? ""),\(row.selectedMs.map { ms($0) } ?? ""),\(row.pipMs.map { ms($0) } ?? ""),\(total),\(row.reason),\(row.origin),\(row.strategy),\(row.recoveryStrategy),\(row.guardGapMs.map { ms($0) } ?? "")")
        }
        out.append("```")

        out.append("")
        out.append("## 6. Hybrid and recovery decisions")
        out.append("")
        out.append("```csv")
        out.append("session,caption_ref,t_ms,reason,value_ms")
        for row in parsed.flatMap({ $0.decisions }) {
            out.append("\(row.session),\(row.caption),\(ms(row.timeMs)),\(row.reason),\(row.valueMs.map { ms($0) } ?? "")")
        }
        out.append("```")

        // 2.2.1 (D9): Low Latency recovery service by how recently a Default call ran (same 1.5 s window as the build 74-81 analysis).
        out.append("")
        out.append("Low Latency recovery service by distance from the previous Default call (paired by caption):")
        out.append("")
        out.append("| | band | n | median | max |")
        out.append("|---|---|---|---|---|")
        for i in selected.indices where selected[i].translationModes?.active == "hybridRecovery" {
            for row in hybridBands(parsed[i]) {
                out.append("| \(labels[i]) | \(row.band) | \(row.n) | \(ms(row.median)) | \(ms(row.max)) |")
            }
        }

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
            out.append("- \(labels[i]): \(retained) mode events retained\(retained >= 2400 ? " (2,400 cap reached; early events missing)" : ""), \(overwritten) overwritten; \(session.events.count) structured events retained. Whole-session counters are not truncated.")
            // 2.2.1 (D6): what the bounded buffers dropped, so a short event list is never mistaken for a quiet run.
            let c = session.counters
            out.append("  - dropped: \(c["structured_events_dropped", default: 0]) structured events, \(c["id_map_resets", default: 0]) correlation-ID map resets, \(c["legacy_context_resets", default: 0]) Legacy context resets, \(c["subtitle_traces_dropped", default: 0]) subtitle traces.")
        }
        out.append("")
        return out.joined(separator: "\n")
    }
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
