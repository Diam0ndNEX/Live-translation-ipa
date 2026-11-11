import Foundation

/// Deterministic synthetic time is intentionally independent of wall time.
/// These tests verify critical-path decisions and regressions, not Apple model speed.
private struct CandidateIdentity: Equatable {
    let session: UUID
    let caption: String
    let text: String
    let source: String
    let target: String
    let rules: String
    let layout: Int
    let rotation: Int
    let context: Int
}

private struct CandidatePlan: Equatable {
    let units: [String]
    let exactKeys: [String]
}

private struct FakePlanBuilder {
    var work = ExactPlanReuseCache<CandidateIdentity, CandidatePlan>(capacity: 4)
    var builds = 0
    var reuses = 0

    mutating func prepare(_ identity: CandidateIdentity, reuse: Bool) -> (CandidatePlan, Double) {
        if reuse, let plan = work.lookup(identity) {
            reuses += 1
            return (plan, 0.3)
        }
        builds += 1
        let units = identity.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let keys = units.map {
            SharedTranslationWork.unitKey(source: identity.source, target: identity.target,
                                          text: $0, protectedWords: [], rules: identity.rules)
        }
        let result = CandidatePlan(units: units, exactKeys: keys)
        work.insert(result, for: identity)
        return (result, 20.3)
    }
}

private struct PathTrace {
    let firstOCR: Double
    let confirmedAt: Double
    let resultReadyAt: Double
    let enqueueAt: Double
    let modelCalls: Int
    let selectedUnits: [String]
    var latency: Double { enqueueAt - firstOCR }
}

private func syntheticCaption(mode: TranslationSystem, candidate: CandidateIdentity,
                              alreadyConfirmed: Bool, specModelMs: Double,
                              confirmDelayMs: Double, reusePlan: Bool,
                              memoryHit: Bool = false, match: Bool = true,
                              extraOverheadMs: Double = 0) -> PathTrace {
    var builder = FakePlanBuilder()
    let (tentative, _) = builder.prepare(candidate, reuse: reusePlan)
    var confirmed = candidate
    if !match { confirmed = CandidateIdentity(session: candidate.session, caption: candidate.caption,
        text: candidate.text + " corrigido", source: candidate.source, target: candidate.target,
        rules: candidate.rules, layout: candidate.layout, rotation: candidate.rotation,
        context: candidate.context) }
    let (finalPlan, confirmedPlanMs) = builder.prepare(confirmed, reuse: reusePlan)
    precondition(!finalPlan.units.isEmpty)
    precondition(finalPlan.exactKeys.count == finalPlan.units.count)
    precondition(tentative == finalPlan || !match)
    let firstOCR = 0.0
    let firstRead = 100.0
    let independentConfirmation = firstRead + confirmDelayMs
    let modelReady = firstRead + specModelMs
    let confirmedPrepared = independentConfirmation + confirmedPlanMs + extraOverheadMs
    let selectedAt: Double
    let calls: Int
    if memoryHit {
        selectedAt = confirmedPrepared
        calls = 0
    } else if match {
        selectedAt = max(confirmedPrepared, modelReady)
        calls = 1
    } else {
        selectedAt = confirmedPrepared + specModelMs
        calls = 2
    }
    let display = selectedAt + (alreadyConfirmed ? 4.0 : 6.0)
    precondition(finalPlan.units == confirmed.text.components(separatedBy: "\n"))
    precondition(display >= independentConfirmation)
    precondition(mode != .legacy || display >= confirmedPrepared)
    return PathTrace(firstOCR: firstOCR, confirmedAt: independentConfirmation,
                     resultReadyAt: selectedAt, enqueueAt: display,
                     modelCalls: calls, selectedUnits: finalPlan.units)
}

@main struct HotPathTimedExperiments {
    static func main() {
        let candidate = CandidateIdentity(session: UUID(), caption: "speech-1",
            text: "Primeira linha\nSegunda linha", source: "pt", target: "en",
            rules: "v4-rules", layout: 21, rotation: 0, context: 1)

        for modelMs in [40.0, 45, 50] {
            for confirmation in [100.0, 160, 250] {
                let reference = syntheticCaption(mode: .lowLatency, candidate: candidate,
                    alreadyConfirmed: true, specModelMs: modelMs,
                    confirmDelayMs: confirmation, reusePlan: false)
                let optimized = syntheticCaption(mode: .lowLatency, candidate: candidate,
                    alreadyConfirmed: true, specModelMs: modelMs,
                    confirmDelayMs: confirmation, reusePlan: true)
                precondition(reference.modelCalls == optimized.modelCalls &&
                    reference.selectedUnits == optimized.selectedUnits)
                precondition(abs((reference.latency - optimized.latency) - 20) < 0.001,
                    "F1 must remove the confirmed duplicate preparation on a matching caption")
                let injected = syntheticCaption(mode: .lowLatency, candidate: candidate,
                    alreadyConfirmed: true, specModelMs: modelMs,
                    confirmDelayMs: confirmation, reusePlan: true, extraOverheadMs: 20)
                precondition(abs((injected.latency - optimized.latency) - 20) < 0.001,
                    "A 20ms LL handoff regression must be visible at the total latency endpoint")
            }
        }

        for modelMs in [200.0, 270, 350] {
            for confirmation in [100.0, 160, 250] {
                let reference = syntheticCaption(mode: .legacy, candidate: candidate,
                    alreadyConfirmed: true, specModelMs: modelMs,
                    confirmDelayMs: confirmation, reusePlan: false, match: false)
                let optimized = syntheticCaption(mode: .legacy, candidate: candidate,
                    alreadyConfirmed: true, specModelMs: modelMs,
                    confirmDelayMs: confirmation, reusePlan: true, match: false)
                precondition(reference.selectedUnits == optimized.selectedUnits &&
                    reference.modelCalls == optimized.modelCalls)
                // A corrected candidate does not share the same key. There is
                // deliberately no false reuse credit when identity changes.
                precondition(abs(reference.latency - optimized.latency) < 0.001)
                let matchedBase = syntheticCaption(mode: .legacy, candidate: candidate,
                    alreadyConfirmed: true, specModelMs: modelMs,
                    confirmDelayMs: confirmation, reusePlan: true)
                let injected = syntheticCaption(mode: .legacy, candidate: candidate,
                    alreadyConfirmed: true, specModelMs: modelMs,
                    confirmDelayMs: confirmation, reusePlan: true, extraOverheadMs: 25)
                precondition(injected.latency >= matchedBase.latency,
                    "A Legacy confirmed-queue injection cannot masquerade as improvement")
            }
        }

        let memory = syntheticCaption(mode: .lowLatency, candidate: candidate,
            alreadyConfirmed: true, specModelMs: 45, confirmDelayMs: 140,
            reusePlan: true, memoryHit: true)
        precondition(memory.modelCalls == 0 && memory.selectedUnits.count == 2)

        var lease = AppleDefaultLeaseState()
        let oldTicket = lease.begin()!
        lease.requestCancellation()
        precondition(lease.begin() == nil,
            "A timed-out but still physically executing Default request retains exclusive lane ownership")
        precondition(!lease.finish(oldTicket, successful: true),
            "A late cancelled response cannot become a warm or displayed result")
        let newTicket = lease.begin()!
        precondition(lease.finish(newTicket, successful: true))

        // 2.2.1 D13: the A/B variants are run-time settings, pinned when a session starts. The compile flags used by the
        // reference CI builds override them, so this block only runs in the default build.
        #if !SCREENLINGO_REFERENCE_LL_PLAN && !SCREENLINGO_REFERENCE_LEGACY_UNITS
        do {
            // 2.5.0: the Hybrid scheduler variant that was pinned here is removed with the mode.
            let standard = UserDefaults.standard
            // Hot path flags: defaults are today's optimized paths, the label records what runs.
            precondition(TranslationHotPathAB.reuseStandaloneLowLatencyPlan && TranslationHotPathAB.reuseLegacyPreparedUnits &&
                         TranslationHotPathAB.label == "L1_F1", "D13: hot path defaults unchanged")
            standard.set(false, forKey: TranslationHotPathAB.planSettingKey)
            standard.set(false, forKey: TranslationHotPathAB.unitsSettingKey)
            precondition(TranslationHotPathAB.label == "L1_F1", "D13: hot path settings do not apply mid-run")
            TranslationHotPathAB.pinSettings()
            precondition(!TranslationHotPathAB.reuseStandaloneLowLatencyPlan && !TranslationHotPathAB.reuseLegacyPreparedUnits &&
                         TranslationHotPathAB.label == "L0_F0", "D13: both switches selectable and recorded in the label")
            for key in [TranslationHotPathAB.planSettingKey, TranslationHotPathAB.unitsSettingKey,
                        TranslationHotPathAB.planPinnedKey, TranslationHotPathAB.unitsPinnedKey] { standard.removeObject(forKey: key) }
            precondition(TranslationHotPathAB.label == "L1_F1")
            // 2.5.0: the new switches default to on, never change mid-run, and can be turned off for the next session.
            precondition(TranslationHotPathAB.trustedCaptionBand && TranslationHotPathAB.legacyHeadStart &&
                         TranslationHotPathAB.warmAtCaptureStart && TranslationHotPathAB.quietRewarm &&
                         TranslationHotPathAB.reportStoredSessionTotals, "2.5.0 switches default to on")
            standard.set(false, forKey: "trustedCaptionBand")
            precondition(TranslationHotPathAB.trustedCaptionBand, "a switch does not apply mid-run")
            TranslationHotPathAB.pinSettings()
            precondition(!TranslationHotPathAB.trustedCaptionBand && TranslationHotPathAB.legacyHeadStart,
                         "one switch can be turned off without touching the others")
            standard.removeObject(forKey: "trustedCaptionBand")
            for item in TranslationHotPathAB.v250Switches { standard.removeObject(forKey: item.pinned) }
            for key in [TranslationHotPathAB.planPinnedKey, TranslationHotPathAB.unitsPinnedKey] { standard.removeObject(forKey: key) }
            precondition(TranslationHotPathAB.trustedCaptionBand && TranslationHotPathAB.label == "L1_F1")
        }
        #endif

        print("v1.9.6 timed software A/B matrix passed: LL, Legacy, exact multi-line plans, correction, memory and late model completion")
        print("Synthetic values are not physical Apple model latency measurements")
    }
}
