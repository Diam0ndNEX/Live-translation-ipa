import Foundation

@MainActor
final class Harness {
    struct Call {
        let activityID: UUID
        let caption: ModeCaption
        let strategy: RequestedTranslationStrategy
        let speculative: Bool
        let indices: [Int]
        let continuation: CheckedContinuation<[String]?, Never>
    }
    var calls: [Call] = []
    var selected: [(ModeCaption, ModeOutput, String)] = []
    var events: [String] = []
    var memory: [String?] = [nil]
    var lookupCount = 0
    var delayedMemory = false
    var pendingLookups: [CheckedContinuation<[String?], Never>] = []
    var cancellations: [Bool] = []
    var backend = TranslationBackendActivity()
    lazy var coordinator = ModeCoordinator(
        lookup: { [weak self] _ in
            guard let self else { return [nil] }
            self.lookupCount += 1
            if self.delayedMemory {
                return await withCheckedContinuation { self.pendingLookups.append($0) }
            }
            return self.memory
        },
        translate: { [weak self] caption, indices, strategy, spec in
            guard let self else { return nil }
            let activityID = self.backend.begin(kind: spec ? .speculative : .confirmed, source: caption.source,
                target: caption.target, strategy: strategy, stage: .running)
            let result: [String]? = await withCheckedContinuation { continuation in
                self.calls.append(Call(activityID: activityID, caption: caption, strategy: strategy, speculative: spec, indices: indices, continuation: continuation))
            }
            self.backend.end(activityID)
            return result
        }, cancel: { [weak self] spec in
            self?.cancellations.append(spec)
            guard let self else { return }
            for call in self.calls where call.speculative == spec { self.backend.advance(call.activityID, to: .cancelling) }
        },
        selected: { [weak self] caption, output, reason in self?.selected.append((caption, output, reason)) },
        event: { [weak self] _, reason, _ in self?.events.append(reason) }, status: { [weak self] _ in self?.events.append("status") })
    let session = UUID()
    func caption(_ text: String = "I do not have 10 cats.", revision: Int = 1, id: String = "caption", source: String = "en") -> ModeCaption {
        ModeCaption(session: session, caption: id, revision: revision, source: source, target: "de", rules: "rules", text: text,
            units: [text], keys: [source + ">de|" + text], firstOCR: 1)
    }
    func reply(_ index: Int, _ values: [String]?) { calls[index].continuation.resume(returning: values) }
    func settle() async { for _ in 0..<100 { await Task.yield() } }
}

@main struct ThreeModeTests {  // name kept: build.yml and the scripts refer to this folder
    @MainActor static func main() async {
        // Capture readiness comes from transport evidence, not a translated caption.
        var readiness = CaptureReadiness()
        precondition(readiness.state == .idle)
        readiness.requested(at: 0); precondition(readiness.state == .waiting)
        readiness.receive(frames: 0, session: "first", stopped: false, at: 1)
        precondition(readiness.state == .connected)
        readiness.receive(frames: 1, session: "first", stopped: false, at: 2)
        precondition(readiness.state == .active)
        readiness.requested(at: 3); precondition(readiness.state == .active)
        readiness.tick(at: 7); precondition(readiness.state == .lost)
        readiness.receive(frames: 0, session: "second", stopped: false, at: 8)
        precondition(readiness.state == .connected)
        readiness.receive(frames: 5, session: "first", stopped: true, at: 9)
        precondition(readiness.state == .connected)
        readiness.receive(frames: 1, session: "second", stopped: false, at: 10)
        readiness.receive(frames: 1, session: "second", stopped: true, at: 11)
        precondition(readiness.state == .stopped)
        readiness.requested(at: 12); readiness.tick(at: 42)
        precondition(readiness.state == .timedOut)

        // 2.5.0: Hybrid Recovery was removed; the Hybrid policy checks that stood here went with it.
        for mode in [TranslationSystem.lowLatency] {
            let probe = Harness()
            probe.coordinator.system = mode
            probe.coordinator.observe(probe.caption(id: "probe"), confirmed: true, speculate: false)
            await probe.settle()
            precondition(probe.lookupCount == 1 &&
                probe.calls.count == 1,
                "Confirmed memory probe must be reused; no duplicate SQLite read on recovery")
            probe.reply(0, ["Confirmed response"])
            await probe.settle()
            precondition(probe.selected.count == 1)
            probe.coordinator.reset()
        }

        // Reset during an in-flight Apple call must not let its late response
        // clear the speculative owner of the next capture session.
        let resetRace = Harness()
        resetRace.coordinator.system = .lowLatency
        resetRace.coordinator.observe(resetRace.caption(id: "obsolete"), confirmed: false, speculate: true)
        await resetRace.settle()
        precondition(resetRace.calls.count == 1)
        resetRace.coordinator.reset()
        resetRace.coordinator.observe(resetRace.caption(id: "new-session"), confirmed: false, speculate: true)
        await resetRace.settle()
        precondition(resetRace.calls.count == 2)
        resetRace.reply(0, ["Abandoned response"])
        await resetRace.settle()
        resetRace.coordinator.observe(resetRace.caption(id: "third-subtitle"), confirmed: false, speculate: true)
        await resetRace.settle()
        precondition(resetRace.calls.count == 2, "Stale task cleared the current speculation owner")
        resetRace.reply(1, ["Valid new-session response"])
        await resetRace.settle()
        resetRace.coordinator.reset()
        let sameSession = UUID()
        let nominalCaption = ModeCaption(system: .lowLatency, thermal: 0, session: sameSession,
            caption: "candidate", revision: 1, source: "pt", target: "en", rules: "r",
            text: "Bom dia", units: ["Bom dia"], keys: ["key"], firstOCR: 7.0)
        var fairCaption = nominalCaption
        fairCaption.thermal = 1
        precondition(nominalCaption == fairCaption && nominalCaption.matches(fairCaption),
            "Nominal/fair transitions cannot revoke an otherwise identical translation")
        precondition(nominalCaption.policyCohort == fairCaption.policyCohort,
            "Nominal and fair must share adaptive model scheduling evidence")
        fairCaption.thermal = 2
        precondition(nominalCaption == fairCaption &&
                     nominalCaption.policyCohort != fairCaption.policyCohort,
            "Serious protection changes scheduling evidence but not caption authority")
        let readinessStart = Date(timeIntervalSince1970: 100)
        precondition(InitialWarmupPolicy.strategies(for: .legacy).isEmpty)
        for source in ["en", "es", "fr", "de", "it", "pt", "ru", "ja", "ko", "zh-Hans", "zh-Hant", "ar", "tr", "hi", "id", "nl", "pl", "th", "vi", "uk"] {
            precondition(InitialWarmupSamples.units(source: source)?.count == 2)
        }
        precondition(InitialWarmupSamples.units(source: "zz") == nil)
        precondition(InitialWarmupPolicy.strategies(for: .lowLatency) == [.lowLatency])
        let both = TranslationLanguageCoverage(appleDefault: .installed, lowLatency: .installed)
        precondition(both.overall(for: .legacy) == .installed && both.overall(for: .lowLatency) == .installed)
        precondition(both.nextDownload(for: .legacy) == nil && both.nextDownload(for: .lowLatency) == nil)
        let onlyDefault = TranslationLanguageCoverage(appleDefault: .installed, lowLatency: .supported)
        precondition(onlyDefault.overall(for: .lowLatency) == .supported)
        precondition(onlyDefault.nextDownload(for: .lowLatency) == .lowLatency)
        precondition(onlyDefault.nextDownload(for: .legacy) == nil)
        let onlyLow = TranslationLanguageCoverage(appleDefault: .supported, lowLatency: .installed)
        precondition(onlyLow.overall(for: .legacy) == .supported && onlyLow.nextDownload(for: .legacy) == .appleDefault)
        precondition(onlyLow.nextDownload(for: .lowLatency) == nil)
        let unsupported = TranslationLanguageCoverage(appleDefault: .unsupported, lowLatency: .unsupported)
        precondition(unsupported.overall(for: .lowLatency) == .unsupported && unsupported.nextDownload(for: .lowLatency) == nil)
        let unknown = TranslationLanguageCoverage(appleDefault: .unchecked, lowLatency: .unchecked)
        precondition(unknown.overall(for: .lowLatency) == .unchecked && unknown.overall(for: .legacy) == .unchecked)
        var warmupBudget = InitialWarmupPolicy()
        precondition(warmupBudget.claim(source: "pt", target: "en", strategy: .appleDefault))
        precondition(warmupBudget.claim(source: "pt", target: "en", strategy: .lowLatency))
        precondition(!warmupBudget.claim(source: "pt", target: "en", strategy: .lowLatency))
        precondition(!warmupBudget.claim(source: "pt", target: "en", strategy: .appleDefault))
        for index in 0..<62 { precondition(warmupBudget.claim(source: "pair\(index)", target: "en", strategy: .lowLatency)) }
        precondition(warmupBudget.attempted.count == 64)
        precondition(!warmupBudget.claim(source: "another", target: "en", strategy: .lowLatency))
        precondition(warmupBudget.totalAdmissions == 64)
        var retryPolicy = InitialWarmupPolicy()
        let attemptedAt = Date(timeIntervalSince1970: 100)
        precondition(retryPolicy.claim(source: "pt", target: "en", strategy: .lowLatency, now: attemptedAt))
        retryPolicy.finish(source: "pt", target: "en", strategy: .lowLatency, succeeded: false, now: attemptedAt)
        precondition(!retryPolicy.claim(source: "pt", target: "en", strategy: .lowLatency, now: attemptedAt.addingTimeInterval(5)))
        precondition(retryPolicy.skippedReason(source: "pt", target: "en", strategy: .lowLatency,
                                              now: attemptedAt.addingTimeInterval(5)).contains("cooldown"))
        precondition(retryPolicy.claim(source: "pt", target: "en", strategy: .lowLatency,
                                       now: attemptedAt.addingTimeInterval(31)))
        retryPolicy.finish(source: "pt", target: "en", strategy: .lowLatency, succeeded: true,
                           now: attemptedAt.addingTimeInterval(31))
        precondition(!retryPolicy.claim(source: "pt", target: "en", strategy: .lowLatency,
                                        now: attemptedAt.addingTimeInterval(120)))
        precondition(retryPolicy.skippedReason(source: "pt", target: "en", strategy: .lowLatency,
                                              now: attemptedAt.addingTimeInterval(120)).contains("succeeded"))
        var evidence = TranslationReadiness(source: "pt", target: "en")
        precondition(evidence.activity.phase == .waiting)
        evidence.prepare(.checkingLanguages, now: readinessStart)
        precondition(evidence.languages == .working && evidence.activity.phase == .working)
        evidence.prepare(.languagesInstalled)
        evidence.prepare(.creatingSessions)
        evidence.prepare(.checkingSessions)
        evidence.prepare(.sessionsReady)
        precondition(evidence.languages == .complete && evidence.sessions == .complete)
        precondition(evidence.execution == .pending && evidence.activity.phase == .waiting)
        precondition(evidence.completedAt == nil && evidence.durationMs == nil)
        // Installed assets and a ready session cannot masquerade as completed warm-up.
        evidence.beginExecution(label: "Running Legacy warm-up", now: readinessStart)
        precondition(evidence.execution == .working && evidence.activity.since == readinessStart)
        evidence.finishExecution(success: true, milliseconds: 540, now: readinessStart.addingTimeInterval(0.54))
        precondition(evidence.activity.phase == .ready && evidence.durationMs == 540)
        precondition(evidence.completedAt == readinessStart.addingTimeInterval(0.54))
        // Invalidation prevents stale success from declaring the next session ready.
        evidence.sessions = .pending; evidence.execution = .pending
        precondition(evidence.activity.phase == .waiting)
        evidence.prepare(.creatingSessions)
        evidence.beginExecution(label: "Running translation request")
        evidence.finishExecution(success: false, milliseconds: nil)
        precondition(evidence.activity.phase == .attention && evidence.activeSince == nil)
        var unsupportedEvidence = TranslationReadiness()
        unsupportedEvidence.prepare(.unavailable)
        precondition(unsupportedEvidence.activity.phase == .attention)
        var missingAssets = TranslationReadiness()
        missingAssets.prepare(.checkingLanguages)
        missingAssets.prepare(.languagesUnavailable)
        precondition(missingAssets.activity.phase == .attention && missingAssets.activeSince == nil)
        // Backend lifetime must outlive caption selection and advisory cancellation.
        var backendState = TranslationBackendActivity()
        let previousPrep = backendState.begin(kind: .preparation, source: "pt", target: "en", strategy: .lowLatency, stage: .checkingLanguages)
        let latestPrep = backendState.begin(kind: .preparation, source: "de", target: "en", strategy: .lowLatency, stage: .preparingSessions)
        backendState.end(previousPrep)
        precondition(backendState.current?.id == latestPrep && backendState.activity?.phase == .working)
        let realRequest = backendState.begin(kind: .speculative, source: "de", target: "en", strategy: .lowLatency, stage: .running)
        backendState.end(latestPrep)
        backendState.advance(realRequest, to: .cancelling)
        precondition(backendState.executing && backendState.activity?.title == "Waiting for cancelled model work to return")
        let recoveryRequest = backendState.begin(kind: .confirmed, source: "de", target: "en", strategy: .lowLatency, stage: .waitingForSlot)
        precondition(backendState.current?.id == recoveryRequest)
        backendState.advance(recoveryRequest, to: .running)
        backendState.end(realRequest)
        precondition(backendState.executing && backendState.current?.id == recoveryRequest)
        backendState.end(recoveryRequest)
        precondition(!backendState.executing && backendState.activity == nil)
        var previousSuccess = TranslationReadiness(source: "de", target: "en")
        previousSuccess.finishExecution(success: true, milliseconds: 320)
        precondition(backendState.liveReadiness(previousSuccess).execution == .idle)
        let warmRequest = backendState.begin(kind: .warmup, source: "de", target: "en", strategy: .lowLatency, stage: .running)
        precondition(backendState.activity?.title == "Running initial warm-up")
        let liveRequest = backendState.begin(kind: .confirmed, source: "de", target: "en", strategy: .lowLatency, stage: .running)
        backendState.advance(warmRequest, to: .cancelling)
        precondition(backendState.current?.id == liveRequest && backendState.jobs.count == 2)
        backendState.end(liveRequest)
        precondition(backendState.executing)
        backendState.end(warmRequest)
        precondition(backendState.liveReadiness(previousSuccess).durationMs == 320)
        let nextRequest = backendState.begin(kind: .confirmed, source: "de", target: "en", strategy: .lowLatency, stage: .running)
        precondition(backendState.liveReadiness(previousSuccess).execution == .working)
        backendState.end(nextRequest)
        precondition(backendState.liveReadiness(previousSuccess).execution == .idle)
        precondition(TranslationBackendActivity.idle(capture: true, ownInterfaceVisible: false, modelObserved: true).title == "Watching for the next caption")
        precondition(TranslationBackendActivity.idle(capture: true, ownInterfaceVisible: true, modelObserved: true).phase == .waiting)
        precondition(TranslationActivity.event("speculative_model_submitted")?.phase == .working)
        precondition(TranslationActivity.event("speculation_ready")?.phase == .ready)
        precondition(TranslationActivity.event("recovery_decision_source_mismatch")?.phase == .working)
        precondition(TranslationActivity.event("pip_enqueue_memory_hit")?.title == "Saved translation reused")
        precondition(TranslationActivity.event("pip_enqueue_speculation_match_in_flight")?.phase == .ready)
        precondition(TranslationActivity.event("display_failed")?.phase == .attention)
        precondition(TranslationActivity.event("cancelled_call_returned") == nil)
        let suite = "three-mode-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // 2.5.0: the old hybridTranslation switch is ignored; only the Low Latency switch decides.
        for (low, hybrid, expected) in [(false, false, TranslationSystem.legacy), (true, false, .lowLatency), (false, true, .legacy), (true, true, .lowLatency)] {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(low, forKey: "lowLatencyTranslation"); defaults.set(hybrid, forKey: "hybridTranslation")
            defaults.set("preserve", forKey: "unrelated")
            let migrated = TranslationSystem.migrate(defaults)
            precondition(migrated.0 == expected)
            defaults.set(!low, forKey: "lowLatencyTranslation")
            let persisted = TranslationSystem.migrate(defaults)
            precondition(persisted.0 == expected && persisted.1 == migrated.1)
            precondition(defaults.string(forKey: "unrelated") == "preserve")
        }
        defaults.set("future-mode", forKey: "translationSystem")
        precondition(TranslationSystem.migrate(defaults).0 == .legacy)
        precondition(defaults.string(forKey: "translationSystem") == "future-mode")
        for system in [TranslationSystem.lowLatency] {
            // Matching in-flight work is promoted, never translated a second time.
            let h = Harness(); h.coordinator.system = system
            let c = h.caption()
            h.coordinator.observe(c, confirmed: false, speculate: true); await h.settle()
            precondition(h.calls.count == 1)
            precondition(h.calls[0].strategy == (system == .lowLatency ? .lowLatency : .appleDefault))
            h.coordinator.observe(c, confirmed: true, speculate: true); await h.settle()
            precondition(h.calls.count == 1 && h.selected.isEmpty)
            h.reply(0, ["Ich habe keine 10 Katzen."]); await h.settle()
            precondition(h.selected.count == 1)
            h.coordinator.observe(c, confirmed: true, speculate: true); await h.settle()
            precondition(h.selected.count == 1 && h.calls.count == 1)
            h.coordinator.reset()

            // Mismatch recovery starts without waiting for cancellation to finish.
            let mismatch = Harness(); mismatch.coordinator.system = system
            mismatch.coordinator.observe(mismatch.caption("I have 10 cats."), confirmed: false, speculate: true)
            await mismatch.settle()
            let corrected = mismatch.caption(revision: 2)
            mismatch.coordinator.observe(corrected, confirmed: true, speculate: true)
            await mismatch.settle()
            precondition(mismatch.calls.count == 2 && mismatch.calls[1].strategy == .lowLatency)
            mismatch.reply(1, ["Correct complete output"]); await mismatch.settle()
            mismatch.reply(0, ["Obsolete incorrect output"]); await mismatch.settle()
            precondition(mismatch.selected.count == 1 && mismatch.selected[0].1.values == ["Correct complete output"])
            mismatch.coordinator.reset()

            // Preferred memory bypasses an occupied speculative inference lane.
            let memory = Harness(); memory.coordinator.system = system
            memory.coordinator.observe(memory.caption("Old candidate"), confirmed: false, speculate: true); await memory.settle()
            memory.memory = ["Saved preferred output"]
            memory.coordinator.observe(memory.caption(revision: 2), confirmed: true, speculate: false); await memory.settle()
            precondition(memory.selected.count == 1 && memory.calls.count == 1)
            precondition(memory.selected[0].1.strategies[0] == nil)
            precondition(memory.backend.executing && memory.backend.activity?.phase == .working)
            memory.reply(0, nil); await memory.settle()
            precondition(memory.backend.activity == nil)
            memory.coordinator.reset()

            // No speculation uses LL; source corrections and language switches invalidate old output.
            let fresh = Harness(); fresh.coordinator.system = system
            fresh.coordinator.observe(fresh.caption(), confirmed: true, speculate: false); await fresh.settle()
            precondition(fresh.calls.count == 1 && fresh.calls[0].strategy == .lowLatency)
            fresh.coordinator.observe(fresh.caption("I have 20 cats.", revision: 2), confirmed: true, speculate: false); await fresh.settle()
            fresh.reply(0, ["Old"]); await fresh.settle()
            precondition(fresh.selected.isEmpty)
            fresh.reply(1, ["New"]); await fresh.settle()
            precondition(fresh.selected.count == 1)
            fresh.coordinator.reset()

            // Stop/restart rejects a completion even if the OS ignores cancellation.
            let stop = Harness(); stop.coordinator.system = system
            stop.coordinator.observe(stop.caption(), confirmed: true, speculate: false); await stop.settle()
            stop.coordinator.reset(); stop.reply(0, ["Must not display"]); await stop.settle()
            precondition(stop.selected.isEmpty)
        }
        // Regression: an early subtitle B MUST be eligible while the previous
        // confirmed subtitle A is still on screen. v1.9.2 rejected this
        // ordinary transition and effectively disabled both predictive modes.
        for system in [TranslationSystem.lowLatency] {
            let nextSubtitle = Harness()
            nextSubtitle.coordinator.system = system
            let previous = nextSubtitle.caption("Previously shown subtitle.", revision: 1, id: "A")
            nextSubtitle.coordinator.observe(previous, confirmed: true, speculate: false)
            await nextSubtitle.settle()
            precondition(nextSubtitle.calls.count == 1)
            nextSubtitle.reply(0, ["Previous translated subtitle"])
            await nextSubtitle.settle()
            precondition(nextSubtitle.selected.count == 1)
            let next = nextSubtitle.caption("The upcoming subtitle.", revision: 2, id: "B")
            nextSubtitle.coordinator.observe(next, confirmed: false, speculate: true)
            await nextSubtitle.settle()
            precondition(nextSubtitle.coordinator.shouldStartModel(next, speculative: true),
                         "Previous displayed text must not invalidate the next early OCR prediction")
            precondition(nextSubtitle.calls.count == 2)
            precondition(nextSubtitle.calls[1].strategy == .lowLatency)
            nextSubtitle.coordinator.noteSpeculativeModelSubmitted(next)
            nextSubtitle.coordinator.observe(next, confirmed: true, speculate: true)
            await nextSubtitle.settle()
            precondition(nextSubtitle.calls.count == 2, "A matching in-flight prediction is reused")
            nextSubtitle.reply(1, ["Upcoming translation"])
            await nextSubtitle.settle()
            precondition(nextSubtitle.selected.count == 2 &&
                         nextSubtitle.selected[1].1.values == ["Upcoming translation"])
            precondition(!nextSubtitle.coordinator.shouldStartModel(next, speculative: true),
                         "Committed captions must not restart speculative inference")
            nextSubtitle.coordinator.reset()

            // If the next confirmation is C instead of predicted B, a B
            // request that has not started must be dropped, not displayed.
            let replaced = Harness()
            replaced.coordinator.system = system
            let old = replaced.caption("Already displayed", id: "old")
            replaced.coordinator.observe(old, confirmed: true, speculate: false)
            await replaced.settle()
            replaced.reply(0, ["Old translation"])
            await replaced.settle()
            let predicted = replaced.caption("Predicted B", revision: 2, id: "predicted")
            replaced.coordinator.observe(predicted, confirmed: false, speculate: true)
            await replaced.settle()
            precondition(replaced.coordinator.shouldStartModel(predicted, speculative: true))
            let actual = replaced.caption("Confirmed C", revision: 3, id: "actual")
            replaced.coordinator.observe(actual, confirmed: true, speculate: false)
            await replaced.settle()
            precondition(!replaced.coordinator.shouldStartModel(predicted, speculative: true))
            precondition(replaced.coordinator.shouldStartModel(actual, speculative: false))
            precondition(replaced.events.contains("speculation_superseded_before_confirmation"))
            replaced.reply(1, ["Stale predicted result"])
            await replaced.settle()
            precondition(replaced.selected.count == 1)
            replaced.reply(2, ["Confirmed C result"])
            await replaced.settle()
            precondition(replaced.selected.count == 2 &&
                         replaced.selected[1].1.values == ["Confirmed C result"])
            replaced.coordinator.reset()
        }

        // Backend request ownership allows an early preview before confirmation
        // but refuses stale, selected and reset requests before model admission.
        let admission = Harness()
        admission.coordinator.system = .lowLatency
        let preview = admission.caption("Early line", id: "preview")
        admission.coordinator.observe(preview, confirmed: false, speculate: true)
        await admission.settle()
        precondition(admission.coordinator.shouldStartModel(preview, speculative: true))
        precondition(!admission.coordinator.shouldStartModel(preview, speculative: false))
        let accepted = admission.caption("Early line", id: "preview")
        admission.coordinator.observe(accepted, confirmed: true, speculate: true)
        await admission.settle()
        precondition(admission.coordinator.shouldStartModel(accepted, speculative: false))
        let superseding = admission.caption("Correct line", revision: 2, id: "corrected")
        admission.coordinator.observe(superseding, confirmed: true, speculate: false)
        await admission.settle()
        precondition(!admission.coordinator.shouldStartModel(preview, speculative: true))
        precondition(!admission.coordinator.shouldStartModel(accepted, speculative: false))
        precondition(admission.coordinator.shouldStartModel(superseding, speculative: false))
        admission.coordinator.reset()
        precondition(!admission.coordinator.shouldStartModel(superseding, speculative: false))
        for i in admission.calls.indices { admission.reply(i, nil) }
        await admission.settle()

        // A stale unsuccessful recovery must not re-enter the model lane for
        // its same-strategy retry or consume time ahead of the current caption.
        let staleRetry = Harness()
        staleRetry.coordinator.system = .lowLatency
        let staleFirst = staleRetry.caption("First request", id: "first")
        staleRetry.coordinator.observe(staleFirst, confirmed: true, speculate: false)
        await staleRetry.settle()
        precondition(staleRetry.calls.count == 1)
        let liveSecond = staleRetry.caption("Second request", revision: 2, id: "second")
        staleRetry.coordinator.observe(liveSecond, confirmed: true, speculate: false)
        await staleRetry.settle()
        precondition(staleRetry.calls.count == 2)
        staleRetry.reply(0, nil)
        await staleRetry.settle()
        precondition(staleRetry.calls.count == 2, "Stale requests must not retry or fall back")
        staleRetry.reply(1, ["Current caption"])
        await staleRetry.settle()
        precondition(staleRetry.selected.count == 1 && staleRetry.selected[0].1.values == ["Current caption"])
        staleRetry.coordinator.reset()

        // Failed LL requests have a bounded same-strategy retry and no default refinement.
        let fail = Harness(); fail.coordinator.system = .lowLatency
        fail.coordinator.observe(fail.caption(), confirmed: true, speculate: false); await fail.settle()
        fail.reply(0, nil); await fail.settle(); fail.reply(1, nil); await fail.settle()
        precondition(fail.calls.count == 2 && fail.calls.allSatisfy { $0.strategy == .lowLatency })
        precondition(fail.selected.isEmpty && fail.events.contains("status"))
        fail.coordinator.reset()
        // Whitespace-only OCR normalization is safe only with identical
        // ordered translation units, exact context keys and config revision.
        let norm = Harness()
        let c = norm.caption()
        let whitespaceSameWork = ModeCaption(session: c.session, caption: c.caption,
            revision: c.revision, source: c.source, target: c.target, rules: c.rules,
            text: "I do not\nhave 10 cats.", units: c.units, keys: c.keys, firstOCR: c.firstOCR)
        precondition(c.matches(whitespaceSameWork))
        // Raw identical unit strings must take the allocation-free match path.
        precondition(c.matches(c))
        let normalizedUnit = ModeCaption(session: c.session, caption: c.caption,
            revision: c.revision, source: c.source, target: c.target, rules: c.rules,
            text: c.text, units: ["I do not\nhave 10 cats."],
            keys: c.keys, firstOCR: c.firstOCR)
        precondition(c.matches(normalizedUnit),
            "Whitespace-only unit changes retain identical exact-key work")
        let changedUnit = ModeCaption(session: c.session, caption: c.caption,
            revision: c.revision, source: c.source, target: c.target, rules: c.rules,
            text: c.text, units: ["I do not have 20 cats."],
            keys: c.keys, firstOCR: c.firstOCR)
        precondition(!c.matches(changedUnit),
            "Matching caption text cannot hide changed translation inputs")
        let unicodeBase = ModeCaption(session: c.session, caption: c.caption,
            revision: c.revision, source: c.source, target: c.target, rules: c.rules,
            text: "Café", units: ["Café"], keys: ["unicode-exact-key"], firstOCR: c.firstOCR)
        let unicodeVariant = ModeCaption(session: c.session, caption: c.caption,
            revision: c.revision, source: c.source, target: c.target, rules: c.rules,
            text: "Cafe\u{301}", units: ["Cafe\u{301}"], keys: ["unicode-exact-key"], firstOCR: c.firstOCR)
        precondition(unicodeBase.matches(unicodeVariant),
            "Canonical Unicode equivalents retain existing matching semantics")
        precondition(!c.matches(norm.caption("I do not\nhave 10 cats.")),
            "Different exact unit keys must block speculative output")
        precondition(!c.matches(norm.caption(revision: 2)),
            "Capture/settings revision must invalidate earlier speculation")
        let twoUnits = ModeCaption(session: c.session, caption: c.caption,
            revision: c.revision, source: c.source, target: c.target, rules: c.rules,
            text: c.text, units: ["I do not", "have 10 cats."],
            keys: ["unit1", "unit2"], firstOCR: c.firstOCR)
        precondition(!c.matches(twoUnits),
            "A changed OCR unit split cannot borrow a one-unit prediction")
        for text in ["I have 10 cats.", "I do not have 20 cats.", "not have 10 cats.", "i do not have 10 cats.", "I do not have 10 cats!"] {
            precondition(!c.matches(norm.caption(text)))
        }
        precondition(!c.matches(norm.caption(source: "pt")))
        precondition(!c.matches(norm.caption(id: "different")))
        let legacy = Harness(); legacy.coordinator.system = .legacy
        legacy.coordinator.observe(legacy.caption(), confirmed: true, speculate: true); await legacy.settle()
        precondition(legacy.calls.isEmpty && legacy.selected.isEmpty)
        // A simultaneous speculative completion cannot outrun preferred-memory selection.
        let preferredRace = Harness(); preferredRace.coordinator.system = .lowLatency
        preferredRace.coordinator.observe(preferredRace.caption(), confirmed: false, speculate: true); await preferredRace.settle()
        preferredRace.delayedMemory = true
        preferredRace.coordinator.observe(preferredRace.caption(), confirmed: true, speculate: true); await preferredRace.settle()
        precondition(preferredRace.pendingLookups.count == 1)
        preferredRace.reply(0, ["New speculative wording"]); await preferredRace.settle()
        precondition(preferredRace.selected.isEmpty, "Memory priority waits only for the independent active probe")
        preferredRace.pendingLookups[0].resume(returning: ["Preferred saved wording"]); await preferredRace.settle()
        precondition(preferredRace.selected.count == 1 && preferredRace.selected[0].1.values == ["Preferred saved wording"])
        precondition(preferredRace.selected[0].2 == "memory_hit" && preferredRace.calls.count == 1)
        preferredRace.coordinator.reset()

        // Matching completed speculation is selected immediately, without another model call.
        let ready = Harness(); ready.coordinator.system = .lowLatency
        ready.coordinator.observe(ready.caption(), confirmed: false, speculate: true); await ready.settle()
        ready.reply(0, ["Ready"]); await ready.settle()
        ready.coordinator.observe(ready.caption(), confirmed: true, speculate: true); await ready.settle()
        precondition(ready.selected.count == 1 && ready.calls.count == 1)
        // Another caption can reuse the session-only LL cache, without contaminating preferred memory.
        ready.coordinator.observe(ready.caption(id: "another"), confirmed: true, speculate: false); await ready.settle()
        precondition(ready.selected.count == 2 && ready.calls.count == 1)
        precondition(ready.selected[1].1.origins == ["session_low_latency"])
        precondition(ready.selected[1].2 == "memory_hit", "Session-cache reuse must not be reported as fresh recovery")
        ready.coordinator.reset()

        // Exact repeated units are translated once and expanded to complete output.
        let duplicate = Harness(); duplicate.memory = [nil, nil]; duplicate.coordinator.system = .lowLatency
        let unique = duplicate.caption()
        let repeated = ModeCaption(session: unique.session, caption: unique.caption, revision: 1,
            source: unique.source, target: unique.target, rules: unique.rules, text: unique.text,
            units: unique.units + unique.units, keys: unique.keys + unique.keys, firstOCR: 1)
        duplicate.coordinator.observe(repeated, confirmed: true, speculate: false); await duplicate.settle()
        precondition(duplicate.calls.count == 1 && duplicate.calls[0].indices == [0])
        duplicate.reply(0, ["Complete"]); await duplicate.settle()
        precondition(duplicate.selected[0].1.values == ["Complete", "Complete"])
        duplicate.coordinator.reset()

        // Real source correction after display creates a new selectable revision.
        let revision = Harness(); revision.coordinator.system = .lowLatency
        revision.coordinator.observe(revision.caption(), confirmed: true, speculate: false); await revision.settle()
        revision.reply(0, ["First"]); await revision.settle()
        revision.coordinator.observe(revision.caption("I do not have 20 cats.", revision: 2), confirmed: true, speculate: false); await revision.settle()
        revision.reply(1, ["Corrected"]); await revision.settle()
        precondition(revision.selected.count == 2 && revision.events.contains("source_correction"))
        revision.coordinator.reset()

        // Focus loss, orientation/context changes and periodic scans recover the broad area.
        var focus = CaptionFocus()
        precondition(focus.scan(at: 0, y0: 0, y1: 1, context: "up").broad)
        focus.observe(bounds: [(center: 0.2, height: 0.04, confidence: 0.99)])
        let focused = focus.scan(at: 0.1, y0: 0, y1: 1, context: "up")
        precondition(!focused.broad && focused.y0 < 0.2 && focused.y1 > 0.2)
        precondition(focus.requiresRediscovery(scan: focused, recognized: "a changed prefix", previous: "old full caption"))
        precondition(focus.scan(at: 0.2, y0: 0, y1: 1, context: "up").broad)
        precondition(focus.scan(at: 0.99, y0: 0, y1: 1, context: "up").broad)
        focus.observe(bounds: [])
        precondition(focus.scan(at: 1.0, y0: 0, y1: 1, context: "up").broad)
        focus.observe(bounds: [(center: 0.2, height: 0.04, confidence: 0.99)])
        precondition(focus.scan(at: 1.1, y0: 0, y1: 1, context: "rotated").broad)
        focus.observe(bounds: [(center: 0.2, height: 0.04, confidence: 0.5)])
        precondition(focus.scan(at: 1.1, y0: 0, y1: 1, context: "rotated").broad)
        // A quick broadcast restart never allows delayed old UDP packets to revive it.
        var capture = CaptureSessionIdentityGate()
        precondition(capture.admit("first") == .newSession)
        precondition(capture.admit("first") == .current)
        precondition(capture.admit("second") == .newSession)
        precondition(capture.admit("first") == .rejected)
        precondition(!capture.stop("first"))
        precondition(capture.stop("second"))
        precondition(capture.admit("second") == .rejected)
        precondition(capture.admit("third") == .newSession)
        precondition(capture.admit(nil) == .rejected)
        // Language/caption identity supersedes recovery even when cancellation is ignored.
        let language = Harness(); language.coordinator.system = .lowLatency
        language.coordinator.observe(language.caption(), confirmed: true, speculate: false); await language.settle()
        language.coordinator.observe(language.caption("Não tenho gatos.", revision: 2, id: "new-caption", source: "pt"), confirmed: true, speculate: false); await language.settle()
        language.reply(0, ["Old language output"]); await language.settle()
        precondition(language.selected.isEmpty)
        language.reply(1, ["Current Portuguese output"]); await language.settle()
        precondition(language.selected.count == 1 && language.selected[0].0.source == "pt")
        language.coordinator.reset()

        // Pressure stops tentative work and gives confirmed work a recovery path.
        let pressure = Harness(); pressure.coordinator.system = .lowLatency
        pressure.coordinator.observe(pressure.caption(), confirmed: false, speculate: true); await pressure.settle()
        pressure.coordinator.observe(pressure.caption(), confirmed: true, speculate: true); await pressure.settle()
        pressure.coordinator.reduceSpeculation(memoryPressure: true); await pressure.settle()
        precondition(pressure.calls.count == 2 && pressure.calls[1].strategy == .lowLatency)
        pressure.reply(1, ["Confirmed under pressure"]); pressure.reply(0, ["Obsolete tentative result"]); await pressure.settle()
        precondition(pressure.selected.count == 1 && pressure.events.contains("memory_pressure"))
        pressure.coordinator.reset()

        var thermalCaption = norm.caption(); thermalCaption.thermal = 1
        precondition(thermalCaption.policyCohort == norm.caption().policyCohort,
            "Nominal and fair thermal evidence must use one full-performance cohort")
        precondition(norm.caption(source: "pt").policyCohort != norm.caption().policyCohort)
        precondition(CaptionClockOrigin.monotonic(firstSeen: 80, wallFirstSeen: 1000, wallNow: 5000, uptimeNow: 100) == 80,
            "Wall-clock changes cannot reset a supplied monotonic OCR origin")
        precondition(CaptionClockOrigin.monotonic(firstSeen: nil, wallFirstSeen: 995, wallNow: 1000, uptimeNow: 100) == 95)
        precondition(CaptionClockOrigin.monotonic(firstSeen: 500, wallFirstSeen: 995, wallNow: 1000, uptimeNow: 100) == 95)
        // ---- 2.5.0 ----
        // A saved Hybrid choice moves once to Low Latency, with one notice and a reason code that stays.
        let hybridSuite = "hybrid-migration-" + UUID().uuidString
        let hybridDefaults = UserDefaults(suiteName: hybridSuite)!
        defer { hybridDefaults.removePersistentDomain(forName: hybridSuite) }
        hybridDefaults.set("hybridRecovery", forKey: "translationSystem")
        let hybridMoved = TranslationSystem.migrate(hybridDefaults)
        precondition(hybridMoved.0 == .lowLatency && hybridMoved.1 == TranslationSystem.migratedHybridReason)
        precondition(hybridDefaults.string(forKey: "translationSystem") == "lowLatency" &&
                     hybridDefaults.bool(forKey: TranslationSystem.hybridNoticePendingKey), "Moved once, notice pending")
        let hybridAgain = TranslationSystem.migrate(hybridDefaults)
        precondition(hybridAgain.0 == .lowLatency && hybridAgain.1 == TranslationSystem.migratedHybridReason,
                     "The migration reason code stays for Diagnostics")
        // After the notice was seen, a preset or backup that still says Hybrid moves again without a second notice.
        hybridDefaults.set(false, forKey: TranslationSystem.hybridNoticePendingKey)
        hybridDefaults.set(true, forKey: TranslationSystem.hybridNoticeShownKey)
        hybridDefaults.set("hybridRecovery", forKey: "translationSystem")
        precondition(TranslationSystem.migrate(hybridDefaults).0 == .lowLatency &&
                     !hybridDefaults.bool(forKey: TranslationSystem.hybridNoticePendingKey), "The notice is shown once")
        precondition(TranslationSystem.allCases == [.legacy, .lowLatency], "Two modes")
        let oldModeNames = try? JSONDecoder().decode([TranslationSystem].self, from: Data("[\"hybridRecovery\",\"legacy\"]".utf8))
        precondition(oldModeNames == [.lowLatency, .legacy], "A record that names the removed mode still decodes")

        // Low Latency without its language pack asks; it never starts on another model.
        precondition(LowLatencyPackGate.decision(system: .legacy, sourceKnown: true, lowLatency: .unsupported) == .start)
        precondition(LowLatencyPackGate.decision(system: .lowLatency, sourceKnown: true, lowLatency: .installed) == .start)
        precondition(LowLatencyPackGate.decision(system: .lowLatency, sourceKnown: true, lowLatency: .supported) == .askForPack(canDownload: true))
        precondition(LowLatencyPackGate.decision(system: .lowLatency, sourceKnown: true, lowLatency: .unsupported) == .askForPack(canDownload: false))
        precondition(LowLatencyPackGate.decision(system: .lowLatency, sourceKnown: false, lowLatency: .supported) == .start,
                     "With an unknown source there is nothing to ask about yet")
        precondition(LowLatencyPackGate.decision(system: .lowLatency, sourceKnown: true, lowLatency: .unchecked) == .start)
        precondition(LowLatencyPackGate.message(source: "Portuguese", target: "English", canDownload: true).contains("Portuguese to English"),
                     "The question names the pair")

        // Item F: the head start is used only while the fast pass keeps being right.
        var headStart = HeadStartGovernor()
        precondition(!headStart.maySend && headStart.shouldRunPrePass(), "Learning: the fast pass runs, nothing is sent")
        for _ in 0..<5 { headStart.record(right: true) }
        precondition(!headStart.maySend, "Five right answers are not enough")
        headStart.record(right: true)
        precondition(headStart.maySend && headStart.shouldRunPrePass())
        headStart.record(right: false); headStart.record(right: false)
        precondition(!headStart.maySend && headStart.samples == 8, "6 of 8 right is below the required share")
        var headStartProbes = 0
        for _ in 0..<12 { if headStart.shouldRunPrePass() { headStartProbes += 1 } }
        precondition(headStartProbes == 2, "While it is off, one fast pass in six keeps the score current")
        for _ in 0..<12 { headStart.record(right: true) }
        precondition(headStart.maySend && headStart.samples == HeadStartGovernor.window, "It comes back when the fast pass is right again")

        // Items C and D: fixed names and buckets.
        precondition(ModelLengthBucket.bucket(characters: 0) == .to20 && ModelLengthBucket.bucket(characters: 20) == .to20 &&
                     ModelLengthBucket.bucket(characters: 21) == .to40 && ModelLengthBucket.bucket(characters: 80) == .to80 &&
                     ModelLengthBucket.bucket(characters: 81) == .to160 && ModelLengthBucket.bucket(characters: 161) == .over160)
        precondition(ModelLengthBucket.to40.metric == "modelLen21to40Ms" && V250Names.metrics.contains("modelLen161PlusMs"))
        precondition(V250Names.extraReadCounters.count == 8 && V250Names.extraReadLabels.count == 8 &&
                     ExtraReadCause.other.rawValue == 7 && V250Names.counters.count == 15)

        // Item E: the trusted caption band.
        func bandLine(_ center: Double, _ height: Double = 0.05, _ confidence: Double = 0.95) -> (center: Double, height: Double, confidence: Double) {
            (center, height, confidence)
        }
        var band = CaptionFocus()
        let bandFirst = band.scan(at: 0, y0: 0, y1: 1, context: "band", useBand: true)
        precondition(bandFirst.broad)
        band.learnBand(bounds: [bandLine(0.15)], broad: true); band.observe(bounds: [bandLine(0.15)])
        precondition(band.bandAgreement == 1 && band.trustedScanArea(y0: 0, y1: 1) == nil, "One whole-area read is not enough")
        let bandEarly = band.scan(at: 0.1, y0: 0, y1: 1, context: "band", useBand: true)
        precondition(!bandEarly.broad && !band.trusts(bounds: [bandLine(0.15)], scan: bandEarly), "Not trusted yet: the 2.4.0 rule applies")
        band.learnBand(bounds: [bandLine(0.4)], broad: false)
        precondition(band.bandAgreement == 1, "Focused reads never build trust")
        let bandSecond = band.scan(at: 0.8, y0: 0, y1: 1, context: "band", useBand: true)
        precondition(bandSecond.broad)
        band.learnBand(bounds: [bandLine(0.15)], broad: true); band.observe(bounds: [bandLine(0.15)])
        precondition(band.bandAgreement == 2)
        let bandFocused = band.scan(at: 0.9, y0: 0, y1: 1, context: "band", useBand: true)
        precondition(!bandFocused.broad && abs(bandFocused.y0 - 0.045) < 0.000001 && abs(bandFocused.y1 - 0.255) < 0.000001,
                     "A focused read covers the band: the caption lines plus 1.6 line heights each way")
        precondition(band.trusts(bounds: [bandLine(0.15), bandLine(0.21)], scan: bandFocused), "A caption that grew by one line is read whole and trusted")
        precondition(!band.trusts(bounds: [bandLine(0.24)], scan: bandFocused), "A line at the edge of the band may be cut off: not trusted")
        precondition(!band.trusts(bounds: [bandLine(0.15, 0.05, 0.6)], scan: bandFocused), "An unclear read is not trusted")
        precondition(!band.trusts(bounds: [bandLine(0.15)], scan: bandSecond), "A whole-area read needs no trust")
        precondition(!band.trusts(bounds: [], scan: bandFocused), "No text is not trusted: the whole area is read to confirm it")
        let bandOff = band.scan(at: 0.95, y0: 0, y1: 1, context: "band")
        precondition(!bandOff.broad && bandOff.y0 > bandFocused.y0, "Switch off: the 2.4.0 crop")
        band.observe(bounds: [])
        let bandGap = band.scan(at: 1.0, y0: 0, y1: 1, context: "band", useBand: true)
        precondition(!bandGap.broad && abs(bandGap.y0 - 0.045) < 0.000001, "The band outlives the gap between two captions")
        precondition(band.scan(at: 1.6, y0: 0, y1: 1, context: "band", useBand: true).broad, "The whole area is still read every 0.75 s")
        band.learnBand(bounds: [bandLine(0.15), bandLine(0.8)], broad: true)
        precondition(band.bandAgreement == 1 && band.trustedScanArea(y0: 0, y1: 1) == nil, "Text outside the band ends the trust")
        _ = band.scan(at: 5, y0: 0, y1: 1, context: "rotated", useBand: true)
        precondition(band.bandAgreement == 0, "A new context forgets the band")

        print("Two-mode migration, pack question, sharing, atomic selection, mismatch, cancellation, memory isolation, strategy purity, semantic identity and 2.5.0 policy checks passed")
    }
}
