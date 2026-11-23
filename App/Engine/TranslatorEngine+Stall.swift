import SwiftUI
import Translation
import os

// 2.6.0: stall recovery. The report "translation stops after a while" could not be explained from earlier reports.
// Code reading found one gap: a model call had no time limit, and the drain stays busy until the call returns.
// Everything here is unverified on a device (nothing was compiled or run when it was written).
extension TranslatorEngine {
    /// Called by runBatch around every live model call. A call that returns normally teaches the limit.
    func noteModelCallReturned(seconds: Double) {
        modelStall.record(seconds: seconds)
        laneProgressAt = ProcessInfo.processInfo.systemUptime
    }

    func noteModelCallStarted() {
        laneProgressAt = ProcessInfo.processInfo.systemUptime
    }

    /// Learned limit for one model call (seconds).
    var modelCallLimitSeconds: Double { modelStall.limitSeconds }

    /// A call was abandoned because it did not return in time.
    func noteModelCallHung(after seconds: Double) {
        diag.noteModelState("model_call_hung", durationMs: seconds * 1000)
        diag.log("Translation call did not return after \(Int(seconds)) s; continuing without it")
    }

    /// An abandoned call returned after all: it was slow, not hung, so the limit grows.
    func noteModelCallLateReturn(seconds: Double) {
        modelStall.widen(afterLateReturn: seconds)
        diag.noteModelState("model_call_late_return", durationMs: seconds * 1000)
    }

    /// Once a second from tick(). Declares a stall when confirmed work has been waiting while no model call
    /// started or ended, and then tries one recovery step at a time (lane, sessions, local link).
    func stallWatchdogTick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard TranslationHotPathAB.stallWatchdog, !paused, !frozen, captureAlive else {
            laneProgressAt = now
            stallLadder.progress()
            return
        }
        guard queued != nil, !waitingToDisplay else {
            // Nothing is waiting: the lane is not stalled. A stall that ended is recorded with its length.
            laneProgressAt = now
            if let length = stallLadder.progress(now: now), length >= StallLadder.minimumStall {
                diag.noteModelState("stall_recovered", durationMs: length * 1000)
            }
            return
        }
        let waiting = max(0, now - laneProgressAt)
        guard let rung = stallLadder.evaluate(now: now, waiting: waiting, limit: modelStall.limitSeconds) else { return }
        performStallRung(rung)
    }

    func performStallRung(_ rung: StallLadder.Rung) {
        diag.noteModelState(rung.reason, durationMs: max(0, ProcessInfo.processInfo.systemUptime - laneProgressAt) * 1000)
        switch rung {
        case .laneReset:
            abandonLane()
        case .sessionReset:
            dropModelSessions()
            abandonLane()
        case .linkReset:
            dropModelSessions()
            server.restart()
            abandonLane()
        case .unhealthy:
            dropModelSessions()
            abandonLane()
            toast("Translation is not responding. If captions do not return, restart capture, then the app.")
        }
        laneProgressAt = ProcessInfo.processInfo.systemUptime
    }

    /// Abandons the drain that is stuck and starts a new one for the queued caption. A late return of the old
    /// drain cannot reset anything: its epoch no longer matches.
    func abandonLane() {
        drainEpoch += 1
        drainTask?.cancel()
        drainTask = nil
        busy = false
        activeQueueOwner = .scheduling
        currentSpeculativeText = nil
        startDrain()
    }

    func dropModelSessions() {
        directSession = nil
        directKey = ""
        speculativeSessions.reset()
    }
}
