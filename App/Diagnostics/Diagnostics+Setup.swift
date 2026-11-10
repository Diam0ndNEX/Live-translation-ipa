import CryptoKit
import SwiftUI
import Charts
import os
import Darwin

extension Diagnostics {
    static var hardwareModelCode: String {
        var machine = utsname()
        _ = uname(&machine)
        // The hw.machine family code is not a device name or unique identifier.
        return withUnsafeBytes(of: &machine.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    var isRunPaused: Bool { activeRun != nil && pausedAt != nil }
    /// Seconds with capture off inside the current run. Left out of the run duration and of Time live.
    var pausedSeconds: TimeInterval { pausedTotal + (pausedAt.map { Date().timeIntervalSince($0) } ?? 0) }
    struct ActiveRun {
        let id: UUID
        let startedAt: Date
        let mode: String
        var modeChanges: [String] = []
        var startingRAMEntries: Int
        var lastCheckpointAt: Date
    }
    struct RunBanner: Identifiable {
        let id = UUID()
        let result: TestRunSaveResult
        let mode: String
        let seconds: Double
        let at = Date()
    }
    /// App-to-extension configuration, not a claim about actual Vision cadence.
    func noteCapturePolicy(edge: Double, interval: Double, coolMode: Bool,
                           memoryPressure: Bool, workloadPressure: Bool) {
        requestedCaptureEdgePx = max(0, Int(edge))
        requestedCaptureIntervalMs = max(0, Int((interval * 1000).rounded()))
        captureReductionReasons = ThermalPerformancePolicy.reductionReasons(
            state: ProcessInfo.processInfo.thermalState, coolMode: coolMode,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            memoryPressure: memoryPressure, workloadPressure: workloadPressure)
    }
    struct CostToken { let start: Double; let outer: Bool; let detailed: Bool }
    func beginRecorder() -> CostToken? {
        guard enabled else { return nil }
        recorderDepth += 1
        return CostToken(start: ProcessInfo.processInfo.systemUptime, outer: recorderDepth == 1, detailed: detailedCollection)
    }
    func endRecorder(_ token: CostToken?) {
        guard let token else { return }
        recorderDepth -= 1
        if token.outer { recorderCosts.record(ms: (ProcessInfo.processInfo.systemUptime-token.start)*1000, detailed: token.detailed) }
    }
    func stableCandidateID(_ candidate: String?) -> UUID? {
        guard let candidate else { return nil }
        if let existing = candidateIDs[candidate] { return existing }
        if candidateIDs.count >= 6000 { candidateIDs.removeAll(keepingCapacity: true); idMapResets += 1 }
        let id = UUID()
        candidateIDs[candidate] = id
        return id
    }

    private func stableFrameID(_ index: Int?) -> UUID? {
        guard let index else { return nil }
        if let id = frameIDs[index] { return id }
        if frameIDs.count >= 6000 { frameIDs.removeAll(keepingCapacity: true); idMapResets += 1 }
        let id = UUID(); frameIDs[index] = id
        return id
    }

    private func stableUnitID(_ canonicalKey: String?) -> UUID? {
        guard let canonicalKey else { return nil }
        if let id = unitIDs[canonicalKey] { return id }
        if unitIDs.count >= 6000 { unitIDs.removeAll(keepingCapacity: true); idMapResets += 1 }
        let id = UUID(); unitIDs[canonicalKey] = id
        return id
    }

    func trace(_ candidate: String?, stage: String, detail: String, at time: Date = Date(),
               frameIndex: Int? = nil) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard detailedCollection, let candidate else { return }
        // Never export a caller's identifier: historical candidates can encode input text.
        guard let safeID = stableCandidateID(candidate) else { return }
        let stages: Set<String> = [
            "first OCR", "seen", "confirmed", "processing", "speculating", "cache",
            "ready", "enqueued", "superseded", "memory", "cancelled",
            "ocrCorrection", "language", "segmentation", "freshTranslation",
            "translationResult"
        ]
        let safeStage = stages.contains(stage) ? stage : "other"
        appendStructured(candidate: safeID, frameIndex: frameIndex, stage: safeStage,
                         outcome: "observed", reason: safeStage, durationMs: nil, at: time)
        subtitleTraces.append(SubtitleTrace(candidate: safeID.uuidString, stage: safeStage, time: time, detail: detail))
        if subtitleTraces.count > 300 {
            subtitleTracesDropped += subtitleTraces.count - 300
            subtitleTraces.removeFirst(subtitleTraces.count - 300)
        }
    }


    /// Correlates a processing/rejection decision to the frame and candidate.
    /// Reason codes and stages are hard-coded allowlists; raw OCR/source text,
    /// user-provided candidate identifiers and paths never reach the archive.
    func notePipelineDecision(candidate: String?, frameIndex: Int?,
                              stage: String, reason: String, durationMs: Double? = nil) {
        guard detailedCollection else { return }
        let allowedStages: Set<String> = [
            "frame_arrival", "rotation", "ocr_execution", "duplicate_detection", "ocr_filtering",
            "stability", "text_grouping", "ocr_correction", "language_detection",
            "segmentation", "memory_lookup", "translation", "pip_preparation",
            "pip_enqueue", "model_state", "cancellation"
        ]
        let allowedReasons: Set<String> = [
            "accepted", "completed", "rejected_duplicate", "rejected_recent_fragment",
            "rejected_empty", "rejected_revision", "rejected_unstable",
            "rejected_low_confidence", "rejected_stale", "filtered", "deferred_early_candidate",
            "preserved_confirmed_work", "confirmed_handoff_deferred",
            "adaptive_speculation_backoff", "slow_tail", "handoff_expired", "handoff_replayed", "enqueue_failed",
            "changing_group_preferred", "dominant_group", "queue_replaced",
            "confirmed", "speculative", "ready", "enqueued", "cancelled",
            // 2.2.1 (E10): why Legacy declined a speculation (the engine already emitted these; the allowlist dropped them)
            "legacy_speculation_low_confidence", "legacy_speculation_saved_memory_backoff", "legacy_speculation_low_yield_backoff"
        ]
        guard allowedStages.contains(stage), allowedReasons.contains(reason) else { return }
        let token = beginRecorder(); defer { endRecorder(token) }
        appendStructured(candidate: stableCandidateID(candidate), frameIndex: frameIndex,
                         stage: stage, outcome: reason, reason: reason, durationMs: durationMs)
    }

    /// Bounded, privacy-safe segmentation timing. Source text and cache keys are
    /// never stored in structured events; only opaque candidate IDs are emitted.
    /// Keep state transitions even when there is no OCR candidate. This is how
    /// 'translation suddenly stopped' can be distinguished from missed text.
    func noteRuntimeState(_ reason: String) {
        guard enabled else { return }
        let allowed: Set<String> = [
            "heartbeat_timeout", "capture_connected", "idle_auto_pause", "session_time_limit",
            "app_started", "app_interface_visible", "external_capture_period", "capture_config_changed", "capture_idle", "capture_live",
            "capture_paused", "capture_frozen",
            "thermal_nominal", "thermal_fair", "thermal_serious", "thermal_critical", "detail_suspended_thermal",
            "pip_auto_open_skipped_not_active",
            "pip_start_unsupported", "pip_start_not_possible", "pip_start_not_hosted", "pip_start_failed", "pip_audio_session_failed"
        ]
        guard allowed.contains(reason) else { return }
        appendStructured(stage: "runtime_state", outcome: reason, reason: reason,
                         durationMs: nil)
    }

    /// Only count events after the selection is known; never record the label text.
    func noteMovieSelection(groups: Int, filteredSmall: Int, temporalOverride: Bool,
                            confirmed: Bool) {
        guard enabled, confirmed else { return }
        s.movieSelections += 1
        s.movieRejectedSmall += max(0, filteredSmall)
        if temporalOverride {
            s.movieTemporalOverrides += 1
            if detailedCollection {
                appendStructured(stage: "text_grouping", outcome: "changing_group_preferred",
                    reason: "changing_group_preferred", durationMs: nil)
            }
        } else if detailedCollection && groups > 1 && s.movieSelections % 24 == 0 {
            // Sample aggregate selections; avoid flooding the short candidate ring.
            appendStructured(stage: "text_grouping", outcome: "dominant_group",
                reason: "dominant_group", durationMs: nil)
        }
    }

    /// Aggregate-only idle reconciliation performance. Never export source
    /// sentences, translated outputs, memory keys, or device identifiers.
    func noteLegacyBatch(selected: Int, committed: Int, skipped: Int,
                         workers: Int, durationMs: Double) {
        guard enabled else { return }
        s.legacyBatchEntries += max(0, selected)
        s.legacyBatchVerified += max(0, committed)
        s.legacyBatchSkipped += max(0, skipped)
        s.legacyBatchPeakWorkers = max(s.legacyBatchPeakWorkers, max(0, workers))
        if durationMs.isFinite && durationMs >= 0 { s.legacyBatchElapsedMs += durationMs }
        noteModelState("legacy_batch_committed", durationMs: durationMs)
    }

    func recordLegacyValidationSnapshot(inventory: [String: Int], reasons: [String: Int], source: String, target: String) {
        guard enabled else { return }
        let inventoryKeys = ["Pending legacy records": "legacyInventoryPending",
            "Different target language": "legacyInventoryOtherTarget",
            "Different source language": "legacyInventoryOtherSource",
            "Outside 4–240 character range": "legacyInventoryOutsideLength",
            "Scan candidates before safety checks": "legacyInventoryCandidates"]
        let reasonKeys = ["Unreadable key or protected context": "legacySkipKeyContext",
            "Needs cleanup or slang review": "legacySkipCleanup",
            "Needs sentence-unit review": "legacySkipSegmentation",
            "Language model unavailable": "legacySkipModel"]
        legacyValidationSnapshot = [:]
        for (label, key) in inventoryKeys { legacyValidationSnapshot[key] = max(0, inventory[label, default: 0]) }
        for (label, key) in reasonKeys { legacyValidationSnapshot[key] = max(0, reasons[label, default: 0]) }
        legacyValidationPair = ["legacyInventorySource": source, "legacyInventoryTarget": target]
    }

    func noteTemporaryReuse(count: Int = 1) {
        guard enabled else { return }
        temporaryMemoryHits += max(0, count)
    }

    func noteSharedModelUnits(_ count: Int, confirmed: Bool = false) {
        guard enabled else { return }
        sharedModelUnits += max(0, count)
        if confirmed { sharedConfirmedModelUnits += max(0, count) }
    }
    func noteMemoryAwareSpeculationSkip() {
        guard enabled else { return }
        memoryAwareSpeculationSkipped += 1
    }
    func noteRAMCaptionBypass() {
        guard enabled else { return }
        ramCaptionBypasses += 1
    }
    func noteExactCaptionReuse() {
        guard enabled else { return }
        exactCaptionHits += 1
    }
    func noteExactUnitCoalescing(_ count: Int) {
        guard enabled else { return }
        exactUnitsCoalesced += max(0, count)
    }
    func noteSpeculativeUnit(_ outcome: String) {
        guard enabled, ["retained", "reused", "evictedUnused"].contains(outcome) else { return }
        speculativeUnitCounts[outcome, default: 0] += 1
    }
    /// 2.3.0: a confirmed, not yet enqueued caption was replaced by a different confirmed caption. Records whether its
    /// translation had started and how long it had been confirmed. Counts and one bounded sample list only.
    func noteConfirmedSupersession(workStarted: Bool, ageMs: Double) {
        guard enabled, ageMs.isFinite, ageMs >= 0 else { return }
        if workStarted { s.supersededConfirmedInFlight += 1 } else { s.supersededConfirmedNotStarted += 1 }
        modelTimingSamples["confirmed_superseded_age_ms", default: []].append(ageMs)
        if modelTimingSamples["confirmed_superseded_age_ms", default: []].count > 1200 {
            modelTimingSamples["confirmed_superseded_age_ms"]?.removeFirst()
        }
    }
    /// 2.3.2: live read of this session's enqueue-path counts and superseded-confirmation ages for the in-app tabs.
    /// Same names as the exported report. Counts since the last reset.
    func enqueuePathCount(_ reason: String) -> Int { modeEventCounts["pip_enqueue_" + reason, default: 0] }
    var confirmedSupersededAges: Summary {
        let values = modelTimingSamples["confirmed_superseded_age_ms", default: []]
        return Diagnostics.summarize(values.map { Sample(t: Date(), v: $0) })
    }
    func recordQueueWait(owner: ModelQueueOwner, durationMs: Double, candidate: String?) {
        guard enabled, durationMs.isFinite, durationMs >= 0 else { return }
        queueWaitSamples[owner, default: []].append(durationMs)
        if queueWaitSamples[owner, default: []].count > 1200 { queueWaitSamples[owner]?.removeFirst() }
        appendStructured(candidate: stableCandidateID(candidate), stage: "queue_wait",
                         outcome: owner.rawValue, reason: owner.rawValue, durationMs: durationMs)
    }

    func noteCompletedWorkRecovery(_ count: Int) {
        guard enabled else { return }
        completedWorkRecoveredUnits += max(0, count)
    }

    func noteModelState(_ reason: String, durationMs: Double? = nil, candidate: String? = nil) {
        guard enabled else { return }
        let allowed: Set<String> = [
            "warmup_started", "warmup_succeeded", "warmup_failed",
            "warmup_model_submitted", "speculative_model_submitted", "confirmed_model_submitted", "model_batch_cancelled",
            "warmup_model_completed", "speculative_model_completed", "confirmed_model_completed",
            "model_session_created", "model_batch_failed", "model_batch_completed",
            "speculative_session_created", "speculative_stop_requested", "speculative_stop_released",
            "warmup_source_unresolved", "warmup_predicted_source", "warmup_preempted",
            "model_batch_first_30s", "legacy_batch_committed", "legacy_idle_started",
            "legacy_idle_completed", "legacy_idle_deferred",
            "legacy_confirmed_after_switch", "legacy_confirmed_no_switch", "legacy_shared_session_used", "speculative_lease_conflict",
            "legacy_queued_speculation_superseded", // 2.2.1 (E10): was emitted by the engine but dropped here
            "legacy_confirmed_own_lane", "legacy_detached_speculation_released" // 2.2.3 (L2)
        ]
        guard allowed.contains(reason) else { return }
        if modeActiveSystem == "legacy", let candidate {
            if reason == "confirmed_model_submitted" {
                legacyModeContexts[candidate]?.fresh = true
                legacyModeEvent(candidate, reason: "requested_appleDefault")
            }
            if reason == "speculative_model_submitted" { legacyModeEvent(candidate, reason: "requested_appleDefault") }
            // 2.3.0: was "recovery_service_ms". In Legacy this is the ordinary confirmed model call, not a recovery.
            if reason == "confirmed_model_completed" { legacyModeEvent(candidate, reason: "confirmed_service_ms", duration: durationMs) }
            if reason == "speculative_model_completed" { legacyModeEvent(candidate, reason: "speculative_service_ms", duration: durationMs) }
        }
        if ["model_batch_completed", "confirmed_model_completed", "speculative_model_completed", "speculative_stop_released", "legacy_detached_speculation_released",
            "legacy_confirmed_after_switch", "legacy_confirmed_no_switch"].contains(reason),
           let durationMs, durationMs.isFinite, durationMs >= 0 {
            modelTimingSamples[reason, default: []].append(durationMs)
            if modelTimingSamples[reason, default: []].count > 1200 {
                modelTimingSamples[reason]?.removeFirst()
            }
        }
        appendStructured(candidate: stableCandidateID(candidate), stage: "model_state", outcome: reason, reason: reason,
            durationMs: durationMs)
    }

    func noteQueueReplacement() {
        guard enabled else { return }
        s.queueReplacements += 1
        if detailedCollection {
            appendStructured(stage: "cancellation", outcome: "queue_replaced",
                reason: "queue_replaced", durationMs: nil)
        }
    }

    func noteThermalState() {
        guard enabled else { return }
        let currentLevel = ProcessInfo.processInfo.thermalState.rawValue
        if thermalStartLevel == nil { thermalStartLevel = currentLevel }
        thermalMaxLevel = max(thermalMaxLevel, currentLevel)
        let reason: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: reason = "thermal_nominal"
        case .fair: reason = "thermal_fair"
        case .serious: reason = "thermal_serious"
        case .critical: reason = "thermal_critical"
        @unknown default: return
        }
        let hot = reason == "thermal_serious" || reason == "thermal_critical"
        let requested = UserDefaults.standard.bool(forKey: "detailedCollection")
        if hot, requested, !detailSuspendedByThermal {
            detailSuspendedByThermal = true
            noteRuntimeState("detail_suspended_thermal")
        }
        guard lastRecordedThermalState != reason else { return }
        lastRecordedThermalState = reason
        noteRuntimeState(reason)
    }

    func noteSegmentation(candidate: String?, reused: Bool, durationMs: Double) {
        let token = beginRecorder(); defer { endRecorder(token) }
        guard detailedCollection else { return }
        let outcome = reused ? "cache_hit" : "computed"
        appendStructured(candidate: stableCandidateID(candidate), stage: "segmentation",
                         outcome: outcome, reason: outcome, durationMs: durationMs)
    }

    func appendStructured(candidate: UUID? = nil, frameIndex: Int? = nil,
                                  unitKey: String? = nil, stage: String, outcome: String,
                                  reason: String, durationMs: Double?, at time: Date = Date()) {
        let key: String?
        switch stage {
        case "first OCR": key = "firstSeen"
        case "superseded": key = "superseded"
        case "cancelled": key = "cancelled"
        case "cancellation": key = reason == "queue_replaced" ? nil : "cancelled"
        case "runtime_state": key = "runtimeTransition"
        case "model_state": key = reason
        case "stability", "pip_enqueue":
            key = ["handoff_replayed", "handoff_expired", "enqueue_failed"].contains(reason) ? reason : nil
        default: key = nil
        }
        if let key { eventTotals[key, default: 0] += 1 }
        let event = StructuredDiagnosticEvent(id: UUID(), timestamp: time,
            sessionID: diagnosticSessionID, candidateID: candidate,
            frameID: stableFrameID(frameIndex), unitID: stableUnitID(unitKey),
            stage: stage, outcome: outcome, reasonCode: reason,
            durationMs: durationMs.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, privacy: "metadataOnly")
        structuredEvents.append(event)
        if structuredEvents.count > 6000 {
            structuredEventsDropped += structuredEvents.count - 6000
            structuredEvents.removeFirst(structuredEvents.count - 6000)
        }
        // Reserve 128 of the 6,000 exported events for sparse early-session
        // evidence, so an initial 90-second stall is not erased by late activity.
        if Date().timeIntervalSince(started) <= 120, openingEvents.count < 128 {
            earlyEventsSeen += 1
            if earlyEventsSeen % 20 == 0 || stage == "runtime_state" ||
               stage == "model_state" {
                openingEvents.append(event)
            }
        }
    }
}
