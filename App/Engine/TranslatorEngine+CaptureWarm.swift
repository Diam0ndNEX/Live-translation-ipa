import SwiftUI
import Translation

/// 2.5.0 (item A and the quiet re-warm): one short model call when it is known that captions are about to come,
/// so the first caption does not pay for loading the model (467 to 1156 ms in the 2.4.0 device test).
/// The output is thrown away. It changes timing only: no caption is read, confirmed or worded differently.
/// Whether iOS keeps the model loaded afterwards is not known; the effect is UNVERIFIED.
extension TranslatorEngine {
    /// The source language a warm-up can use now, or nil when Automatic has nothing to go on yet.
    private func captureWarmSource() -> String? {
        if sourceCode != "auto" { return sourceCode }
        if let locked = lockedLang { return locked }
        if detectedLang != "–" { return detectedLang }
        return SubtitlePerformancePolicy.predictiveSource(
            selected: sourceCode, detected: nil,
            lastResolved: ud.string(forKey: "lastEffectiveSource"),
            ageSeconds: Date().timeIntervalSince1970 - ud.double(forKey: "lastEffectiveSourceAt"),
            enabled: flag("predictiveWarmup", true))
    }

    private var captureWarmAllowed: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        return flag("keepWarm", true) && runtimePolicy.allowsPrewarming && !paused && !manualMode &&
            !ProcessInfo.processInfo.isLowPowerModeEnabled && (thermal == .nominal || thermal == .fair)
    }

    /// Item A. Called when capture connects, and again when ScreenLingo leaves the screen during capture (that
    /// step drops unfinished work, a running warm-up included).
    func warmAtCaptureStart() {
        guard TranslationHotPathAB.warmAtCaptureStart, captureAlive,
              Date().timeIntervalSince(lastCaptureWarmSuccess) > 20 else { return }
        startCaptureWarm(counter: "captureStartWarmups", metric: "captureStartWarmupMs")
    }

    /// Extra (spec 4b), Low Latency only: after 15 s without a caption, at most once a minute. Legacy already has
    /// its own warm-up during quiet capture (`prewarm` from `tick`).
    func rewarmAfterQuietIfDue() {
        guard TranslationHotPathAB.quietRewarm, activeTranslationSystem == .lowLatency, captureAlive,
              !appInterfaceVisible || !flag("suppressOwnInterface", true),
              Date().timeIntervalSince(lastTextDate) > 15,
              Date().timeIntervalSince(lastCaptureWarmAttempt) > 60 else { return }
        startCaptureWarm(counter: "quietRewarms", metric: "quietRewarmMs")
    }

    private func startCaptureWarm(counter: String, metric: String) {
        guard captureWarmAllowed, let code = captureWarmSource(), code != targetCode,
              Locale.Language(identifier: code).languageCode != Locale.Language(identifier: targetCode).languageCode
        else { return }
        let ticket = UUID()
        captureWarmTicket = ticket
        lastCaptureWarmAttempt = Date()
        let system = activeTranslationSystem, destination = targetCode
        Task { [weak self] in
            guard let self else { return }
            let began = ProcessInfo.processInfo.systemUptime
            let warmed: Bool
            if system == .lowLatency {
                warmed = await self.warmLowLatencyForCapture(source: code, target: destination, ticket: ticket)
            } else {
                warmed = await self.warmLegacyForCapture(source: code, target: destination, ticket: ticket)
            }
            guard warmed, self.captureWarmTicket == ticket else { return }
            self.lastCaptureWarmSuccess = Date()
            self.diag.noteV250(counter: counter)
            self.diag.noteV250(metric: metric, ms: (ProcessInfo.processInfo.systemUptime - began) * 1000)
        }
    }

    private func warmLowLatencyForCapture(source: String, target: String, ticket: UUID) async -> Bool {
        guard #available(iOS 26.4, *), let samples = InitialWarmupSamples.units(source: source) else { return false }
        // A warm-up that was just dropped may still hold the warm-up lane for a moment.
        for _ in 0..<4 where modeService.warmupLane.busy {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard captureWarmTicket == ticket else { return false }
        }
        guard captureWarmTicket == ticket, activeTranslationSystem == .lowLatency else { return false }
        let completed = await modeService.warmInitially(source: source, target: target, system: .lowLatency,
            testMode: memoryTestMode.rawValue, samples: samples, repeatable: true)
        return (completed ?? 0) > 0
    }

    private func warmLegacyForCapture(source code: String, target destination: String, ticket: UUID) async -> Bool {
        guard #available(iOS 26.0, *), flag("liveWarmupLegacy", true), !warming, !busy, queued == nil,
              !legacyValidationBusy else { return false }
        let source = Locale.Language(identifier: code), target = Locale.Language(identifier: destination)
        guard let word = Self.warmWords[source.languageCode?.identifier ?? code] else { return false }
        let context = contextRevision
        warming = true
        defer { warming = false }
        guard await pairStatus(source, target) == .installed, context == contextRevision,
              captureWarmTicket == ticket, activeTranslationSystem == .legacy, !busy, queued == nil else { return false }
        lastWarm = Date()
        if captureAlive, diag.enabled { diag.s.warmupsDuringCapture += 1 }
        diag.noteModelState("warmup_started")
        let session = TranslationSession(installedSource: source, target: target)
        warmupSuperseded = false
        warmupSession = session
        defer { warmupSession = nil }
        let sentence = Self.warmSentences[source.languageCode?.identifier ?? code]
        let warmed = await runBatch(session, [word] + (sentence.map { [$0] } ?? []), warmup: true)
        guard warmed != nil, !warmupSuperseded, context == contextRevision else {
            diag.noteModelState(warmed == nil ? "warmup_failed" : "warmup_preempted")
            return false
        }
        diag.noteModelState("warmup_succeeded")
        // Keep the warmed session for the first caption, as `prewarm` does.
        let key = "\(source.minimalIdentifier)>\(destination)|default"
        if !busy, directSession == nil || directKey != key {
            directSession = session
            directKey = key
        }
        warmupStatus = "Ready"
        return true
    }
}
