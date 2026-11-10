import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    // MARK: Bounded concurrent, foreground-only legacy validation

    var mayRunIdleValidation: Bool {
        activeTranslationSystem == .legacy && memoryReady && !memorySaving && !memoryMutationInProgress &&
        pendingMemory.isEmpty && !legacyValidationBusy && !warming &&
        !captureAlive && !pipActive && !busy &&
        UIApplication.shared.applicationState == .active &&
        allowsPersistentTranslations && !flag("privateSession", false) && !flag("freshTranslationTest", false) &&
        !ProcessInfo.processInfo.isLowPowerModeEnabled &&
        ProcessInfo.processInfo.thermalState != .serious &&
        ProcessInfo.processInfo.thermalState != .critical
    }

    func cancelLegacyValidation() {
        idleValidationTask?.cancel()
        legacyIdleValidationStatus = "Stopping after current on-device model request…"
    }

    func startLegacyValidation(maxEntries: Int = IdleLegacyBatchPolicy.manualEntries) {
        guard activeTranslationSystem == .legacy else { legacyIdleValidationStatus = "Available in Legacy"; return }
        guard idleValidationTask == nil else { return }
        refreshLegacyScanContext()
        if legacyValidationExhausted {
            // Manual validation is a new scan after settings/model availability
            // may have changed; automatic idle checks avoid repeated futile scans.
            legacyValidationCursor = 0
            legacyValidationExhausted = false
        }
        idleValidationTask = Task { [weak self] in
            await self?.validateIdleLegacy(maxEntries: maxEntries)
            self?.idleValidationTask = nil
        }
    }

    /// One isolated model session per worker, with at most twelve texts in a
    /// single call. No shared foreground session, no 50 simultaneous models.
    nonisolated static func translateIdleChunk(source: String, target: String,
                                                       texts: [String]) async -> [String]? {
        guard #available(iOS 26.0, *), !Task.isCancelled, !texts.isEmpty else { return nil }
        let session = TranslationSession(installedSource: Locale.Language(identifier: source),
                                         target: Locale.Language(identifier: target))
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element,
                                       clientIdentifier: String($0.offset))
        }
        do {
            let response = try await withTaskCancellationHandler {
                try await session.translations(from: requests)
            } onCancel: {
                // Each idle worker owns this disposable session. Never cancel
                // the live retained session when foreground capture preempts it.
                session.cancel()
            }
            guard !Task.isCancelled else { return nil }
            return PipelineSafety.orderedTranslations(
                response.map { ($0.clientIdentifier, $0.targetText) }, count: texts.count)
        } catch { return nil }
    }
}
