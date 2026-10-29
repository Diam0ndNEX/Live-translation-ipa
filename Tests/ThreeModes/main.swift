import Foundation

@MainActor
final class Harness {
    struct Call {
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
    var cancellations: [Bool] = []
    lazy var coordinator = ThreeModeCoordinator(
        lookup: { [weak self] _ in self?.memory ?? [nil] },
        translate: { [weak self] caption, indices, strategy, spec in
            await withCheckedContinuation { continuation in
                self?.calls.append(Call(caption: caption, strategy: strategy, speculative: spec, indices: indices, continuation: continuation))
            }
        }, cancel: { [weak self] spec in self?.cancellations.append(spec) },
        selected: { [weak self] caption, output, reason in self?.selected.append((caption, output, reason)) },
        event: { [weak self] _, reason, _ in self?.events.append(reason) }, status: { [weak self] _ in self?.events.append("status") })
    let session = UUID()
    func caption(_ text: String = "I do not have 10 cats.", revision: Int = 1, id: String = "caption", source: String = "en") -> ModeCaption {
        ModeCaption(session: session, caption: id, revision: revision, source: source, target: "de", rules: "rules", text: text,
            units: [text], keys: [text], firstOCR: 1)
    }
    func reply(_ index: Int, _ values: [String]?) { calls[index].continuation.resume(returning: values) }
    func settle() async { for _ in 0..<100 { await Task.yield() } }
}

@main struct ThreeModeTests {
    @MainActor static func main() async {
        let suite = "three-mode-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for (low, hybrid, expected) in [(false, false, TranslationSystem.legacy), (true, false, .lowLatency), (false, true, .hybridRecovery), (true, true, .hybridRecovery)] {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(low, forKey: "lowLatencyTranslation"); defaults.set(hybrid, forKey: "hybridTranslation")
            defaults.set("preserve", forKey: "unrelated")
            precondition(TranslationSystem.migrate(defaults).0 == expected)
            defaults.set(!low, forKey: "lowLatencyTranslation")
            precondition(TranslationSystem.migrate(defaults).0 == expected)
            precondition(defaults.string(forKey: "unrelated") == "preserve")
        }
        defaults.set("future-mode", forKey: "translationSystem")
        precondition(TranslationSystem.migrate(defaults).0 == .legacy)
        precondition(defaults.string(forKey: "translationSystem") == "future-mode")
        for system in [TranslationSystem.hybridRecovery, .lowLatency] {
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
            memory.reply(0, ["Late"]); await memory.settle(); memory.coordinator.reset()

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
        // Failed LL requests have a bounded same-strategy retry and no default refinement.
        let fail = Harness(); fail.coordinator.system = .lowLatency
        fail.coordinator.observe(fail.caption(), confirmed: true, speculate: false); await fail.settle()
        fail.reply(0, nil); await fail.settle(); fail.reply(1, nil); await fail.settle()
        precondition(fail.calls.count == 2 && fail.calls.allSatisfy { $0.strategy == .lowLatency })
        precondition(fail.selected.isEmpty && fail.events.contains("status"))
        fail.coordinator.reset()
        // Ready speculation survives harmless whitespace, but never changed meaning.
        let norm = Harness()
        let c = norm.caption()
        precondition(c.matches(norm.caption("I do not\nhave 10 cats.")))
        for text in ["I have 10 cats.", "I do not have 20 cats.", "not have 10 cats.", "i do not have 10 cats.", "I do not have 10 cats!"] {
            precondition(!c.matches(norm.caption(text)))
        }
        precondition(!c.matches(norm.caption(source: "pt")))
        precondition(!c.matches(norm.caption(id: "different")))
        let legacy = Harness(); legacy.coordinator.system = .legacy
        legacy.coordinator.observe(legacy.caption(), confirmed: true, speculate: true); await legacy.settle()
        precondition(legacy.calls.isEmpty && legacy.selected.isEmpty)
        print("Three-mode migration, sharing, atomic selection, mismatch, cancellation, memory isolation, strategy purity and semantic identity checks passed")
    }
}
