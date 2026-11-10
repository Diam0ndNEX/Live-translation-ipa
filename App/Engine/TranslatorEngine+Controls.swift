import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    func tick() {
        tickCount += 1
        let conditions = translationConditions
        if currentRuntimeConditions != conditions { currentRuntimeConditions = conditions }
        if activeTranslationSystem != .legacy, initialWarmupTask != nil,
           ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            interruptWarmupForLiveWork()
            initialWarmupProgress = "Initial warm-up deferred by power or temperature conditions"
        }
        captureReadiness.tick(at: ProcessInfo.processInfo.systemUptime)
        publishCaptureStatus()
        let alive = Date().timeIntervalSince(lastPacketDate) < 5
        let thermalState = ProcessInfo.processInfo.thermalState
        if lastThermalSyncState != thermalState {
            lastThermalSyncState = thermalState
            // Restore full capture policy promptly after serious/critical
            // without touching active translation sessions or persistent memory.
            if alive { syncConfig() }
        }
        if captureAlive && !alive {
            status = "Capture stopped – iOS may have closed the capture extension. Tap the broadcast icon again (try Speed: Fast)."
            diag.log("Capture stopped")
            diag.noteRuntimeState("heartbeat_timeout")
            diag.pauseRun(reason: "heartbeatTimeout", frames: frames)
            if activeTranslationSystem != .legacy { invalidatePending() }
        }
        if captureAlive != alive { captureAlive = alive }
        if alive, let started = limitBase ?? sessionStarted, int("sessionLimit", 0) > 0,
           Date().timeIntervalSince(started) >= Double(int("sessionLimit", 0)) * 60, !paused {
            paused = true
            toast("Session timer reached – translation paused. Turn Pause off to continue; the timer starts again.")
            diag.noteRuntimeState("session_time_limit")
        }
        if activeTranslationSystem != .legacy,
           ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            modeCoordinator.reduceSpeculation(memoryPressure: false)
        }
        diag.noteThermalState()
        diag.tick(alive: alive, paused: paused, frozen: frozen)
        if tickCount % 5 == 0 { saveMemory() }
        if tickCount % 60 == 0 { applyHistoryRetention() }
        if tickCount % 5 == 0 { refreshLegacyScanContext() }
        if tickCount % 5 == 0, flag("legacyIdleValidationEnabled", false),
           !legacyValidationExhausted, mayRunIdleValidation {
            let fair = ThermalPerformancePolicy.automaticPressure(for: ProcessInfo.processInfo.thermalState)
            if Date().timeIntervalSince(lastIdleValidationAttempt) >=
                IdleLegacyBatchPolicy.cooldownSeconds(thermalFair: fair) {
                startLegacyValidation(maxEntries: IdleLegacyBatchPolicy.automaticEntries)
            }
        }
        if alive, !paused, tickCount % 10 == 0, Date().timeIntervalSince(lastTextDate) > 8,
           Date().timeIntervalSince(lastWarm) > 25 {
            Task { await prewarm() }
        }
        UIApplication.shared.isIdleTimerDisabled = alive && flag("keepAwake", true)
        if tickCount % 10 == 0, alive { syncConfig() }        // refreshes adaptive performance
        let idle = int("idleMinutes", 0)
        if idle > 0, alive, !paused, Date().timeIntervalSince(lastTextDate) > Double(idle) * 60 {
            paused = true
            status = "Paused after \(idle) min without text. Turn Pause off to resume; the idle timer starts again."
            diag.log("Auto-paused (idle)")
            diag.noteRuntimeState("idle_auto_pause")
        }
    }

    /// Called when the user changes the frame-rotation setting.
    func rotationSettingChanged() {
        rotationBudget.reset()
        lastConfiguredRotation = frameRotMode
        autoRot = 0; trial = 0; orderVote = 0; votesSinceChange = 0; calibrated = false
        rotRev += 1
        invalidatePending()
        syncConfig()
    }

    func languageSelectionChanged() {
        modelReadiness = TranslationReadiness()
        invalidatePending()
        languageRouter.reset(); languageContext.reset(); rotationBudget.reset()
        languageFailures = 0
        lockedLang = nil
        detectedLang = "–"
        latestBlocks = []
        // Re-evaluate automatic rotation from ReplayKit orientation, not the previous language's guess.
        autoRot = 0; trial = 0; orderVote = 0; votesSinceChange = 0; calibrated = false
        if diag.enabled { diag.s.orderVote = 0; diag.s.calibrated = false }
        // Reject in-flight OCR for the old pair and request fresh confirmation of static text.
        rotRev += 1
        syncConfig()
        diag.event(.language, "Source selection changed: \(sourceCode) → \(targetCode)")
        if activeTranslationSystem != .legacy { Task { [weak self] in await self?.prewarm() } }
    }

    func testModeSettingsChanged() {
        let next = TranslationTestMode(freshRequests: flag("freshTranslationTest", false),
                                       temporaryMemory: flag("temporaryMemoryTest", false))
        guard next != memoryTestMode else { return }
        // Close the old measurement cohort before changing cache access policy.
        diag.reset()
        invalidatePending()
        idleValidationTask?.cancel()
        memoryTestMode = next
        diag.translationTestMode = next
        diag.startingRAMEntries = next.allowsReuse ? ram.values.count : 0
        if temporaryMemoryEntries != processMemory.temporary.values.count {
            temporaryMemoryEntries = processMemory.temporary.values.count
        }
        bypassMemory = false
        rotRev += 1
        syncConfig()
        if let health = memoryHealth { applyMemoryHealth(health) }
    }

    /// Own-app visibility is observable; video playback in another app is not.
    /// Do not translate ScreenLingo's diagnostic/settings interface back into PiP.
    func setAppInterfaceVisible(_ visible: Bool) {
        guard visible != appInterfaceVisible else { return }
        appInterfaceVisible = visible
        rotRev += 1 // Reject packets produced before the visibility boundary.
        invalidatePending()
        diag.noteRuntimeState(visible ? "app_interface_visible" : "external_capture_period")
        syncConfig()
    }

    func pipelineSettingsChanged() {
        diag.noteRuntimeState("capture_config_changed")
        invalidatePending()
        rotRev += 1
        syncConfig()
    }

    /// Sends OCR area, source-language hint, speed and rotation to the extension.
    func syncConfig() {
        let r = area.range()
        var maxEdge = speed.maxEdge, interval = speed.interval
        if flag("adaptive", true) {
            switch ProcessInfo.processInfo.thermalState {
            case .serious: maxEdge *= 0.75; interval *= 1.5
            case .critical: maxEdge *= 0.55; interval *= 2.5
            default: break
            }
            if ProcessInfo.processInfo.isLowPowerModeEnabled { interval *= 1.5 }
            if extFreeMB > 0 && extFreeMB < 12 { maxEdge = min(maxEdge, 800) }
        }
        let intelligentCool = flag("coolMode", false) && flag("smartCool", true)
        if !intelligentCool { interval = runtimePolicy.captureInterval(interval) }
        if diag.enabled {
            diag.s.rotation = effectiveRot
            diag.noteCapturePolicy(edge: maxEdge, interval: interval,
                coolMode: flag("coolMode", false),
                memoryPressure: extFreeMB > 0 && extFreeMB < 12,
                workloadPressure: busy && queued != nil)
        }
        server.send(Config(lang: SourceLanguageRouter.captureLanguage(selected: sourceCode, locked: lockedLang), y0: r.lowerBound, y1: r.upperBound,
                           maxEdge: maxEdge, interval: interval, paused: paused || manualMode,
                           stability: int("stability", 2), rot: effectiveRot, rev: rotRev,
                           boost: int("boost", 1), skipUnchanged: flag("skipUnchanged", true),
                           subtitleAwareChangeDetection: flag("subtitleAwareChangeDetection", false),
                           speculate: speculationAllowed && flag("translateAhead", true), confidence: num("ocrConfidence", 0.3),
                           correction: flag("ocrCorrection", true), idleBackoff: flag("idleBackoff", true),
                           movieMode: flag("rapidTextTracking", true),
                           rapidTextTracking: flag("rapidTextTracking", true),
                           captureDiagnostics: diag.enabled,
                           adaptiveOCR: speed == .automatic || (speed == .balanced && flag("adaptiveOCR", true)),
                           adaptiveConfirmation: flag("adaptiveConfirmation", false), subtitleTracking: flag("subtitleTracking", true),
                           confirmationDeadline: num("confirmationDeadline", 0.6), smartCool: intelligentCool,
                           pressure: flag("adaptive", true) && (intelligentCool || speed == .automatic || (speed == .balanced && flag("adaptiveOCR", true))) && (ThermalPerformancePolicy.automaticPressure(for: ProcessInfo.processInfo.thermalState) || (busy && queued != nil)),
                           selectiveSpeculation: flag("selectiveSpeculation", true), speculationConfidence: num("speculationConfidence", 0.85),
                           detailCeiling: (ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical || (extFreeMB > 0 && extFreeMB < 12)) ? maxEdge : 2400,
                           confirmationBurst: !flag("coolMode", false),
                           appInterfaceVisible: appInterfaceVisible && flag("suppressOwnInterface", true),
                           focusedCaptionOCR: activeTranslationSystem != .legacy && flag("subtitleTracking", true),
                           strictCaptionIdentity: activeTranslationSystem != .legacy,
                           pixelConfirmation: flag("pixelConfirmation", true),
                           eventDrivenOCR: flag("eventDrivenOCR", true),
                           fastOCR: flag("fastOCR", false),
                           cjkSingleCharacters: flag("cjkSingleCharacters", true),
                           independentHeartbeat: TranslationHotPathAB.independentHeartbeat ? true : nil))
    }

    /// Invalidate suspended work before changing language, capture state, or settings.
    func invalidatePending() {
        if activeTranslationSystem != .legacy {
            modelReadiness.sessions = modelReadiness.sessions == .complete ? .idle : .pending
            modelReadiness.execution = modelReadiness.completedAt == nil ? .pending : .idle
            modelReadiness.activeSince = nil
            modelReadiness.explanation = "Current caption work was invalidated. Retained session handles need rechecking; a previous completed model run remains historical evidence."
        } else if modelReadiness.execution == .working {
            modelReadiness.execution = .pending; modelReadiness.activeSince = nil
            modelReadiness.explanation = "Previous work was interrupted; waiting for the current request."
        }
        modeWorkActivity = nil; modeActivityCaption = nil; modeActivitySelected = false
        preparationTicket = UUID()
        // A new capture/mode context deserves a fresh session readiness check.
        // The five-second retry throttle applies only within one unchanged context.
        lastModePreparationPair = ""
        lastModePreparationAt = .distantPast
        interruptWarmupForLiveWork()
        modeSessionID = UUID(); modeLastIdentity = ""; modePlans.removeAll(); modeMemoryOrigins.removeAll()
        modePreparedPlans.clear(); preparedUnits.clear()
        modeFingerprintDigests.removeAll(keepingCapacity: true)
        modeModelTimings.removeAll()
        if modeDiagnosticEpochs.count >= 64 { modeDiagnosticEpochs.removeAll() }
        modeDiagnosticEpochs[modeSessionID] = diag.started
        modeCoordinator.reset(); modeService.reset(preserveIdleSessions: true)
        contextRevision += 1
        generation += 1
        cancelDrain(preemptSpeculation: true)
        speculativeSessions.reset()
        deferredConfirmedPacket = nil
        confirmedHandoffDeadlineTask?.cancel()
        confirmedHandoffDeadlineTask = nil
        activeCandidateID = nil; activeCandidateText = ""
        movieTextFocus.reset()
        activeCandidateConfirmed = false; activeCandidatePresented = false
        cancelPresentation()
        queued = nil
        queuedPacket = nil
        queuedTs = Date().timeIntervalSince1970
        specQueued = nil
        lastHandled = ""
        lastSpecText = ""
        clearTask?.cancel()
        clearTask = nil
    }

    func toggleFrozenOutput() {
        frozen.toggle()
        invalidatePending()
        if !frozen, !latestBlocks.isEmpty { enqueue(latestBlocks) }
        status = frozen ? "Floating window frozen – capture continues" : "Live again"
    }

    func beginWorkspace() {
        manualMode = true
        lockedLang = nil; languageRouter.reset()
        clearOutput()
        invalidatePending()
        syncConfig()
    }

    func endWorkspace() {
        manualMode = false
        invalidatePending()
        syncConfig()
        if !paused { enqueue(latestBlocks) }
    }

    func translateText(_ text: String) {
        guard manualMode else { return }
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12000))
        guard !trimmed.isEmpty else { toast("Enter some text first"); return }
        frozen = false
        invalidatePending()
        queuedTs = Date().timeIntervalSince1970
        queuedPacket = nil
        enqueue([trimmed])
    }

    func clearOutput() {
        invalidatePending()
        showing = false; original = ""; translated = ""
        renderedGrams = placeholderGrams; sourceGrams = []
        pip.render(original: "", translated: "Listening…", showOriginal: false)
    }

    func timingSettingsChanged() {
        invalidatePending()
        pip.configureHeartbeat()
        syncConfig()
        if !paused, !manualMode { enqueue(latestBlocks) }
    }

    // MARK: History storage
    func saveHistory() {
        // Private translations are excluded when history is populated in show().
        // Explicit edits/deletions of existing history must still survive restart.
        guard flag("saveHistory", true) else { return }
        let started = ProcessInfo.processInfo.systemUptime
        let days = int("historyRetentionDays", 0)
        let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 86400) : Date.distantPast
        let retained = HistoryPolicy.trimmed(history.filter { $0.starred || $0.date >= cutoff }, capacity: historyCapacity)
        if let d = try? JSONEncoder().encode(retained) { ud.set(d, forKey: "historyData") }
        diag.noteHistorySave(ms: (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }
}
