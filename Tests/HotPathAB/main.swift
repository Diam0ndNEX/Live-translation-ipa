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
            // 2.5.3: the head start defaults to off once a session has been pinned.
            precondition(!TranslationHotPathAB.legacyHeadStart, "2.5.3: head start off by default")
            precondition(TranslationHotPathAB.trustedCaptionBand &&
                         TranslationHotPathAB.warmAtCaptureStart && TranslationHotPathAB.quietRewarm &&
                         TranslationHotPathAB.reportStoredSessionTotals, "2.5.0 switches default to on")
            standard.set(false, forKey: "trustedCaptionBand")
            precondition(TranslationHotPathAB.trustedCaptionBand, "a switch does not apply mid-run")
            TranslationHotPathAB.pinSettings()
            precondition(!TranslationHotPathAB.trustedCaptionBand && !TranslationHotPathAB.legacyHeadStart,
                         "one switch can be turned off without touching the others")
            standard.removeObject(forKey: "trustedCaptionBand")
            for item in TranslationHotPathAB.v250Switches { standard.removeObject(forKey: item.pinned) }
            for key in [TranslationHotPathAB.planPinnedKey, TranslationHotPathAB.unitsPinnedKey] { standard.removeObject(forKey: key) }
            precondition(TranslationHotPathAB.trustedCaptionBand && TranslationHotPathAB.label == "L1_F1")

            // 2.5.4: both new switches default to on, apply from the next session, and turn off one at a time.
            TranslationHotPathAB.pinSettings()
            precondition(TranslationHotPathAB.pixelManyLines && TranslationHotPathAB.captionLineSpeculation,
                         "2.5.4 switches default to on")
            standard.set(false, forKey: "pixelManyLines")
            precondition(TranslationHotPathAB.pixelManyLines, "a 2.5.4 switch does not apply mid-run")
            TranslationHotPathAB.pinSettings()
            precondition(!TranslationHotPathAB.pixelManyLines && TranslationHotPathAB.captionLineSpeculation,
                         "one 2.5.4 switch can be turned off alone")
            standard.removeObject(forKey: "pixelManyLines")
            for item in TranslationHotPathAB.v254Switches { standard.removeObject(forKey: item.pinned) }
            for key in [TranslationHotPathAB.planPinnedKey, TranslationHotPathAB.unitsPinnedKey] { standard.removeObject(forKey: key) }
            precondition(TranslationHotPathAB.pixelManyLines && TranslationHotPathAB.label == "L1_F1")
            let normalize: (String) -> String = { String($0.lowercased().filter { $0.isLetter || $0.isNumber }) }
            let wanted = normalize("Eu não sei de nada")
            precondition(CaptionLineSelection.indices(lineTexts: ["Eu não sei", "de nada", "MENU 12"], candidate: wanted,
                                                      normalize: normalize) == [0, 1],
                         "2.5.4: a line that is not part of the caption is not judged")
            precondition(CaptionLineSelection.indices(lineTexts: ["abc", "def"], candidate: "xyz", normalize: normalize) == [0, 1],
                         "2.5.4: when no line matches every line is kept")

            // 2.5.5: the switch defaults to on and turns off alone; the text blocks of one subtitle are joined.
            TranslationHotPathAB.pinSettings()
            precondition(TranslationHotPathAB.captionJoin, "2.5.5 switch defaults to on")
            standard.set(false, forKey: "captionJoin")
            precondition(TranslationHotPathAB.captionJoin, "the 2.5.5 switch does not apply mid-run")
            TranslationHotPathAB.pinSettings()
            precondition(!TranslationHotPathAB.captionJoin && TranslationHotPathAB.pixelManyLines, "the 2.5.5 switch turns off alone")
            standard.removeObject(forKey: "captionJoin")
            for item in TranslationHotPathAB.v255Switches { standard.removeObject(forKey: item.pinned) }
            for key in [TranslationHotPathAB.planPinnedKey, TranslationHotPathAB.unitsPinnedKey] { standard.removeObject(forKey: key) }
            precondition(CaptionJoin.joined(["[E como ele", "vai fazer isso?]"]) == ["[E como ele vai fazer isso?]"],
                         "2.5.5: a subtitle drawn in two places is one text")
            precondition(CaptionJoin.joined(["Percy:", "Satanás??!!O próprio Diabo tá falando sério??!!!"]) == ["Percy: Satanás??!!O próprio Diabo tá falando sério??!!!"],
                         "2.5.5: a speaker name joins its sentence")
            precondition(CaptionJoin.joined(["one block"]) == ["one block"], "2.5.5: one block stays")
            precondition(CaptionJoin.joined(["多个", "字幕"]) == ["多个字幕"], "2.5.5: CJK blocks join without a space")
            precondition(CaptionJoin.joined(["pre-", "fix"]) == ["pre-fix"], "2.5.5: a trailing hyphen joins without a space")
            precondition(CaptionJoin.joined(["  ", "alone"]) == ["  ", "alone"], "2.5.5: an empty block does not create a join")
            let longA = String(repeating: "a", count: 150), longB = String(repeating: "b", count: 100)
            precondition(CaptionJoin.joined([longA, longB]) == [longA, longB], "2.5.5: a long result is not joined")

            // 2.5.6: the growth switch defaults to on and turns off alone; growth is recognised from the text only.
            TranslationHotPathAB.pinSettings()
            precondition(TranslationHotPathAB.growthSettle, "2.5.6 switch defaults to on")
            standard.set(false, forKey: "growthSettle")
            precondition(TranslationHotPathAB.growthSettle, "the 2.5.6 switch does not apply mid-run")
            TranslationHotPathAB.pinSettings()
            precondition(!TranslationHotPathAB.growthSettle && TranslationHotPathAB.captionJoin, "the 2.5.6 switch turns off alone")
            standard.removeObject(forKey: "growthSettle")
            for item in TranslationHotPathAB.v256Switches + TranslationHotPathAB.v260Switches + TranslationHotPathAB.v261Switches { standard.removeObject(forKey: item.pinned) }
            for key in [TranslationHotPathAB.planPinnedKey, TranslationHotPathAB.unitsPinnedKey] { standard.removeObject(forKey: key) }
            var growth = CaptionGrowthTracker()
            precondition(growth.observe("ola tudo", at: 0) == .different, "2.5.6: the first reading is not growth")
            precondition(growth.observe("ola tudo bem", at: 0.3) == .extended, "2.5.6: more text at the end is growth")
            precondition(growth.observe("ola tudo bem", at: 0.4) == .same, "2.5.6: a repeat is not growth")
            precondition(growth.observe("ola tudo bem com voce", at: 0.7) == .extended, "2.5.6: growth continues")
            precondition(abs(growth.quietPeriod - 0.481) < 0.001, "2.5.6: the quiet period follows the observed pace")
            precondition(abs(growth.wait(elapsed: 0) - 0.481) < 0.001 && abs(growth.wait(elapsed: 0.85) - 0.05) < 0.001,
                         "2.5.6: the wait is capped by the total hold")
            precondition(growth.observe("adeus amigo", at: 1.0) == .different, "2.5.6: another caption is not growth")
            precondition(growth.wouldExtend("adeus amigo meu", at: 1.2) && !growth.wouldExtend("adeus amigo meu", at: 4.0),
                         "2.5.6: an old reading is not the previous caption")
            precondition(!CaptionGrowthTracker.extends("abc de", "xyz"), "2.5.6: very short text is not tracked")
            var slow = CaptionGrowthTracker(), fast = CaptionGrowthTracker()
            _ = slow.observe("abcd efgh", at: 0); _ = fast.observe("abcd efgh", at: 0)
            for step in 1...7 {
                _ = slow.observe("abcd efgh" + String(repeating: "x", count: step), at: Double(step) * 1.4)
                _ = fast.observe("abcd efgh" + String(repeating: "x", count: step), at: Double(step) * 0.12)
            }
            precondition(slow.quietPeriod == CaptionGrowthTracker.maximumQuiet && fast.quietPeriod == CaptionGrowthTracker.minimumQuiet,
                         "2.5.6: the wait adapts to the pace of the video within its limits")

            // 2.6.0: stall recovery. The switch defaults to on and turns off alone.
            TranslationHotPathAB.pinSettings()
            precondition(TranslationHotPathAB.stallWatchdog, "2.6.0 switch defaults to on")
            standard.set(false, forKey: "stallWatchdog")
            precondition(TranslationHotPathAB.stallWatchdog, "the 2.6.0 switch does not apply mid-run")
            TranslationHotPathAB.pinSettings()
            precondition(!TranslationHotPathAB.stallWatchdog && TranslationHotPathAB.captionJoin, "the 2.6.0 switch turns off alone")
            standard.removeObject(forKey: "stallWatchdog")
            for item in TranslationHotPathAB.v260Switches { standard.removeObject(forKey: item.pinned) }
            // The call limit is learned: cold, fast device, slow device, and the fixed ceiling.
            var limit = ModelStallLimit()
            precondition(limit.limitSeconds == ModelStallLimit.coldSeconds, "2.6.0: before any call the limit is the cold one")
            for _ in 0..<10 { limit.record(seconds: 0.5) }
            precondition(limit.limitSeconds == ModelStallLimit.floorSeconds, "2.6.0: a fast device keeps the floor")
            var slowDevice = ModelStallLimit()
            for _ in 0..<10 { slowDevice.record(seconds: 2) }
            precondition(abs(slowDevice.limitSeconds - 12) < 0.001, "2.6.0: the limit is a multiple of the slow end")
            var verySlow = ModelStallLimit()
            for _ in 0..<10 { verySlow.record(seconds: 10) }
            precondition(verySlow.limitSeconds == ModelStallLimit.ceilingSeconds, "2.6.0: the limit never exceeds the ceiling")
            limit.widen(afterLateReturn: 9)
            precondition(limit.p95 == 9, "2.6.0: a late return widens the limit")
            // The recovery ladder: one step at a time, in order, only after the threshold, restarting after progress.
            var ladder = StallLadder()
            precondition(ladder.evaluate(now: 100, waiting: 3, limit: 6) == nil, "2.6.0: a short wait is not a stall")
            precondition(ladder.evaluate(now: 100, waiting: 9.5, limit: 6) == .laneReset, "2.6.0: first step")
            precondition(ladder.evaluate(now: 105, waiting: 14.5, limit: 6) == nil, "2.6.0: one step per interval")
            precondition(ladder.evaluate(now: 110.1, waiting: 19.6, limit: 6) == .sessionReset, "2.6.0: second step")
            precondition(ladder.evaluate(now: 121, waiting: 30.5, limit: 6) == .linkReset, "2.6.0: third step")
            precondition(ladder.evaluate(now: 132, waiting: 41.5, limit: 6) == .unhealthy, "2.6.0: last step")
            precondition(ladder.evaluate(now: 150, waiting: 59.5, limit: 6) == nil, "2.6.0: unhealthy retries slowly")
            precondition(ladder.evaluate(now: 193, waiting: 102, limit: 6) == .laneReset, "2.6.0: the ladder starts over after the slow retry")
            let length = ladder.progress(now: 200)
            precondition(length != nil && length! > 100, "2.6.0: progress reports how long the stall lasted")
            precondition(ladder.evaluate(now: 201, waiting: 9.5, limit: 6) == .laneReset, "2.6.0: after progress the ladder starts at the first step")
            var slowLimit = StallLadder()
            precondition(slowLimit.evaluate(now: 50, waiting: 12, limit: 15) == nil && slowLimit.evaluate(now: 51, waiting: 18.5, limit: 15) == .laneReset,
                         "2.6.0: a stall is never declared before the model call limit has passed")
            // The race: a call that returns, a call that never returns (ignores cancellation), a late return.
            final class Box: @unchecked Sendable { var outcome = ""; var late = 0.0 }
            // @Sendable: a closure written here would otherwise run on the main actor, which the test thread blocks below.
            func race(limit: Double, _ work: @escaping @Sendable () async throws -> Int, box: Box) {
                let done = DispatchSemaphore(value: 0)
                // Detached: the test thread blocks below, so the race must not need the main actor.
                Task.detached {
                    let r = try? await ModelCallRace.run(limit: limit, onLateReturn: { box.late = $0 }, work)
                    switch r {
                    case .some(.value(let v)): box.outcome = "value \(v)"
                    case .some(.timedOut): box.outcome = "timedOut"
                    case .none: box.outcome = "error"
                    }
                    done.signal()
                }
                precondition(done.wait(timeout: .now() + 10) == .success, "2.6.0: the race test did not finish in 10 s")
            }
            let prompt = Box()
            race(limit: 2, { 42 }, box: prompt)
            precondition(prompt.outcome == "value 42", "2.6.0: a call that returns gives its value, got \(prompt.outcome)")
            let hung = Box()
            race(limit: 0.2, { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }; return 1 }, box: hung)
            precondition(hung.outcome == "timedOut", "2.6.0: a call that never returns is abandoned at the limit, got \(hung.outcome)")
            let slowCall = Box()
            race(limit: 0.1, { try await Task.sleep(nanoseconds: 400_000_000); return 7 }, box: slowCall)
            precondition(slowCall.outcome == "timedOut", "2.6.0: a call slower than the limit is abandoned, got \(slowCall.outcome)")
            let failing = Box()
            race(limit: 2, { () async throws -> Int in throw CancellationError() }, box: failing)
            precondition(failing.outcome == "error", "2.6.0: a failing call fails, it is not a timeout, got \(failing.outcome)")
            let gate = ResumeGate()
            precondition(gate.claim() && !gate.claim() && gate.isClaimed, "2.6.0: only one outcome gets through")
            // Automatic quality signals work on the text alone.
            var signals = CaptionSignals()
            precondition(signals.observe(original: "Hello there my friend how are you", translated: "Ola meu amigo como vai voce", at: 0).isEmpty,
                         "2.6.0: a normal caption has no flag")
            precondition(signals.observe(original: "Hello there my friend how are you", translated: "Ola, meu amigo: como vai voce!", at: 3) == [.reshownSame],
                         "2.6.0: the same sentence again (spacing, case and punctuation do not matter)")
            precondition(signals.observe(original: "Hello there my friend how are you today", translated: "Ola meu amigo como vai voce hoje", at: 5) == [.rewrittenSoon],
                         "2.6.0: the same sentence rewritten soon after")
            var numbers = CaptionSignals()
            precondition(numbers.observe(original: "Pay 1500 dollars now please", translated: "Pague dolares agora por favor", at: 0) == [.digitsLost],
                         "2.6.0: a number that went missing")
            precondition(numbers.observe(original: "Pay 1500 dollars now please", translated: "Pague 1500 dolares agora", at: 30).isEmpty,
                         "2.6.0: a number that is kept is not flagged")
            precondition(numbers.observe(original: "abcdefghij klm", translated: "abcdefghij klm", at: 60) == [.unchanged],
                         "2.6.0: nothing was translated")
            precondition(numbers.observe(original: "one two three four five", translated: "um um um dois tres", at: 90) == [.repeatedWord],
                         "2.6.0: a word repeated three times")
            var ratio = CaptionSignals()
            for i in 0..<40 {
                _ = ratio.observe(original: "alpha beta gamma delta \(i) epsilon", translated: "alfa beta gama delta \(i) epsilon", at: Double(i) * 10)
            }
            precondition(ratio.observe(original: "alpha beta gamma delta zeta", translated: String(repeating: "x", count: 400), at: 1_000) == [.lengthOutlier],
                         "2.6.0: a length far from this run's usual ratio, learned from the run")
            ratio.forgetShown()
            precondition(ratio.recent.isEmpty, "2.6.0: a cleared screen forgets recent captions")
            // Miss classification: near misses are found without any label, language or layout rule.
            var loose = LooseUnitIndex()
            precondition(loose.classifyMiss("Hello there.") == .new, "2.6.0: first sight")
            precondition(loose.classifyMiss("hello  there!") == .nearMiss, "2.6.0: case, spacing and punctuation only")
            precondition(loose.classifyMiss("hello  there!") == .repeatedExact, "2.6.0: the same unit again")
            loose.noteSeen("Good morning")
            precondition(loose.classifyMiss("GOOD MORNING?") == .nearMiss, "2.6.0: a memory hit counts as seen")
            precondition(loose.classifyMiss("") == .new && loose.classifyMiss("...") == .new, "2.6.0: nothing to compare")
            precondition(loose.classifyMiss("Good evening") == .new, "2.6.0: different words are not a near miss")
            // 2.6.1: loose reuse policy and its switch.
            TranslationHotPathAB.pinSettings()
            precondition(TranslationHotPathAB.looseMemoryReuse, "2.6.1 switch defaults to on")
            standard.set(false, forKey: "looseMemoryReuse")
            precondition(TranslationHotPathAB.looseMemoryReuse, "the 2.6.1 switch does not apply mid-run")
            TranslationHotPathAB.pinSettings()
            precondition(!TranslationHotPathAB.looseMemoryReuse && TranslationHotPathAB.stallWatchdog, "the 2.6.1 switch turns off alone")
            standard.removeObject(forKey: "looseMemoryReuse")
            for item in TranslationHotPathAB.v261Switches { standard.removeObject(forKey: item.pinned) }
            precondition(LooseReuse.key("Olá, MEU  amigo!") == "olameuamigo", "2.6.1: the loose key keeps letters and numbers only")
            precondition(LooseReuse.key("Ola\u{0301}") == LooseReuse.key("Ol\u{00E1}"), "2.6.1: canonical forms give one loose key")
            precondition(LooseReuse.terminal("Hello there?! ") == "?!" && LooseReuse.terminal("Hello") == "", "2.6.1: closing punctuation")
            precondition(LooseReuse.adapt(storedSource: "Hello there.", storedTranslation: "Ola.", requestedSource: "hello there!") == "Ola!", "2.6.1: punctuation follows the new source")
            precondition(LooseReuse.adapt(storedSource: "Hello there?!", storedTranslation: "Ola?!", requestedSource: "hello there") == "Ola", "2.6.1: no closing punctuation in the new source")
            precondition(LooseReuse.adapt(storedSource: "Hello there.", storedTranslation: "Ola.", requestedSource: "HELLO THERE.") == "Ola.", "2.6.1: same punctuation keeps the saved text")
            // 2.6.1: a guard turns a switch off for the session only, and pinning at session start clears it.
            precondition(!SwitchGuard.growthShouldTrip(held: 11, dropped: 11), "2.6.1: too few held readings to judge")
            precondition(!SwitchGuard.growthShouldTrip(held: 20, dropped: 11), "2.6.1: 55% dropped is below the limit")
            precondition(SwitchGuard.growthShouldTrip(held: 20, dropped: 12), "2.6.1: 60% dropped trips the guard")
            TranslationHotPathAB.pinSettings()
            precondition(TranslationHotPathAB.growthSettle, "2.6.1: the switch is on before the guard trips")
            TranslationHotPathAB.sessionOff.insert("growthSettle")
            precondition(!TranslationHotPathAB.growthSettle && TranslationHotPathAB.captionJoin, "2.6.1: the guard turns off that switch only")
            precondition((standard.object(forKey: "growthSettlePinned") as? Bool) == true, "2.6.1: the pinned setting is not changed")
            TranslationHotPathAB.pinSettings()
            precondition(TranslationHotPathAB.growthSettle && TranslationHotPathAB.sessionOff.isEmpty, "2.6.1: a new session starts clean")
            // The growth tracker recognises a revealed subtitle whatever it looks like: a label, a bracket, no
            // punctuation, another script. One rule for all, no layout or punctuation exception.
            let revealed = ["Maria: the quick brown fox jumps over the lazy dog",
                            "the quick brown fox jumps over the lazy dog",
                            "[music] the quick brown fox jumps over the lazy dog today",
                            "NARRATOR - the quick brown fox jumps over the lazy dog",
                            "素早い茶色の狐が怠け者の犬を飛び越える",
                            "o rapido cachorro marrom pula sobre a raposa preguicosa"]
            for sample in revealed {
                var tracker = CaptionGrowthTracker()
                let characters = Array(sample)
                var steps = Array(stride(from: 6, to: characters.count, by: 3))
                steps.append(characters.count)
                for (index, count) in steps.enumerated() {
                    let step = tracker.observe(String(characters[0..<count]), at: Double(index) * 0.2)
                    precondition(step == (index == 0 ? .different : .extended), "2.6.0: a revealed subtitle is growth at every step")
                }
                precondition(tracker.observe(String(characters) + String(characters), at: 10) == .different,
                             "2.6.0: after a long pause it is not growth")
            }
            var unrelated = CaptionGrowthTracker()
            for (index, sample) in revealed.enumerated() {
                precondition(unrelated.observe(sample, at: Double(index) * 0.2) == .different, "2.6.0: different captions are never growth")
            }
            precondition(CaptionSignals.key("Ola, MUNDO!") == "olamundo" && CaptionSignals.digitRuns("a 12 b 3 c 456") == ["12", "456"],
                         "2.6.0: key and digit runs")

            // 2.5.1: new Legacy defaults, the one-time reset of saved values, and the pure policies.
            for key in [LegacyV251Defaults.appliedKey, "legacyConfirmedOwnLanePinned", "deferArmedSpeculationPinned",
                        "legacyEagerSpeculationPinned"] { standard.removeObject(forKey: key) }
            precondition(TranslationHotPathAB.legacyEagerSpeculation && TranslationHotPathAB.legacyConfirmedOwnLane &&
                         !TranslationHotPathAB.deferArmedSpeculation, "2.5.1 Legacy defaults")
            standard.set(true, forKey: "deferArmedSpeculation"); standard.set(false, forKey: "legacyConfirmedOwnLane")
            TranslationHotPathAB.pinSettings()
            precondition(!TranslationHotPathAB.deferArmedSpeculation && TranslationHotPathAB.legacyConfirmedOwnLane,
                         "values saved before 2.5.1 are reset once to the new defaults")
            standard.set(true, forKey: "deferArmedSpeculation")
            TranslationHotPathAB.pinSettings()
            precondition(TranslationHotPathAB.deferArmedSpeculation, "after the reset the toggle works again")
            for key in ["deferArmedSpeculation", "legacyConfirmedOwnLane", LegacyV251Defaults.appliedKey,
                        "legacyConfirmedOwnLanePinned", "deferArmedSpeculationPinned"] { standard.removeObject(forKey: key) }
            for item in TranslationHotPathAB.v250Switches + TranslationHotPathAB.v251Switches + TranslationHotPathAB.v254Switches + TranslationHotPathAB.v255Switches + TranslationHotPathAB.v256Switches + TranslationHotPathAB.v260Switches + TranslationHotPathAB.v261Switches { standard.removeObject(forKey: item.pinned) }
            for key in [TranslationHotPathAB.planPinnedKey, TranslationHotPathAB.unitsPinnedKey,
                        TranslationHotPathAB.availabilityRefreshPinnedKey, TranslationHotPathAB.independentHeartbeatPinnedKey] {
                standard.removeObject(forKey: key)
            }
            precondition(HeadStartText.matches("Eu não sei\nde nada", "Eu não sei de nada"), "line breaks do not matter")
            precondition(!HeadStartText.matches("Eu nao sei de nada", "Eu não sei de nada"), "a different letter is a miss")
            precondition(!HeadStartText.matches("", ""), "empty never matches")
            precondition(EagerSpeculationPolicy.mayQueueBehindConfirmed(enabled: true, busy: true, confirmedRunning: true, confirmedQueued: false))
            precondition(!EagerSpeculationPolicy.mayQueueBehindConfirmed(enabled: true, busy: true, confirmedRunning: true, confirmedQueued: true),
                         "never while a confirmed caption waits")
            precondition(!EagerSpeculationPolicy.mayQueueBehindConfirmed(enabled: true, busy: true, confirmedRunning: false, confirmedQueued: false),
                         "never behind another early translation")
            precondition(!EagerSpeculationPolicy.mayQueueBehindConfirmed(enabled: false, busy: true, confirmedRunning: true, confirmedQueued: false))
            // 2.5.2
            precondition(TranslationHotPathAB.finishRunningCaption, "2.5.2 switch defaults to on")
            precondition(ConfirmedHandoffPolicy.holdWhileOwnCallRuns(enabled: true, busy: true, confirmedRunning: true, captionQueued: false) == ConfirmedHandoffPolicy.maximumHold)
            precondition(ConfirmedHandoffPolicy.maximumHold < 1.2, "a held caption must be replayed before the 1.2 s replay limit")
            precondition(ConfirmedHandoffPolicy.holdWhileOwnCallRuns(enabled: true, busy: true, confirmedRunning: true, captionQueued: true) == 0,
                         "no hold when the running call is an older caption's")
            precondition(ConfirmedHandoffPolicy.holdWhileOwnCallRuns(enabled: true, busy: true, confirmedRunning: false, captionQueued: false) == 0)
            precondition(ConfirmedHandoffPolicy.holdWhileOwnCallRuns(enabled: false, busy: true, confirmedRunning: true, captionQueued: false) == 0)
        }
        #endif

        print("v1.9.6 timed software A/B matrix passed: LL, Legacy, exact multi-line plans, correction, memory and late model completion")
        print("Synthetic values are not physical Apple model latency measurements")
    }
}
