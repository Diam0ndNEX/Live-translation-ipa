import Foundation

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
        // 2.2.1 (D7, suspected): the old rule (P95 > max(1800, 2.5 x median)) never flagged a 1.5 s tail.
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
        return findings
    }
}
