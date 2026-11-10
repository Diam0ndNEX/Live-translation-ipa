import CryptoKit
import SwiftUI
import Charts
import os
import Darwin

extension Diagnostics {
    // MARK: Once a second
    func tick(alive: Bool, paused: Bool, frozen: Bool) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard enabled else { return }
        tickN += 1
        if let run = activeRun, Date().timeIntervalSince(run.lastCheckpointAt) >= 60 { checkpointRun() }
        let st: EngineState = !alive ? .idle : (paused ? .paused : (frozen ? .frozen : .live))
        if st != lastState {
            if let i = spans.indices.last { spans[i].end = Date() }
            if detailedCollection { spans.append(StateSpan(start: Date(), end: nil, state: st)) }
            if spans.count > 300 { spans.removeFirst() }
            // 2.3.2: a stop the user made is not a drop; a heartbeat timeout still is.
            if let prev = lastState, prev != .idle, st == .idle, pausedAt == nil || pauseReason == "heartbeatTimeout" { s.captureDrops += 1 }
            event(.state, "Now \(st.title)")
            switch st {
            case .idle: noteRuntimeState("capture_idle")
            case .live: noteRuntimeState("capture_live")
            case .paused: noteRuntimeState("capture_paused")
            case .frozen: noteRuntimeState("capture_frozen")
            }
            lastState = st
        }
        lastCaptureConnected = alive
        let now = Date()
        // Fine-grained data is bounded: latest 5 minutes at 1s, latest
        // 15 minutes at 5s; 15s buckets remain for long sessions/old readers.
        if detailedCollection && now.timeIntervalSince(oneSecondStart) >= 1 {
            if let completed = makeInterval(at: now, start: oneSecondStart, baseline: oneSecondBaseline) {
                oneSecondHistory.append(completed)
                if oneSecondHistory.count > 300 {
                    oneSecondHistory.removeFirst(oneSecondHistory.count - 300)
                }
            }
            oneSecondStart = now
            oneSecondBaseline = cumulativeCounters()
        } else if !detailedCollection {
            oneSecondHistory = []
            oneSecondStart = now
            oneSecondBaseline = cumulativeCounters()
        }
        if now.timeIntervalSince(fiveSecondStart) >= 5 {
            if let completed = makeInterval(at: now, start: fiveSecondStart, baseline: fiveSecondBaseline) {
                fiveSecondHistory.append(completed)
                if fiveSecondHistory.count > 180 {
                    fiveSecondHistory.removeFirst(fiveSecondHistory.count - 180)
                }
            }
            fiveSecondStart = now
            fiveSecondBaseline = cumulativeCounters()
        }
        if now.timeIntervalSince(intervalStart) >= 15 {
            if let completed = makeInterval(at: now, start: intervalStart, baseline: intervalBaseline) {
                intervalHistory.append(completed)
                if intervalHistory.count > 960 { intervalHistory.removeFirst(intervalHistory.count - 960) }
            }
            intervalStart = now
            intervalBaseline = cumulativeCounters()
        }
        if detailedCollection && tickN % 2 == 0 { sampleDevice(alive: alive) }
    }

    func cumulativeCounters() -> [String: Int] {
        [
            "captureFrames": s.frames, "capturePasses": s.passes,
            "capturePackets": s.packets, "ocrPackets": s.ocrPackets,
            "candidateConfirmed": s.confirmedCandidatePackets,
            "candidateEnqueued": s.enqueuedCandidateFrames,
            "candidateSuperseded": eventTotals["superseded", default: 0],
            "candidateCancelled": eventTotals["cancelled", default: 0],
            "candidateFirstSeen": eventTotals["firstSeen", default: 0],
            "speculativeRequests": s.specModelRequests,
            "specPreemptionRequested": s.specPreemptionRequested,
            "specMatchingConfirmation": s.specMatchingConfirmation,
            "specRetainedUnits": s.specRetainedUnits,
            "completedConfirmedUnitsRetained": completedWorkRecoveredUnits,
            "temporaryMemoryHits": temporaryMemoryHits,
            "exactCaptionHits": exactCaptionHits,
            "ramCaptionBypasses": ramCaptionBypasses,
            "memoryAwareSpeculationSkipped": memoryAwareSpeculationSkipped,
            "sharedInFlightUnits": sharedModelUnits,
            "sharedConfirmedInFlightUnits": sharedConfirmedModelUnits,
            "exactUnitsCoalesced": exactUnitsCoalesced,
            "speculativeUnitsRetained": speculativeUnitCounts["retained", default: 0],
            "speculativeUnitsReused": speculativeUnitCounts["reused", default: 0],
            "speculativeUnitsEvictedUnused": speculativeUnitCounts["evictedUnused", default: 0],
            "uncachedUnits": s.cacheMisses,
            "bypassedLookups": memoryOutcomes[.bypassed, default: 0],
            "temporaryMemoryMisses": memoryOutcomes[.temporaryMiss, default: 0],
            "speculativeDiscarded": s.specDiscarded,
            "legacyVerified": memoryHealth.legacyValidated,
            "legacySuperseded": memoryHealth.legacySuperseded,
            "legacyOCRSuggestions": memoryHealth.suggestedOCRMatches,
            "legacyFragmentSuggestions": memoryHealth.suggestedFragmentMatches,
            "legacyIdleStarted": eventTotals["legacy_idle_started", default: 0],
            "legacyIdleCompleted": eventTotals["legacy_idle_completed", default: 0],
            "ramHits": memoryOutcomes[.ramHit, default: 0],
            "persistentHits": memoryOutcomes[.persistentHit, default: 0],
            "speculativeHits": memoryOutcomes[.speculativeHit, default: 0],
            "lookupMisses": memoryOutcomes[.miss, default: 0],
            "unchangedSkips": s.unchangedSkipped, "cadenceSkips": s.cadenceSkipped,
            "pausedSkips": s.pausedSkipped, "emptyOCRPasses": s.emptyOCRPasses,
            "contrastRetries": s.retryCount, "movieSelections": s.movieSelections,
            "movieTemporalOverrides": s.movieTemporalOverrides,
            "movieRejectedSmall": s.movieRejectedSmall,
            "queueReplacements": s.queueReplacements,
            "earlyDeferred": s.deferredEarlyCandidates,
            "handoffDeferred": s.confirmedHandoffDeferred,
            "adaptiveSpeculationSkipped": s.adaptiveSpeculationSkipped,
            "legacyAdaptiveLowYieldSkips": s.legacyAdaptiveLowYieldSkips,
            "legacyAdaptiveSavedSkips": s.legacyAdaptiveSavedSkips,
            "legacyLowConfidenceSkips": s.legacyLowConfidenceSkips,
            "legacyBusySpeculationSkips": s.legacyBusySpeculationSkips,
            "legacyDuplicateSpeculationSkips": s.legacyDuplicateSpeculationSkips,
            "slowTailEnqueues": s.slowTailEnqueues,
            "manualTranslations": s.manualTranslations,
            "identicalFrameHolds": s.identicalFrameHolds,
            "warmupsDuringCapture": s.warmupsDuringCapture,
            "legacyBatchEntries": s.legacyBatchEntries,
            "legacyBatchVerified": s.legacyBatchVerified,
            "legacyBatchSkipped": s.legacyBatchSkipped,
            "unpresentedConfirmed": s.supersededUnpresentedConfirmed,
            "modelBatches": s.batches, "modelFailures": s.failures,
            "warmupAttempts": eventTotals["warmup_started", default: 0],
            "warmupSucceeded": eventTotals["warmup_succeeded", default: 0],
            "warmupPredicted": eventTotals["warmup_predicted_source", default: 0],
            // Legacy alias counts first-30s completions, not proven cold loads.
            "coldModelBatches": eventTotals["model_batch_first_30s", default: 0],
            "first30sModelBatches": eventTotals["model_batch_first_30s", default: 0],
            "confirmedModelBatches": eventTotals["confirmed_model_submitted", default: 0],
            "speculativeModelBatches": eventTotals["speculative_model_submitted", default: 0],
            "warmupModelBatches": eventTotals["warmup_model_submitted", default: 0],
            "actualModelBatches": eventTotals["confirmed_model_submitted", default: 0] +
                eventTotals["speculative_model_submitted", default: 0] + eventTotals["warmup_model_submitted", default: 0],
            "cancelledModelBatches": eventTotals["model_batch_cancelled", default: 0],
            "speculativeStopRequests": eventTotals["speculative_stop_requested", default: 0],
            "speculativeSessionsCreated": eventTotals["speculative_session_created", default: 0],
            "legacySharedSessionCalls": eventTotals["legacy_shared_session_used", default: 0],
            "legacyConfirmedOwnLane": eventTotals["legacy_confirmed_own_lane", default: 0],
            "handoffReplayed": eventTotals["handoff_replayed", default: 0],
            "handoffExpired": eventTotals["handoff_expired", default: 0],
            "enqueueFailed": eventTotals["enqueue_failed", default: 0],
            "runtimeTransitions": eventTotals["runtimeTransition", default: 0],
            "visualChanges": s.visualChanges
        ]
    }

    private func makeInterval(at now: Date, start: Date,
                              baseline: [String: Int]) -> DiagnosticIntervalBucket? {
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 0 else { return nil }
        let current = cumulativeCounters()
        var delta = current.reduce(into: [String: Int]()) { result, entry in
            result[entry.key] = max(0, entry.value - baseline[entry.key, default: 0])
        }
        let ocrTimes = ocr.filter { $0.t >= start && $0.t <= now }.map(\.v)
        let translationTimes = translate.filter { $0.t >= start && $0.t <= now }.map(\.v)
        let enqueueTimes = latency.filter { $0.t >= start && $0.t <= now }.map(\.v)
        let modelTimes = structuredEvents.filter {
            $0.timestamp >= start && $0.timestamp <= now &&
            $0.stage == "model_state" && $0.reasonCode == "model_batch_completed"
        }.compactMap(\.durationMs)
        delta["ocrMeasurementCount"] = ocrTimes.count
        delta["translationMeasurementCount"] = translationTimes.count
        delta["enqueueMeasurementCount"] = enqueueTimes.count
        let ocrTiming = DiagnosticDistribution(ocrTimes)
        let translationTiming = DiagnosticDistribution(translationTimes)
        let enqueueTiming = DiagnosticDistribution(enqueueTimes)
        let modelTiming = DiagnosticDistribution(modelTimes)
        let thermal: Int
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = 0
        case .fair: thermal = 1
        case .serious: thermal = 2
        case .critical: thermal = 3
        @unknown default: thermal = 0
        }
        return DiagnosticIntervalBucket(startedAt: start,
            elapsedSeconds: min(1800, elapsed), counters: delta,
            thermalLevel: thermal,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            captureConnected: lastCaptureConnected,
            effectiveOCRIntervalMs: s.effectiveOCRIntervalMs > 0 ? s.effectiveOCRIntervalMs : nil,
            visualChangeProxyMs: s.firstSightVisualChangeLagMs > 0 ?
                s.firstSightVisualChangeLagMs : nil,
            ocrMedianMs: ocrTiming.p50, ocrP95Ms: ocrTiming.p95,
            translationMedianMs: translationTiming.p50,
            translationP95Ms: translationTiming.p95,
            enqueueMedianMs: enqueueTiming.p50, enqueueP95Ms: enqueueTiming.p95,
            modelBatchMedianMs: modelTiming.p50)
    }

    func diagnosticIntervals(at now: Date) -> [DiagnosticIntervalBucket] {
        var all = intervalHistory
        if let current = makeInterval(at: now, start: intervalStart, baseline: intervalBaseline) {
            all.append(current)
        }
        return Array(all.suffix(960))
    }

    /// Read-only completed buckets for the live diagnostic UI. Does not
    /// recalculate statistics or store unbounded samples during rendering.
    func completedIntervals(seconds: Int) -> [DiagnosticIntervalBucket] {
        switch seconds {
        case 1: return oneSecondHistory
        case 5: return fiveSecondHistory
        default: return intervalHistory
        }
    }

    func recentIntervals(at now: Date, period: Int) -> [DiagnosticIntervalBucket] {
        let isOneSecond = period == 1
        let start = isOneSecond ? oneSecondStart : fiveSecondStart
        let baseline = isOneSecond ? oneSecondBaseline : fiveSecondBaseline
        var all = isOneSecond ? oneSecondHistory : fiveSecondHistory
        if let current = makeInterval(at: now, start: start, baseline: baseline) {
            all.append(current)
        }
        return Array(all.suffix(isOneSecond ? 300 : 180))
    }

    func diagnosticIntervals(at now: Date, period: Int) -> [DiagnosticIntervalBucket] {
        recentIntervals(at: now, period: period)
    }

    private func sampleDevice(alive: Bool) {
        lastDeviceSampleAt = Date()
        let level: Double
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: level = 0
        case .fair: level = 1
        case .serious: level = 2
        case .critical: level = 3
        @unknown default: level = 0
        }
        add(\.thermal, level, cap: 900)
        add(\.appMem, Double(os_proc_available_memory()) / 1_048_576, cap: 900)
        let b = Double(UIDevice.current.batteryLevel)
        if b >= 0 { add(\.battery, b * 100, cap: 900) }
        if alive, s.extFreeMB > 0 { add(\.extMem, s.extFreeMB, cap: 900) }
        let total = s.cacheHits + s.savedHits + s.specHits + s.cacheMisses
        if total > 0 { add(\.cacheRate, Double(s.cacheHits + s.savedHits + s.specHits) / Double(total) * 100, cap: 900) }
    }
}
