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

private struct HybridTrace {
    let startRecoveryAt: Double
    let defaultCompleteAt: Double
    let recoveryCompleteAt: Double
    let selectedAt: Double
    let selected: String
    let logicalOverlapMs: Double
}

/// Simulates logical request intervals, without asserting that two Apple
/// sessions use separate hardware. The old Default request may finish even
/// after LL recovery wins and must not select again.
private func hybridTimeline(variant: HybridSchedulerVariant, matching: Bool,
                            defaultMs: Double, lowMs: Double, oldWaitMs: Double,
                            previousDefault: [Double], previousLow: [Double],
                            correlatedContention: Int, overlapPenaltyMs: Double) -> HybridTrace {
    let firstOCR = 0.0
    let defaultSubmittedAt = firstOCR + 100
    let confirmedAt = firstOCR + 200
    let defaultDone = defaultSubmittedAt + defaultMs
    let remaining = HybridSchedulingPolicy.matchingWait(variant: variant,
        elapsed: (confirmedAt - defaultSubmittedAt) / 1000,
        defaultSamples: previousDefault.map { $0 / 1000 },
        lowSamples: previousLow.map { $0 / 1000 },
        oldWait: oldWaitMs / 1000, recentContention: correlatedContention)
    let recoveryAt = confirmedAt + remaining * 1000
    let overlapped = max(0, defaultDone - recoveryAt)
    let extra = overlapped > 0 ? overlapPenaltyMs : 0
    let recoveredAt = recoveryAt + lowMs + extra
    let defaultMayWin = matching && defaultDone <= recoveredAt
    let winningAt = defaultMayWin ? defaultDone : recoveredAt
    let selected = defaultMayWin ? "matching_apple_default" : "confirmed_low_latency"
    precondition(winningAt >= confirmedAt)
    if !matching { precondition(selected == "confirmed_low_latency") }
    return HybridTrace(startRecoveryAt: recoveryAt, defaultCompleteAt: defaultDone,
        recoveryCompleteAt: recoveredAt, selectedAt: winningAt,
        selected: selected, logicalOverlapMs: min(defaultDone, recoveredAt) > recoveryAt ?
            min(defaultDone, recoveredAt) - recoveryAt : 0)
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

        // C should hedge promptly toward a 40ms LL service when Default is
        // predicted to take much longer and no contention has been observed.
        let fast = hybridTimeline(variant: .evidenceBounded, matching: true,
            defaultMs: 400, lowMs: 40, oldWaitMs: 100,
            previousDefault: [400, 420, 430, 450], previousLow: [40, 42, 45, 50],
            correlatedContention: 0, overlapPenaltyMs: 0)
        let referenceFast = hybridTimeline(variant: .reference195, matching: true,
            defaultMs: 400, lowMs: 40, oldWaitMs: 100,
            previousDefault: [400, 420, 430, 450], previousLow: [40, 42, 45, 50],
            correlatedContention: 0, overlapPenaltyMs: 0)
        precondition(fast.selected == "confirmed_low_latency" && fast.selectedAt < referenceFast.selectedAt)

        let slowLL = hybridTimeline(variant: .evidenceBounded, matching: true,
            defaultMs: 250, lowMs: 1200, oldWaitMs: 50,
            previousDefault: [250, 250, 250, 250], previousLow: [900, 1200, 1500, 1500],
            correlatedContention: 5, overlapPenaltyMs: 200)
        precondition(slowLL.selected == "matching_apple_default" &&
            slowLL.selectedAt == slowLL.defaultCompleteAt)
        let corrected = hybridTimeline(variant: .evidenceBounded, matching: false,
            defaultMs: 250, lowMs: 45, oldWaitMs: 50,
            previousDefault: [250, 250, 250, 250], previousLow: [45, 45, 45, 45],
            correlatedContention: 0, overlapPenaltyMs: 0)
        precondition(corrected.selected == "confirmed_low_latency")

        let cold = hybridTimeline(variant: .evidenceBounded, matching: true,
            defaultMs: 350, lowMs: 45, oldWaitMs: 100,
            previousDefault: [], previousLow: [], correlatedContention: 0,
            overlapPenaltyMs: 0)
        let oldCold = hybridTimeline(variant: .reference195, matching: true,
            defaultMs: 350, lowMs: 45, oldWaitMs: 100,
            previousDefault: [], previousLow: [], correlatedContention: 0,
            overlapPenaltyMs: 0)
        precondition(cold.selectedAt == oldCold.selectedAt,
            "Without calibrated samples C must retain the bounded reference deadline")

        var lease = AppleDefaultLeaseState()
        let oldTicket = lease.begin()!
        lease.requestCancellation()
        precondition(lease.begin() == nil,
            "A timed-out but still physically executing Default request retains exclusive lane ownership")
        precondition(!lease.finish(oldTicket, successful: true),
            "A late cancelled response cannot become a warm or displayed result")
        let newTicket = lease.begin()!
        precondition(lease.finish(newTicket, successful: true))

        print("v1.9.6 timed software A/B matrix passed: LL, Legacy, Hybrid A/C, exact multi-line plans, correction, memory and late model completion")
        print("Synthetic values are not physical Apple model latency measurements")
    }
}
