import Foundation

@main struct SchedulerTests {
    @MainActor static func until(_ condition: @escaping () -> Bool) async {
        for _ in 0..<10000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Scheduler did not reach its expected suspension boundary")
    }

    @MainActor static func main() async {
        let probe = CaptionMemoryProbe()
        var pending: [String: CheckedContinuation<String?, Never>] = [:]
        var lookups: [String] = []
        var values: [String: String] = [:]
        var completed = 0
        var current = true
        let lookup: @MainActor (String) async -> String? = { key in
            lookups.append(key)
            return await withCheckedContinuation { pending[key] = $0 }
        }
        // Keep an unrelated model suspended. Saved text must arrive before it
        // releases: this is the actual asynchronous coordinator used by the app.
        var modelReleased = false
        var releaseModel: CheckedContinuation<Void, Never>?
        let occupiedModel = Task { @MainActor in
            await withCheckedContinuation { releaseModel = $0 }
            modelReleased = true
        }
        await until { releaseModel != nil }
        let accepted = probe.start(keys: ["A", "A", "B"], isCurrent: { current }, lookup: lookup,
            retain: { values[$0] = $1 }, completed: { completed += 1 })
        precondition(accepted)
        await until { pending["A"] != nil }
        pending.removeValue(forKey: "A")!.resume(returning: "First")
        await until { pending["B"] != nil }
        precondition(values == ["A": "First"] && !modelReleased)
        pending.removeValue(forKey: "B")!.resume(returning: "Second")
        await until { completed == 1 }
        precondition(lookups == ["A", "B"] && values["B"] == "Second" && !modelReleased)
        releaseModel?.resume()
        await occupiedModel.value
        precondition(modelReleased)

        probe.start(keys: ["old"], isCurrent: { current }, lookup: lookup,
            retain: { values[$0] = $1 }, completed: { completed += 1 })
        await until { pending["old"] != nil }
        probe.start(keys: ["new"], isCurrent: { current }, lookup: lookup,
            retain: { values[$0] = $1 }, completed: { completed += 1 })
        await until { pending["new"] != nil }
        pending.removeValue(forKey: "old")!.resume(returning: "Stale output")
        pending.removeValue(forKey: "new")!.resume(returning: "Current output")
        await until { completed == 2 }
        precondition(values["old"] == nil && values["new"] == "Current output",
            "Ignoring Task cancellation in storage must not permit a replaced caption to leak")

        probe.start(keys: ["changed-context"], isCurrent: { current }, lookup: lookup,
            retain: { values[$0] = $1 }, completed: { completed += 1 })
        await until { pending["changed-context"] != nil }
        current = false
        pending.removeValue(forKey: "changed-context")!.resume(returning: "Wrong language")
        for _ in 0..<100 { await Task.yield() }
        precondition(values["changed-context"] == nil && completed == 2,
            "A changed bank, rules, generation or privacy context must reject a late result")
        current = true

        let beforeMiss = lookups.count
        probe.start(keys: ["missing", "unneeded"], isCurrent: { current }, lookup: lookup,
            retain: { values[$0] = $1 }, completed: { completed += 1 })
        await until { pending["missing"] != nil }
        pending.removeValue(forKey: "missing")!.resume(returning: nil)
        await until { completed == 3 }
        precondition(lookups.count == beforeMiss + 1 && values["missing"] == nil,
            "A database miss must hand priority back without scanning unrelated keys")

        probe.start(keys: ["blank"], isCurrent: { current }, lookup: lookup,
            retain: { values[$0] = $1 }, completed: { completed += 1 })
        await until { pending["blank"] != nil }
        pending.removeValue(forKey: "blank")!.resume(returning: " \n ")
        await until { completed == 4 }
        precondition(values["blank"] == nil, "Malformed blank results must never enter caption RAM")
        precondition(!probe.start(keys: (0..<33).map(String.init), isCurrent: { current }, lookup: lookup,
            retain: { values[$0] = $1 }, completed: { completed += 1 }), "Probe work must remain bounded")
        precondition(!probe.start(keys: [], isCurrent: { current }, lookup: lookup,
            retain: { values[$0] = $1 }, completed: { completed += 1 }))
        probe.cancel()

        final class Handle { var cancelled = false }
        let owner = SpeculativeSessionOwner<Handle> { $0.cancelled = true }
        let warmed = Handle()
        var finishModel: CheckedContinuation<Void, Never>?
        let obsoleteTask = Task { @MainActor in
            let lease = owner.begin(key: "pt>en|default", make: { warmed })
            await withCheckedContinuation { finishModel = $0 }
            precondition(Task.isCancelled, "This completed model result belongs to an obsolete task")
            owner.finish(lease, reusable: true)
        }
        await until { finishModel != nil }
        obsoleteTask.cancel()
        finishModel?.resume()
        await obsoleteTask.value
        precondition(owner.takeReusable(key: "pt>en|default") === warmed && !warmed.cancelled,
            "Cooperative task replacement must preserve a successfully completed warm session")
        let invalidated = owner.begin(key: "pt>en|default", make: { Handle() })
        owner.reset()
        owner.finish(invalidated, reusable: true)
        precondition(invalidated.session.cancelled && owner.takeReusable(key: "pt>en|default") == nil,
            "Context invalidation still permanently retires obsolete sessions")
        print("Real asynchronous saved-caption bypass, replacement, context, miss and bounds checks passed")
    }
}
