import Foundation

// 2.6.0: stall recovery. Pure policy and switch definitions, no UI or engine state, and no reference to types from
// Shared.swift, so the ThreeModes and HotPathAB test programs compile and test it with the rest of
// TranslationSystem. Nothing here was measured on a device; the hang itself was never captured in a report.

extension TranslationHotPathAB {
    /// 2.6.0 switches: (setting key, pinned key, report label). Default ON; OFF gives the 2.5.6 behaviour.
    static let v260Switches: [(setting: String, pinned: String, report: String)] = [
        ("stallWatchdog", "stallWatchdogPinned", "stallWatchdogAB")
    ]
    /// Gives up on a translation call that never returns, and recovers a lane that stopped moving. It changes no
    /// caption while calls return normally.
    static var stallWatchdog: Bool {
        (UserDefaults.standard.object(forKey: "stallWatchdogPinned") as? Bool) ?? true
    }
    static let v260ReportLabels: [(key: String, label: String)] = [
        ("stallWatchdogAB", "stall watchdog and recovery")
    ]
}

/// Learns how long a model call may take before it is called hung. The limit follows this device and this run:
/// a multiple of the slow end (P95) of recent successful calls, never below a floor and never above a ceiling.
struct ModelStallLimit {
    static let floorSeconds = 6.0
    static let ceilingSeconds = 30.0
    /// Before any call succeeded the first call may load a model: allow more.
    static let coldSeconds = 15.0
    static let multiple = 6.0
    static let window = 50

    private(set) var recent: [Double] = []

    /// Records the duration of a call that returned normally. A call that was abandoned is never recorded.
    mutating func record(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        recent.append(seconds)
        if recent.count > Self.window { recent.removeFirst(recent.count - Self.window) }
    }

    /// A call abandoned after `abandonedAt` seconds that returned shortly afterwards was slow, not hung: widen.
    mutating func widen(afterLateReturn seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        recent.append(seconds)
        if recent.count > Self.window { recent.removeFirst(recent.count - Self.window) }
    }

    var p95: Double? {
        guard recent.count >= 5 else { return nil }
        let sorted = recent.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)
        return sorted[max(0, index)]
    }

    var limitSeconds: Double {
        guard let p95 else { return Self.coldSeconds }
        return min(Self.ceilingSeconds, max(Self.floorSeconds, p95 * Self.multiple))
    }
}

/// Lets exactly one of two racing outcomes through (the call returning or the timer).
final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
    var isClaimed: Bool { lock.lock(); defer { lock.unlock() }; return claimed }
}

enum ModelCallOutcome<Value> {
    case value(Value)
    case timedOut
}

enum ModelCallRace {
    /// Runs `work` in its own task and returns its result, or `.timedOut` after `limit` seconds. A call that
    /// ignores cancellation keeps running in the background; the caller moves on and the late result is dropped.
    /// Cancelling the awaiting task cancels the work, and the timer still ends the wait if the work ignores that.
    /// `onLateReturn` gets the total seconds when an abandoned call returns after all.
    static func run<Value>(limit: Double, onLateReturn: (@Sendable (Double) -> Void)? = nil,
                           _ work: @escaping () async throws -> Value) async throws -> ModelCallOutcome<Value> {
        let gate = ResumeGate()
        let box = TaskBox()
        let began = Date()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ModelCallOutcome<Value>, Error>) in
                let worker = Task {
                    do {
                        let value = try await work()
                        if gate.claim() { continuation.resume(returning: .value(value)) }
                        else { onLateReturn?(Date().timeIntervalSince(began)) }
                    } catch {
                        if gate.claim() { continuation.resume(throwing: error) }
                    }
                }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0.05, limit) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    if gate.claim() {
                        worker.cancel()
                        continuation.resume(returning: .timedOut)
                    }
                }
                box.set(worker: worker, timer: timer)
            }
        } onCancel: {
            box.cancelWorker()
        }
    }

    final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var worker: Task<Void, Never>?
        private var timer: Task<Void, Never>?
        private var cancelled = false
        func set(worker: Task<Void, Never>, timer: Task<Void, Never>) {
            lock.lock(); defer { lock.unlock() }
            self.worker = worker; self.timer = timer
            if cancelled { worker.cancel() }
        }
        func cancelWorker() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            worker?.cancel()
        }
    }
}

/// The recovery steps for a lane that stopped moving, tried in order and one at a time. A step is repeated only
/// after progress was seen in between. Pure: the engine performs the step and reports progress.
struct StallLadder {
    enum Rung: Int, CaseIterable {
        case laneReset = 1       // abandon the stuck drain, start a fresh one
        case sessionReset = 2    // also drop translation sessions
        case linkReset = 3       // also reopen the local capture link
        case unhealthy = 4       // nothing worked: say so and keep retrying slowly

        var reason: String {
            switch self {
            case .laneReset: return "stall_lane_reset"
            case .sessionReset: return "stall_session_reset"
            case .linkReset: return "stall_link_reset"
            case .unhealthy: return "stall_unhealthy"
            }
        }
    }

    /// Seconds queued work must wait before the first step, and the pause between steps.
    static let minimumStall = 8.0
    static let stepInterval = 10.0
    /// Once unhealthy, retry the whole ladder this often.
    static let unhealthyRetry = 60.0

    private(set) var next: Rung = .laneReset
    private(set) var lastRung: Rung?
    private(set) var lastStepAt: Double?
    private(set) var stallStartedAt: Double?

    /// `waiting` is how long the oldest queued confirmed work has been waiting (nil when nothing is queued).
    /// `limit` is the learned model-call limit: a stall is never declared sooner than that plus a margin.
    mutating func evaluate(now: Double, waiting: Double?, limit: Double) -> Rung? {
        guard let waiting else { progress(); return nil }
        let threshold = max(Self.minimumStall, limit + 3)
        guard waiting >= threshold else { return nil }
        if stallStartedAt == nil { stallStartedAt = now - waiting }
        if let last = lastStepAt {
            let pause = lastRung == .unhealthy ? Self.unhealthyRetry : Self.stepInterval
            guard now - last >= pause else { return nil }
        }
        let step = next
        lastStepAt = now
        lastRung = step
        if step == .unhealthy { next = .laneReset } else { next = Rung(rawValue: step.rawValue + 1) ?? .unhealthy }
        return step
    }

    /// Something moved (queued work was taken, a call returned, a caption was shown). Returns how long the stall
    /// lasted in seconds when one had started.
    @discardableResult
    mutating func progress(now: Double? = nil) -> Double? {
        defer { next = .laneReset; lastRung = nil; lastStepAt = nil; stallStartedAt = nil }
        guard let started = stallStartedAt, let now else { return nil }
        return max(0, now - started)
    }
}
