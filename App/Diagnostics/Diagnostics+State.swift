import CryptoKit
import SwiftUI
import Charts
import os
import Darwin

extension Diagnostics {
    /// Counts one lookup outcome per unit; persistence and eviction counters have separate denominators.
    func recordMemory(_ outcome: MemoryDiagnosticOutcome, durationMs: Double = 0,
                      candidate: String? = nil, frameIndex: Int? = nil, unitKey: String? = nil,
                      count: Int = 1) {
        let token = beginRecorder(); defer { endRecorder(token) }
        guard enabled, count > 0 else { return }
        memoryOutcomes[outcome, default: 0] += count
        if modeActiveSystem == "legacy", outcome == .speculativeHit, let candidate {
            legacyModeContexts[candidate]?.speculativeHit = true
        }
        let finite = durationMs.isFinite && durationMs >= 0
        switch outcome {
        case .ramHit, .persistentHit, .legacyHit, .normalizedHit, .speculativeHit, .miss, .timeout, .compatibilityRejected, .databaseUnavailable:
            if finite { lookupSamples.append(durationMs) }
            if lookupSamples.count > 600 { lookupSamples.removeFirst(lookupSamples.count - 600) }
        case .persisted, .writeFailed:
            if finite { writeSamples.append(durationMs) }
            if writeSamples.count > 600 { writeSamples.removeFirst(writeSamples.count - 600) }
        default: break
        }
        // Preserve errors in basic mode; detailed events are pressure-aware.
        if detailedCollection || outcome == .writeFailed || outcome == .timeout || outcome == .databaseUnavailable {
            let safeID = detailedCollection ? stableCandidateID(candidate) : nil
            appendStructured(candidate: safeID, frameIndex: frameIndex, unitKey: unitKey,
                             stage: "memory", outcome: outcome.rawValue,
                             reason: outcome.rawValue, durationMs: durationMs)
        }
    }

    func memoryOutcomesForUI(_ outcome: MemoryDiagnosticOutcome) -> Int { memoryOutcomes[outcome, default: 0] }

    struct LegacyModeContext {
        let session: UUID
        var source: String
        let target: String
        let fingerprint: String
        let firstOCR: Double
        var fresh = false
        var speculativeHit = false
        /// 2.3.0: true only when THIS caption was seen unconfirmed with different text than it was confirmed with.
        /// Before 2.3.0 this compared against one value shared by all captions (the last early sighting of any caption).
        var mismatch = false
        /// 2.3.0: text fingerprint of this caption's latest unconfirmed sighting; nil when it had none.
        var earlyFingerprint: String?
        /// 2.3.1: the early translation of the same text was still running when the confirmed caption arrived.
        var speculationInFlight = false
    }
    func registerLegacyModeCaption(session: UUID, caption: String, source: String, target: String,
                                   fingerprint: String, firstOCR: Double, confirmed: Bool) {
        guard enabled, modeActiveSystem == "legacy" else { return }
        if legacyModeContexts[caption] == nil {
            // 2.3.0: drop only the oldest entries. Clearing everything at once also erased the context of a caption
            // whose translation was still running, so its enqueue was then labelled a memory hit or not recorded.
            if legacyModeContexts.count >= legacyModeContextLimit {
                let dropped = legacyModeContextOrder.prefix(legacyModeContextDropCount)
                for key in dropped { legacyModeContexts.removeValue(forKey: key) }
                legacyModeContextOrder.removeFirst(dropped.count)
                legacyContextResets += 1
            }
            legacyModeContexts[caption] = LegacyModeContext(session: session, source: source, target: target,
                fingerprint: fingerprint, firstOCR: firstOCR)
            legacyModeContextOrder.append(caption)
        }
        if !confirmed {
            legacyModeContexts[caption]?.earlyFingerprint = fingerprint
        } else if let early = legacyModeContexts[caption]?.earlyFingerprint {
            legacyModeContexts[caption]?.mismatch = early != fingerprint
        }
        legacyModeEvent(caption, reason: confirmed ? "confirmed" : "speculation_admitted")
    }

    /// 2.3.1: Legacy counterpart of Low Latency's speculation_match_in_flight. Called when a confirmed caption arrives while
    /// the early translation of exactly that text is still running. Only tags the caption's diagnostics context.
    func noteLegacySpeculationInFlightMatch(candidate: String?) {
        guard enabled, modeActiveSystem == "legacy", let candidate else { return }
        legacyModeContexts[candidate]?.speculationInFlight = true
    }

    func legacyModeEnqueued(_ caption: String, duration: Double, source: String) {
        legacyModeContexts[caption]?.source = source
        guard let context = legacyModeContexts[caption], modeActiveSystem == "legacy" else { return }
        let reason: String
        // 2.3.0: the old name "pip_enqueue_legacy_recovery" suggested a second attempt. It is the same fresh
        // translation of the confirmed text; the only difference is that the caption's early text had changed.
        if context.fresh { reason = context.mismatch ? "pip_enqueue_fresh_text_changed" : "pip_enqueue_confirmed_fresh" }
        else if context.speculativeHit {
            // 2.3.1: same two names Low Latency uses for the same two situations.
            reason = context.speculationInFlight ? "pip_enqueue_speculation_match_in_flight" : "pip_enqueue_speculation_match_ready"
        }
        else { reason = "pip_enqueue_memory_hit" }
        legacyModeEvent(caption, reason: reason, duration: duration)
    }

    func exportModeEventWindow() -> [TranslationModeTrace] {
        let recent = Array(modeTrace.suffix(5840))
        var identities = Set<String>()
        let merged = openingModeTrace + recent
        return merged.filter { event in
            let identity = event.session.uuidString + event.caption +
                String(event.revision) + event.reason + String(event.monotonicTime)
            return identities.insert(identity).inserted
        }.sorted { $0.monotonicTime < $1.monotonicTime }
    }

    func exportEventWindow() -> [StructuredDiagnosticEvent] {
        let recent = Array(structuredEvents.suffix(5872))
        let existing = Set(recent.map(\.id))
        let early = openingEvents.filter { !existing.contains($0.id) }
        return Array((early + recent).suffix(6000)).sorted { $0.timestamp < $1.timestamp }
    }

    func exportJSON() async {
        guard !exportInProgress else { return }
        exportInProgress = true
        defer { exportInProgress = false }
        let snapshot = sessionSnapshot()
        do {
            let url = try await exportWriter.export(snapshot)
            Sharer.present([url])
            archiveStatus = "JSON export ready"
        } catch { archiveStatus = "Export failed; no file was shared" }
    }

    /// Evidence ZIP for one saved run (pretty JSON stays inside the ZIP only).
    func exportRunZIP(_ id: UUID) async {
        guard !exportInProgress else { return }
        exportInProgress = true
        defer { exportInProgress = false }
        guard let snapshot = (try? await runStore.load(id: id))?.1 else {
            archiveStatus = "Run could not be loaded"; return
        }
        do {
            let url = try await exportWriter.exportZIP(snapshot)
            Sharer.present([url])
            archiveStatus = "ZIP diagnostic bundle ready"
        } catch {
            archiveStatus = "ZIP export failed; no file was shared"
        }
    }

    func exportZIP() async {
        guard !exportInProgress else { return }
        exportInProgress = true
        defer { exportInProgress = false }
        let snapshot = sessionSnapshot()
        do {
            let url = try await exportWriter.exportZIP(snapshot)
            Sharer.present([url])
            archiveStatus = "ZIP diagnostic bundle ready"
        } catch {
            archiveStatus = "ZIP export failed; no file was shared"
        }
    }
}
