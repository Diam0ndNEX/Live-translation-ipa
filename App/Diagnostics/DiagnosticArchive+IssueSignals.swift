import Foundation

/// 2.6.0: findings that the app computes from the counters of a finished session, so that problems are flagged
/// without anyone reading the tables. Every number comes from whole-session counters (metadata only). "Observed"
/// is a recorded fact; "suspected" is a rate that can be a false positive. None of these is proof that a
/// translation was wrong. Thresholds are fixed and stated in the explanation; none was tuned on device data.
extension DiagnosticIssueDetector {
    static func assessSignals(_ session: DiagnosticSessionExport) -> [DiagnosticIssueFinding] {
        var findings: [DiagnosticIssueFinding] = []
        func add(_ code: String, _ classification: String, _ occurrences: Int, _ explanation: String) {
            findings.append(DiagnosticIssueFinding(code: code, classification: classification,
                occurrences: occurrences, explanation: explanation))
        }
        let c = session.counters
        func n(_ key: String) -> Int { max(0, c[key, default: 0]) }
        func percent(_ part: Int, _ whole: Int) -> Int { whole > 0 ? Int((Double(part) / Double(whole) * 100).rounded()) : 0 }

        // Stalls (2.6.0). A hung call is one that did not return within the learned limit.
        if n("stallHangs") > 0 {
            add("model_call_hung", "observed", n("stallHangs"),
                "\(n("stallHangs")) translation call(s) did not return within the learned limit and were abandoned; \(n("stallLateReturns")) of them returned later. A late return means the limit was too short for that moment, not a hang.")
        }
        let resets = n("stallLaneResets") + n("stallSessionResets") + n("stallLinkResets")
        if resets > 0 {
            add("lane_stall_recovery", "observed", resets,
                "Captions waited while no translation call started or ended. Recovery steps taken: lane \(n("stallLaneResets")), sessions \(n("stallSessionResets")), local link \(n("stallLinkResets")); stalls that ended: \(n("stallRecovered")).")
        }
        if n("stallUnhealthy") > 0 {
            add("translation_service_unresponsive", "observed", n("stallUnhealthy"),
                "Every recovery step was tried and captions still waited. The translation service may need the capture or the app restarted.")
        }
        if n("captureRestarts") > 0 {
            add("capture_restarts", "observed", n("captureRestarts"),
                "The capture was restarted during the run. Check the stall rows and the transport gaps around those moments.")
        }

        if n("guardTrips") > 0 {
            add("switch_guard_tripped", "observed", n("guardTrips"),
                "A guard turned off the growing-subtitle wait for the rest of this run because at least \(SwitchGuard.growthMinimumHeld) readings were held and \(Int(SwitchGuard.growthDroppedShare * 100))% or more of them were dropped. The saved setting was not changed. Later parts of this run are 2.5.5 behaviour for growing subtitles.")
        }

        // Growing subtitles (2.5.6).
        if n("growthHeld") >= 10 && percent(n("growthDropped"), n("growthHeld")) >= 25 {
            add("growth_hold_often_dropped", "suspected", n("growthDropped"),
                "\(n("growthDropped")) of \(n("growthHeld")) held readings (\(percent(n("growthDropped"), n("growthHeld")))%) were dropped because the screen moved on. Threshold 25%. The wait may be hiding captions that do not really grow.")
        }
        if n("growthSteps") >= 20 && percent(n("growthHeld"), n("growthSteps")) < 20 {
            add("growth_seen_not_held", "suspected", n("growthSteps"),
                "Growth was seen \(n("growthSteps")) times but only \(n("growthHeld")) readings were held (\(percent(n("growthHeld"), n("growthSteps")))%, threshold 20%). Growth detection may be working on text that is already stable.")
        }

        // Text blocks (2.5.5).
        if n("captionMultiBlock") >= 20 {
            add("multi_block_captions", "observed", n("captionMultiBlock"),
                "\(n("captionMultiBlock")) confirmed readings had several text blocks; \(n("captionJoined")) were joined (\(percent(n("captionJoined"), n("captionMultiBlock")))%). A low join share means the length limit or a script rule kept them apart.")
        }

        // Memory.
        let hits = ["ramHit", "persistentHit", "legacyHit", "normalizedHit", "speculativeHit"].reduce(0) { $0 + n($1) }
        let lookups = hits + n("miss") + n("timeout") + n("compatibilityRejected") + n("databaseUnavailable")
        if lookups >= 50 && percent(hits, lookups) < 35 {
            add("low_memory_hit_rate", "suspected", n("miss"),
                "Only \(percent(hits, lookups))% of \(lookups) lookups hit memory (threshold 35%). Normal for new content; low for content that repeats. The reason for each miss is not recorded yet, so the saving that better matching could give is unknown.")
        }

        // Confirmation by pixels.
        let confirmed = n("confirmedCandidatePackets")
        if confirmed >= 20 && n("confirmedWithPixelRejection") > 0 && percent(n("confirmedWithPixelRejection"), confirmed) >= 20 {
            add("pixel_check_rejects_often", "suspected", n("confirmedWithPixelRejection"),
                "\(percent(n("confirmedWithPixelRejection"), confirmed))% of confirmed readings had a pixel rejection (threshold 20%). Confirmation may be waiting for a second read more often than needed.")
        }

        // Heat.
        if let maxName = session.settings["thermalMax"]?.lowercased(), maxName == "serious" || maxName == "critical" {
            add("thermal_serious_reached", "observed", 1,
                "The phone reached Serious or Critical heat. Timings after that point are not comparable with a cool run, and detailed collection pauses.")
        }
        return findings
    }

    /// Order for the verdict: recorded facts about stops first, then other facts, then suspicions.
    static func severityRank(_ finding: DiagnosticIssueFinding) -> Int {
        let stops: Set<String> = ["translation_service_unresponsive", "model_call_hung", "lane_stall_recovery", "capture_restarts",
                                  "memory_write_failure", "migration_recovery"]
        if stops.contains(finding.code) { return 0 }
        return finding.classification == "observed" ? 1 : 2
    }
}
