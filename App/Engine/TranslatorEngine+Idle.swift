import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    /// v2.0.0 test helper: empties only process-owned Temporary Memory so the
    /// next mode run cannot reuse the previous run's translations. Never
    /// touches saved memory or normal RAM. Refused while capture is live.
    @discardableResult
    func clearTemporaryTestMemory() -> Bool {
        guard !captureAlive else { return false }
        invalidatePending()
        processMemory.temporary.clear()
        temporaryMemoryEntries = 0
        return true
    }

    func deleteUnvalidatedLegacy() async throws -> Int {
        guard memoryReady, !captureAlive, !pipActive, !busy, !warming,
              !legacyValidationBusy, idleValidationTask == nil, !memorySaving,
              !memoryMutationInProgress, pendingMemory.isEmpty else { throw MemoryStoreError.unavailable }
        memoryMutationInProgress = true
        defer { memoryMutationInProgress = false; saveMemory(force: true) }
        invalidatePending()
        memoryRevision += 1
        let count = try await memoryStore.deleteUnvalidatedLegacy(revision: memoryRevision)
        // Pending legacy records are never RAM hits, so valid cached results
        // can stay intact. Reset only scan snapshots/cursors after COMMIT.
        legacyScanFingerprint = ""
        refreshLegacyScanContext()
        await refreshMemoryHealth()
        return count
    }

    /// After *every* suspension, capture and changed processing rules win over
    /// idle work. Never commit translations created under outdated settings.
    private func idleValidationStillSafe(revision: Int, target: String,
                                         rules: String) -> Bool {
        !Task.isCancelled && !captureAlive && !pipActive && !busy &&
        UIApplication.shared.applicationState == .active &&
        allowsPersistentTranslations && !flag("privateSession", false) && !flag("freshTranslationTest", false) &&
        !ProcessInfo.processInfo.isLowPowerModeEnabled &&
        ProcessInfo.processInfo.thermalState != .serious &&
        ProcessInfo.processInfo.thermalState != .critical &&
        contextRevision == revision && targetCode == target &&
        memoryRuleToken == rules && !memorySaving &&
        !memoryMutationInProgress && pendingMemory.isEmpty && memoryReady
    }

    /// Automatic batches of 24 or manual batches up to 48. Two concurrent
    /// sessions in Nominal thermal state, one in Fair. Every result is checked
    /// again before an all-or-nothing SQLite commit.
    func validateIdleLegacy(maxEntries: Int = IdleLegacyBatchPolicy.automaticEntries) async {
        guard mayRunIdleValidation else {
            legacyIdleValidationStatus = "Unavailable during capture or under device pressure"
            return
        }
        guard #available(iOS 26.0, *) else {
            legacyIdleValidationStatus = "Requires iOS 26 or newer"
            return
        }
        guard pairs("sourceFixes").isEmpty &&
              list("neverTranslate", lower: false).isEmpty else {
            legacyIdleValidationStatus = "Source substitutions or protected words prevent safe idle validation"
            return
        }
        lastIdleValidationAttempt = Date()
        legacyValidationBusy = true
        legacyBatchActive = true
        legacyBatchCompleted = 0
        legacyBatchProcessed = 0
        legacyBatchSkipped = 0
        legacyScanReasons = [:]
        legacyEstimatedRemainingMinutes = nil
        legacyBatchStartedAt = Date()
        legacyBatchTotal = 0
        let scanSource = sourceCode
        let scanTarget = targetCode
        let maxCount = max(1, min(IdleLegacyBatchPolicy.maximumEntries, maxEntries))
        let fair = ThermalPerformancePolicy.automaticPressure(for: ProcessInfo.processInfo.thermalState)
        let workers = IdleLegacyBatchPolicy.concurrency(thermalFair: fair)
        legacyBatchWorkers = workers
        legacyIdleValidationStatus = "Scanning up to \(maxCount) older entries…"
        diag.noteModelState("legacy_idle_started")
        defer {
            legacyValidationBusy = false
            legacyBatchActive = false
            legacyValidationElapsedSeconds = max(0, Date().timeIntervalSince(legacyBatchStartedAt))
            diag.recordLegacyValidationSnapshot(inventory: legacyValidationInventory,
                reasons: legacyScanReasons, source: scanSource, target: scanTarget)
            lastIdleValidationAttempt = Date()
        }

        let originalRevision = contextRevision
        let target = targetCode
        let rules = memoryRuleToken
        let sourceFilter: String? = sourceCode == "auto" ? nil : sourceCode
        var selected: [TranslationMemoryStore.LegacyIdleCandidate] = []
        var scanned = 0
        var exhausted = false
        do {
            legacyValidationInventory = try await memoryStore.legacyValidationInventory(
                target: target, selectedSource: sourceFilter)
            while selected.count < maxCount && scanned < 384 {
                guard idleValidationStillSafe(revision: originalRevision, target: target, rules: rules)
                else { return }
                // Request no more rows than we can consume. Otherwise an
                // early break can advance the cursor past unscheduled entries.
                let rows = try await memoryStore.nextLegacyIdleCandidates(
                    target: target, selectedSource: sourceFilter,
                    after: legacyValidationCursor, limit: min(64, maxCount - selected.count))
                if rows.isEmpty { exhausted = true; break }
                for entry in rows {
                    legacyValidationCursor = entry.id
                    scanned += 1
                    let reason: String?
                    if entry.source.isEmpty || entry.text.isEmpty {
                        reason = "Unreadable key or protected context"
                    } else if (flag("cleanOCR", true) && TextIntel.cleanOCR(entry.text) != entry.text) ||
                                (flag("slang", true) && TextIntel.expandSlang(entry.text, lang: entry.source) != entry.text) {
                        reason = "Needs cleanup or slang review"
                    } else {
                        let sentences = splitSentences(entry.text)
                        reason = sentences.count == 1 && sentences[0] == entry.text ? nil : "Needs sentence-unit review"
                    }
                    if let reason {
                        legacyBatchSkipped += 1
                        legacyScanReasons[reason, default: 0] += 1
                        continue
                    }
                    selected.append(entry)
                    if selected.count >= maxCount { break }
                }
            }
        } catch {
            legacyIdleValidationStatus = "Memory scan deferred; originals preserved"
            diag.noteModelState("legacy_idle_deferred")
            return
        }
        guard idleValidationStillSafe(revision: originalRevision, target: target, rules: rules)
        else { return }
        if exhausted { legacyValidationExhausted = true }
        if selected.isEmpty {
            legacyIdleValidationStatus = exhausted ?
                "No safe candidates for this language pair; see inventory and scan reasons below" :
                "Skipped \(legacyBatchSkipped) incompatible older entries"
            return
        }

        // Model availability varies by source when the user selects Automatic.
        var installed = Set<String>()
        for source in Set(selected.map(\.source)).sorted() {
            guard idleValidationStillSafe(revision: originalRevision, target: target, rules: rules)
            else { return }
            let from = Locale.Language(identifier: source)
            let to = Locale.Language(identifier: target)
            if from.languageCode != to.languageCode,
               await pairStatus(from, to) == .installed { installed.insert(source) }
        }
        guard idleValidationStillSafe(revision: originalRevision, target: target, rules: rules)
        else { return }
        let eligible = selected.filter { installed.contains($0.source) }
        legacyBatchSkipped += selected.count - eligible.count
        legacyScanReasons["Language model unavailable", default: 0] += selected.count - eligible.count
        let items = eligible.map { IdleLegacyWorkItem(id: $0.id, source: $0.source, text: $0.text) }
        let chunks = IdleLegacyBatchPolicy.chunks(items, limit: maxCount)
        legacyBatchTotal = items.count
        guard !chunks.isEmpty else {
            legacyIdleValidationStatus = "No installed models for these older entries"
            return
        }
        legacyIdleValidationStatus = "Translating \(items.count) entries with \(workers) workers…"

        // Task-group concurrency is bounded. Results contain only strings; the
        // SQLite actor alone owns durable writes after all sessions finish.
        let results: [(Int, [String]?)] = await withTaskGroup(
            of: (Int, [String]?).self, returning: [(Int, [String]?)].self
        ) { group in
            var next = 0
            func enqueue() {
                guard next < chunks.count else { return }
                let i = next
                next += 1
                let chunk = chunks[i]
                group.addTask {
                    let values = await Self.translateIdleChunk(
                        source: chunk.source, target: target, texts: chunk.items.map(\.text))
                    return (i, values)
                }
            }
            for _ in 0..<min(workers, chunks.count) { enqueue() }
            var output: [(Int, [String]?)] = []
            while let value = await group.next() {
                output.append(value)
                let completedChunk = chunks[value.0]
                legacyBatchProcessed += completedChunk.items.count
                legacyValidationElapsedSeconds = max(0, Date().timeIntervalSince(legacyBatchStartedAt))
                legacyIdleValidationStatus = "Translated \(legacyBatchProcessed)/\(items.count) • saving after batch"
                if idleValidationStillSafe(revision: originalRevision, target: target, rules: rules) {
                    enqueue()
                } else { group.cancelAll() }
            }
            return output
        }
        guard idleValidationStillSafe(revision: originalRevision, target: target, rules: rules)
        else {
            legacyIdleValidationStatus = "Stopped for live translation; old memory unchanged"
            diag.noteModelState("legacy_idle_deferred")
            return
        }
        var commits: [TranslationMemoryStore.LegacyIdleConfirmation] = []
        for (index, values) in results {
            let chunk = chunks[index]
            guard let values, values.count == chunk.items.count else {
                legacyBatchSkipped += chunk.items.count
                continue
            }
            for (item, translated) in zip(chunk.items, values) {
                guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    legacyBatchSkipped += 1
                    continue
                }
                commits.append(.init(id: item.id,
                    currentKey: PipelineSafety.cacheKey(
                        source: item.source, target: target, text: item.text,
                        protectedWords: [], rules: rules),
                    freshOutput: translated))
            }
        }
        guard !commits.isEmpty else {
            legacyIdleValidationStatus = "Models returned no valid translations; originals preserved"
            diag.noteModelState("legacy_idle_deferred")
            return
        }
        guard idleValidationStillSafe(revision: originalRevision, target: target, rules: rules)
        else { return }
        do {
            memoryRevision += 1
            let health = try await memoryStore.confirmIdleLegacyBatch(
                commits, revision: memoryRevision)
            legacyValidatedThisSession += commits.count
            legacyBatchCompleted = commits.count
            diag.noteLegacyBatch(selected: items.count, committed: commits.count,
                skipped: legacyBatchSkipped, workers: workers,
                durationMs: max(0, Date().timeIntervalSince(legacyBatchStartedAt) * 1000))
            applyMemoryHealth(health)
            let elapsed = max(0.1, Date().timeIntervalSince(legacyBatchStartedAt))
            let rate = Double(commits.count) * 60.0 / elapsed
            legacyAverageRate = legacyAverageRate == 0 ? rate : (0.6 * legacyAverageRate + 0.4 * rate)
            legacyEntriesPerMinute = legacyAverageRate
            if let health = memoryHealth, legacyAverageRate > 0 {
                legacyEstimatedRemainingMinutes = Double(health.legacyUnverified) / legacyAverageRate
            }
            legacyValidationElapsedSeconds = elapsed
            legacyIdleValidationStatus = "Validated \(commits.count)/\(items.count), skipped \(legacyBatchSkipped)"
            diag.noteModelState("legacy_idle_completed")
        } catch {
            legacyIdleValidationStatus = "Batch deferred; original memory preserved"
            diag.noteModelState("legacy_idle_deferred")
        }
    }

    /// Loads the translation models before they're needed so the first real sentence isn't slow.
    func prewarm() async {
        if activeTranslationSystem != .legacy {
            guard #available(iOS 26.4, *) else {
                modelReadiness.prepare(.unavailable)
                modeAvailability = "Explicit low latency requires iOS 26.4 or later"
                return
            }
            guard !captureAlive, initialWarmupTask == nil, !Task.isCancelled else { return }
            let code = sourceCode != "auto" ? sourceCode : SubtitlePerformancePolicy.predictiveSource(
                selected: sourceCode, detected: detectedLang == "–" ? nil : detectedLang,
                lastResolved: ud.string(forKey: "lastEffectiveSource"),
                ageSeconds: Date().timeIntervalSince1970 - ud.double(forKey: "lastEffectiveSourceAt"), enabled: flag("predictiveWarmup", true))
            guard let code, code != targetCode else {
                initialWarmupProgress = "Waiting for a known source language before initial warm-up"
                return
            }
            let destination = targetCode, system = activeTranslationSystem, context = modeSessionID
            let id = UUID(); initialWarmupID = id
            let task = Task { [weak self] in
                guard let self else { return }
                await self.refreshModePreparation(source: code, target: destination, system: system)
                guard !Task.isCancelled, context == self.modeSessionID, !self.captureAlive,
                      self.flag("keepWarm", true), self.runtimePolicy.allowsPrewarming, !self.paused,
                      !ProcessInfo.processInfo.isLowPowerModeEnabled,
                      ProcessInfo.processInfo.thermalState == .nominal || ProcessInfo.processInfo.thermalState == .fair,
                      self.modelReadiness.languages == .complete else { return }
                guard let samples = InitialWarmupSamples.units(source: code) else {
                    self.initialWarmupProgress = "No initial sample for this language; live translation remains available"
                    return
                }
                let deadline = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard !Task.isCancelled, let self, self.initialWarmupID == id else { return }
                    self.initialWarmupTask?.cancel(); self.modeService.cancelWarmup()
                    self.initialWarmupProgress = "Initial warm-up budget reached; waiting for outstanding work to return"
                }
                self.initialWarmupProgress = "Initial warm-up · once per language pair and strategy"
                let completed = await self.modeService.warmInitially(source: code, target: destination, system: system,
                    testMode: self.memoryTestMode.rawValue, samples: samples)
                deadline.cancel()
                if !Task.isCancelled, context == self.modeSessionID, !self.captureAlive {
                    if let completed {
                        self.initialWarmupProgress = completed == 0 ? self.modeService.warmupSkipDescription : "Initial warm-up finished · \(completed) strategy/strategies exercised"
                    } else { self.initialWarmupProgress = "Warm-up incomplete or deferred; live translations can retry normally" }
                }
            }
            initialWarmupTask = task
            await task.value
            if initialWarmupID == id { initialWarmupTask = nil }
            return
        }
        guard !Task.isCancelled, runtimePolicy.allowsPrewarming, flag("keepWarm", true), !paused,
              !legacyValidationBusy, !busy, !warming,
              queued == nil, !waitingToDisplay,
              Date().timeIntervalSince(lastWarm) > 25 else { return }
        warming = true
        defer { warming = false }
        let code: String
        var predicted = false
        if sourceCode != "auto" { code = sourceCode }
        else if let l = lockedLang { code = l }
        else if detectedLang != "–" { code = detectedLang }
        else if let previous = SubtitlePerformancePolicy.predictiveSource(
            selected: sourceCode, detected: nil,
            lastResolved: ud.string(forKey: "lastEffectiveSource"),
            ageSeconds: Date().timeIntervalSince1970 -
                ud.double(forKey: "lastEffectiveSourceAt"),
            enabled: flag("predictiveWarmup", true)) {
            code = previous
            predicted = true
        } else {
            warmupStatus = "Waiting for source language"
            if Date().timeIntervalSince(lastUnresolvedWarmupNotice) > 25 {
                lastUnresolvedWarmupNotice = Date()
                diag.noteModelState("warmup_source_unresolved")
            }
            return
        }
        let workContext = contextRevision
        let destination = targetCode
        let src = Locale.Language(identifier: code)
        let target = Locale.Language(identifier: destination)
        if modelReadiness.source != code || modelReadiness.target != destination {
            modelReadiness = TranslationReadiness(source: code, target: destination)
            restoreModelRun(source: code, target: destination, system: .legacy)
        }
        guard src.languageCode != target.languageCode,
              let word = Self.warmWords[src.languageCode?.identifier ?? code] else { return }
        // Avoid reloading the same model while a usable warm session exists.
        let warmKey = "\(src.minimalIdentifier)>\(destination)|\((activeTranslationSystem == .lowLatency) ? "low" : "default")"
        guard directSession == nil || directKey != warmKey else {
            warmupStatus = "Ready"
            // Retaining a handle alone is not evidence that the model ran.
            if modelReadiness.sessions != .complete { modelReadiness.explanation = "A Legacy session is retained; waiting for an observed model request." }
            return
        }
        modelReadiness.prepare(.checkingLanguages)
        let installed = await pairStatus(src, target) == .installed
        guard !Task.isCancelled,
              workContext == contextRevision, !busy, queued == nil,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else {
            if workContext == contextRevision {
                modelReadiness.languages = .pending; modelReadiness.activeSince = nil
                modelReadiness.explanation = "Preparation deferred for live work or current power and temperature conditions."
            }
            return
        }
        guard installed else { modelReadiness.prepare(.languagesUnavailable); return }
        modelReadiness.prepare(.languagesInstalled)
        // 2.2.1 (E18): with "liveWarmupLegacy" off, Legacy does not start a synthetic model call during live capture.
        if captureAlive, !flag("liveWarmupLegacy", true) {
            warmupStatus = "Ready"
            return
        }
        // Direct sessions can warm independently; the iOS 18 hosted path has one continuation.
        guard #available(iOS 26.0, *) else { return }
        lastWarm = Date()
        let t0 = Date()
        warmupStatus = predicted ? "Predictive warm-up…" : "Warming up…"
        modelReadiness.prepare(.creatingSessions)
        if captureAlive, diag.enabled { diag.s.warmupsDuringCapture += 1 } // 2.2.1 (E18): evidence for the report
        diag.noteModelState("warmup_started")
        if predicted { diag.noteModelState("warmup_predicted_source") }
        let session: TranslationSession
        if #available(iOS 26.4, *), (activeTranslationSystem == .lowLatency) {
            session = TranslationSession(installedSource: src, target: target, preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: src, target: target)
        }
        warmupSuperseded = false
        warmupSession = session
        defer { warmupSession = nil }
        // Exercise both a short word and a subtitle-length sentence on the same
        // retained session. Synthetic output never enters memory/history/PiP.
        let sample = Self.warmSentences[src.languageCode?.identifier ?? code]
        let warmed = await runBatch(session, [word] + (sample.map { [$0] } ?? []), warmup: true)
        guard !Task.isCancelled, !warmupSuperseded, workContext == contextRevision else {
            if workContext == contextRevision {
                modelReadiness.execution = .pending; modelReadiness.sessions = .pending
                modelReadiness.activeSince = nil; modelReadiness.explanation = "Warm-up yielded to live translation; it did not establish readiness."
            }
            warmupStatus = "Deferred for live translation"
            diag.noteModelState("warmup_preempted")
            return
        }
        warmupLastDurationMs = Date().timeIntervalSince(t0) * 1000
        warmupStatus = warmed == nil ? "Warm-up failed" :
            (predicted ? "Predicted source prepared" : "Ready")
        diag.noteModelState(warmed == nil ? "warmup_failed" : "warmup_succeeded",
            durationMs: Date().timeIntervalSince(t0) * 1000)
        if warmed != nil, !busy, workContext == contextRevision,
           (directSession == nil || directKey != warmKey) {
            directSession = session
            directKey = warmKey
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        if ms > 300 { diag.event(.translation, "Warmed up the translator in \(Int(ms)) ms") }
    }

    /// Translate the current text again from scratch (ignores the cache).
    func retranslate() {
        guard !original.isEmpty else { return }
        invalidatePending()
        if memoryTestMode != .temporaryMemory { ram.clear() }
        bypassMemory = true
        lastHandled = ""
        let blocks = original.components(separatedBy: "\n")
        diag.log("Retranslating current text")
        queuedPacket = nil
        queuedTs = Date().timeIntervalSince1970
        enqueue(blocks)
    }

    /// Re-reads everything after settings were changed in bulk.
    func reloadSettings() {
        translationSystemChanged()
        testModeSettingsChanged()
        suppressRecent = true
        sourceCode = ud.string(forKey: "source") ?? "auto"
        targetCode = ud.string(forKey: "target") ?? "en"
        suppressRecent = false
        invalidatePending()
        if lastConfiguredRotation != frameRotMode { rotationSettingChanged() }
        else { rotRev += 1; syncConfig() }
        applyStyle()
        applyWindowSize()
        applyHistoryRetention()
        objectWillChange.send()
    }
}
