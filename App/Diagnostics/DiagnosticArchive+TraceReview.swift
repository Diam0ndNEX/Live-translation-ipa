import Foundation

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

/// Off the live path: only process the recorder's bounded last 6000 events.
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
        let bounded = input.suffix(6000)
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
