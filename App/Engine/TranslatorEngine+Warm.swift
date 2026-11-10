import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    func toggleStar(_ id: UUID) {
        if let i = history.firstIndex(where: { $0.id == id }) { history[i].starred.toggle(); flushHistorySave() }
    }

    // iOS 18 path (needs the hosted .translationTask view in RootView)
    func translateLegacy(_ texts: [String], source: Locale.Language, target: Locale.Language,
                                 speculative: Bool = false) async -> [String]? {
        let requestID = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { (cont: CheckedContinuation<[String]?, Never>) in
                legacyRequestID = requestID
                legacyContinuation = cont
                pendingTexts = texts
                legacySpeculative = speculative
                if var c = legacyConfig, c.source == source, c.target == target {
                    c.invalidate(); legacyConfig = c
                } else {
                    if #available(iOS 26.4, *), (activeTranslationSystem == .lowLatency) {
                        legacyConfig = .init(source: source, target: target, preferredStrategy: .lowLatency)
                    } else {
                        legacyConfig = .init(source: source, target: target)
                    }
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    if self?.legacyRequestID == requestID { self?.finishLegacy(nil) }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.legacyRequestID == requestID else { return }
                self.legacyConfig = nil
                self.finishLegacy(nil)
            }
        }
    }
    func runLegacy(_ session: TranslationSession) async {
        // A view task for an older pair can enter after a settings change.
        // Never attach the newest request's texts/continuation to that session.
        guard let config = legacyConfig,
              session.sourceLanguage?.minimalIdentifier == config.source?.minimalIdentifier,
              session.targetLanguage?.minimalIdentifier == config.target?.minimalIdentifier else { return }
        let requestID = legacyRequestID
        let texts = pendingTexts
        let speculative = legacySpeculative
        if activeTranslationSystem == .legacy, let source = config.source?.minimalIdentifier, let target = config.target?.minimalIdentifier,
           modelReadiness.source != source || modelReadiness.target != target {
            modelReadiness = TranslationReadiness(source: source, target: target)
        }
        let result = await runBatch(session, texts, speculative: speculative, observeReadiness: true)
        if legacyRequestID == requestID { finishLegacy(result) }
    }
    private func finishLegacy(_ r: [String]?) {
        legacyContinuation?.resume(returning: r)
        legacyContinuation = nil
    }
}
