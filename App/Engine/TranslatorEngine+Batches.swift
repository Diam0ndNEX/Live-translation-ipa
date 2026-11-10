import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    /// Translates many sentences in one call.
    func translateBatch(_ texts: [String], source: Locale.Language, target: Locale.Language,
                                installed: Bool, speculative: Bool = false,
                                partial: (@MainActor (Int, String) -> Void)? = nil) async -> [String]? {
        if #available(iOS 26.0, *), installed {
            let k = "\(source.minimalIdentifier)>\(targetCode)|\((activeTranslationSystem == .lowLatency) ? "low" : "default")"
            guard !Task.isCancelled else { return nil }
            if diag.enabled { diag.s.sessionKind = "Direct session (iOS 26)" }
            if speculative {
                let workContext = contextRevision
                let diagnosticEpoch = diag.started
                let lease = speculativeSessions.begin(key: k) {
                    diag.noteModelState("speculative_session_created")
                    if #available(iOS 26.4, *), (activeTranslationSystem == .lowLatency) {
                        return TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
                    }
                    return TranslationSession(installedSource: source, target: target)
                }
                if speculativeSessions.takeConflict() { diag.noteModelState("speculative_lease_conflict") }
                if activeTranslationSystem == .legacy, modelReadiness.source != source.minimalIdentifier || modelReadiness.target != target.minimalIdentifier {
                    modelReadiness = TranslationReadiness(source: source.minimalIdentifier, target: target.minimalIdentifier)
                }
                let result = await runBatch(lease.session, texts, speculative: true, partial: partial, observeReadiness: true)
                // A cancelled Swift task can still return a complete valid batch.
                // Only explicit session cancellation (tracked by the lease),
                // failure or context change prevents warm-session reuse.
                speculativeSessions.finish(lease, reusable: result != nil && workContext == contextRevision)
                if let requested = lease.cancellationRequestedAt, diag.started == diagnosticEpoch {
                    diag.noteModelState("speculative_stop_released",
                        durationMs: max(0, ProcessInfo.processInfo.systemUptime - requested) * 1000)
                }
                return result
            }
            // v2.0.0 G5: Legacy model calls are serialized. Reuse the idle,
            // warm prediction session for confirmed work so consecutive calls
            // stay on one session; fall back to the direct session on failure.
            if activeTranslationSystem == .legacy, flag("legacySharedSession", true),
               let shared = speculativeSessions.lendIdle(key: k) {
                if modelReadiness.source != source.minimalIdentifier || modelReadiness.target != target.minimalIdentifier {
                    modelReadiness = TranslationReadiness(source: source.minimalIdentifier, target: target.minimalIdentifier)
                }
                diag.noteModelState("legacy_shared_session_used")
                let shared_result = await runBatch(shared, texts, speculative: false, partial: partial, observeReadiness: true)
                speculativeSessions.returnLent(usable: shared_result != nil)
                if shared_result != nil { warmupStatus = "Ready"; return shared_result }
                if Task.isCancelled { return nil }
            }
            if directSession == nil || directKey != k {
                diag.noteModelState("model_session_created")
                if #available(iOS 26.4, *), (activeTranslationSystem == .lowLatency) {
                    directSession = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
                } else {
                    directSession = TranslationSession(installedSource: source, target: target)
                }
                directKey = k
            }
            if diag.enabled { diag.s.sessionKind = "Direct session (iOS 26)" }
            guard let session = directSession else { return nil }
            if activeTranslationSystem == .legacy, modelReadiness.source != source.minimalIdentifier || modelReadiness.target != target.minimalIdentifier {
                modelReadiness = TranslationReadiness(source: source.minimalIdentifier, target: target.minimalIdentifier)
            }
            let r = await runBatch(session, texts, speculative: speculative, partial: partial)
            if r == nil {
                if directSession === session { directSession = nil }
            } else { warmupStatus = "Ready" }
            return r
        }
        if diag.enabled { diag.s.sessionKind = "Hosted view (iOS 18)" }
        return await translateLegacy(texts, source: source, target: target, speculative: speculative)
    }

    func runBatch(_ session: TranslationSession, _ texts: [String],
                          warmup: Bool = false, speculative: Bool = false,
                          partial: (@MainActor (Int, String) -> Void)? = nil,
                          observeReadiness: Bool = false) async -> [String]? {
        let diagnosticEpoch = diag.started
        let readinessContext = contextRevision
        let readinessSource = modelReadiness.source, readinessTarget = modelReadiness.target
        let observesReadiness = activeTranslationSystem == .legacy && (observeReadiness || session === directSession || session === warmupSession)
        func record(_ reason: String, durationMs: Double? = nil, candidate: String? = nil) {
            if observesReadiness, readinessContext == contextRevision, activeTranslationSystem == .legacy,
               modelReadiness.source == readinessSource, modelReadiness.target == readinessTarget {
                if reason == "warmup_model_submitted" || reason == "confirmed_model_submitted" || reason == "speculative_model_submitted" {
                    modelReadiness.beginExecution(label: warmup ? "Running Legacy warm-up" : "Running translation request")
                } else if reason == "model_batch_completed" {
                    modelReadiness.finishExecution(success: true, milliseconds: durationMs)
                } else if reason == "model_batch_failed" {
                    modelReadiness.finishExecution(success: false, milliseconds: durationMs)
                } else if reason == "model_batch_cancelled" {
                    modelReadiness.execution = .pending; modelReadiness.sessions = .pending; modelReadiness.activeSince = nil
                    modelReadiness.explanation = "Model work was interrupted; live translation has priority."
                }
            }
            guard diagnosticEpoch == diag.started else { return }
            diag.noteModelState(reason, durationMs: durationMs, candidate: candidate)
        }
        let marker = modelPerf.beginInterval("TranslationBatch")
        defer { modelPerf.endInterval("TranslationBatch", marker) }
        let began = ProcessInfo.processInfo.systemUptime
        let sessionID = ObjectIdentifier(session)
        let measuresSwitch = !warmup && activeTranslationSystem == .legacy
        let otherSessionNearby = measuresSwitch &&
            (legacyModelInFlight.contains { $0.key != sessionID && $0.value > 0 } ||
             (legacyLastModelReturn.map { $0.session != sessionID && began - $0.at < 1.5 } ?? false))
        if measuresSwitch { legacyModelInFlight[sessionID, default: 0] += 1 }
        defer {
            if measuresSwitch {
                let remaining = (legacyModelInFlight[sessionID] ?? 1) - 1
                legacyModelInFlight[sessionID] = remaining > 0 ? remaining : nil
                legacyLastModelReturn = (sessionID, ProcessInfo.processInfo.systemUptime)
            }
        }
        let modelCandidate = warmup ? nil : currentPacket?.candidateID
        let first30s = !warmup && sessionStarted.map {
            let age = Date().timeIntervalSince($0)
            return age >= 0 && age <= 30
        } == true
        record(warmup ? "warmup_model_submitted" :
            (speculative ? "speculative_model_submitted" : "confirmed_model_submitted"), candidate: modelCandidate)
        let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        do {
            let result: [String]?
            if partial != nil && texts.count > 1 {
                // Never present partial subtitles. Store only completed units
                // in exact-context volatile memory. A failed batch stays failed.
                var collected: [Int: String] = [:]
                for try await response in session.translate(batch: reqs) {
                    guard let id = response.clientIdentifier,
                          let index = Int(id), index >= 0, index < texts.count,
                          collected[index] == nil else { continue }
                    let value = response.targetText
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    collected[index] = value
                    partial?(index, value)
                }
                result = collected.count == texts.count ?
                    (0..<texts.count).compactMap { collected[$0] } : nil
            } else {
                let res = try await session.translations(from: reqs)
                result = PipelineSafety.orderedTranslations(
                    res.map { ($0.clientIdentifier, $0.targetText) }, count: texts.count)
            }
            record(result == nil ? "model_batch_failed" : "model_batch_completed",
                durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
            if result != nil {
                record(warmup ? "warmup_model_completed" :
                    (speculative ? "speculative_model_completed" : "confirmed_model_completed"),
                    durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000,
                    candidate: modelCandidate)
                if measuresSwitch && !speculative {
                    record(otherSessionNearby ? "legacy_confirmed_after_switch" : "legacy_confirmed_no_switch",
                        durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
                }
            }
            if first30s {
                record("model_batch_first_30s",
                    durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
            }
            return result
        } catch {
            if Task.isCancelled || (warmup && warmupSuperseded) {
                record("model_batch_cancelled",
                    durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
                return nil
            }
            record("model_batch_failed",
                durationMs: (ProcessInfo.processInfo.systemUptime - began) * 1000)
            diag.event(.error, "Translation engine failed: \(error.localizedDescription)")
            return nil
        }
    }

    func schedulePresentation(_ text: String, _ result: String, generation: Int, context: Int, timing: PresentationTiming) {
        guard PresentationSchedule.isCurrent(generation: generation, context: context,
            currentGeneration: self.generation, currentContext: self.contextRevision,
            frozen: frozen, paused: paused, manual: manualMode) else { return }
        cancelPresentation()
        let delay = PresentationSchedule.remaining(policy: ud.string(forKey: "displayPolicy") ?? "immediate",
            minimum: num("minDisplay", 0), lastShown: lastShowDate.timeIntervalSince1970, now: Date().timeIntervalSince1970)
        guard delay > 0 else { show(text, result, timing: timing); return }
        waitingToDisplay = true
        let ticket = presentationID
        presentationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, ticket == self.presentationID else { return }
            self.waitingToDisplay = false
            guard PresentationSchedule.isCurrent(generation: generation, context: context,
                currentGeneration: self.generation, currentContext: self.contextRevision,
                frozen: self.frozen, paused: self.paused, manual: self.manualMode) else { return }
            self.show(text, result, timing: timing)
        }
    }

    func clearRAMCache() {
        invalidatePending()
        processMemory.normal.clear()
        segmentationCache.clear()
        // Temporary test entries are process-owned and are not reset by normal
        // memory maintenance, diagnostics reset, mode toggles or app switches.
    }
}
