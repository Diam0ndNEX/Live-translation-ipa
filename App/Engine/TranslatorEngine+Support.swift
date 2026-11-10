import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    static var settingKeys: [String] { presetKeys + interfaceKeys }
    static func languageState(_ status: LanguageAvailability.Status) -> LanguageAssetState {
        switch status {
        case .installed: return .installed
        case .supported: return .supported
        case .unsupported: return .unsupported
        @unknown default: return .unchecked
        }
    }

    static func platformStatus(_ status: LanguageAssetState) -> LanguageAvailability.Status? {
        switch status {
        case .installed: return .installed
        case .supported: return .supported
        case .unsupported: return .unsupported
        case .unchecked: return nil
        }
    }

    func languageCoverage(for code: String) -> TranslationLanguageCoverage {
        TranslationLanguageCoverage(appleDefault: defaultLangStatus[code] ?? .unchecked,
                                    lowLatency: lowLatencyLangStatus[code] ?? .unchecked)
    }

    var languageSummary: String {
        let code = sourceCode != "auto" ? sourceCode :
            (detectedLang != "–" ? detectedLang : (lockedLang ?? ""))
        guard !code.isEmpty else { return "Automatic source: select or detect a language to check its packs" }
        return languageCoverage(for: code).explanation(for: pendingTranslationSystem)
    }

    func flushHistorySave() { historyWriter.flush() }
    func modelRunKey(_ source: String, _ target: String, _ strategy: RequestedTranslationStrategy) -> String {
        source + ">" + target + "|" + strategy.rawValue
    }

    func recordModelRun(source: String, target: String, strategy: RequestedTranslationStrategy,
                                milliseconds: Double?, at: Date = Date()) {
        guard !source.isEmpty, !target.isEmpty, source != target else { return }
        observedModelRuns[modelRunKey(source, target, strategy)] = (at, milliseconds)
        if observedModelRuns.count > 128,
           let oldest = observedModelRuns.min(by: { $0.value.at < $1.value.at }) {
            observedModelRuns.removeValue(forKey: oldest.key)
        }
    }

    func activateTranslationSystem() {
        let selection = TranslationSystem.migrate(ud)
        pendingTranslationSystem = selection.0
        if activeTranslationSystem != selection.0 {
            if activeTranslationSystem == .legacy, let at = modelReadiness.completedAt {
                recordModelRun(source: modelReadiness.source, target: modelReadiness.target,
                               strategy: .appleDefault, milliseconds: modelReadiness.durationMs, at: at)
            }
            modelReadiness = TranslationReadiness()
            initialWarmupProgress = ""
            startupWarmupTask?.cancel(); startupWarmupTask = nil
            idleValidationTask?.cancel(); idleValidationTask = nil
            invalidatePending()
            directSession = nil; directKey = ""; availCache.removeAll()
        }
        if activeTranslationSystem != selection.0 { diag.endRun(reason: "modeChanged"); refreshModeDiagnosticEpoch() } // a run never mixes modes
        activeTranslationSystem = selection.0
        modeCoordinator.system = selection.0
        // 2.2.1 (D13): the A/B settings are read here, at the start of a session, so a change never applies mid-run.
        HybridSchedulingPolicy.pinSetting()
        TranslationHotPathAB.pinSettings()
        modeCoordinator.hybridVariant = HybridSchedulingPolicy.buildVariant
        diag.modeActiveSystem = selection.0.rawValue
        diag.modePendingSystem = selection.0.rawValue
        diag.modeMigration = selection.1
        modeAvailability = selection.0 == .legacy ? "Apple default; effective model identity unavailable" : "Checking installed low-latency languages"
        if sourceCode != "auto" {
            if modelReadiness.source.isEmpty { modelReadiness = TranslationReadiness(source: sourceCode, target: targetCode) }
            restoreModelRun(source: sourceCode, target: targetCode, system: selection.0)
        }
        if #unavailable(iOS 26.4), selection.0 != .legacy {
            modeAvailability = selection.0 == .lowLatency ? "Explicit low latency requires iOS 26.4 or later" : "Fast recovery needs iOS 26.4; Apple default fallback remains available"
        }
        if selection.0 != .legacy, sourceCode != "auto" {
            let session = modeSessionID, source = sourceCode, target = targetCode
            Task { [weak self] in
                guard let self else { return }
                guard session == self.modeSessionID else { return }
                if !self.captureAlive { await self.prewarm() }
                else { await self.refreshModePreparation(source: source, target: target, system: selection.0) }
            }
        }
        if selection.0 == .legacy, !captureAlive, directSession == nil {
            Task { [weak self] in await self?.prewarm() }
        }
    }
}
