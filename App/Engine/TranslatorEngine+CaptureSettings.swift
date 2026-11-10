import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    // MARK: Settings → capture extension
    var effectiveRot: Int {
        if frameRotMode == "auto" { return autoRot }
        return ((Int(frameRotMode) ?? 0) / 90) & 3
    }

    var unconsumedSpeculation: Int { ram.specKeys.count }
    var speculationAllowed: Bool {
        if !memoryTestMode.allowsSpeculation { return false }
        if !flag("coolMode", false) { return true }
        return flag("smartCool", true) && ocrMs < 100 && queued == nil
            && !ProcessInfo.processInfo.isLowPowerModeEnabled && !ThermalPerformancePolicy.automaticPressure(for: ProcessInfo.processInfo.thermalState)
    }

    var runtimePolicy: RuntimePolicy {
        RuntimePolicy(coolMode: flag("coolMode", false), diagnosticsEnabled: flag("diagnosticsEnabled", true),
                      detailedRequested: flag("detailedCollection", false))
    }

    /// Run boundaries clear the diagnostic collection and move `diag.started`; mode events are
    /// accepted only for the epoch of their session, so refresh it for the current session.
    func refreshModeDiagnosticEpoch() { modeDiagnosticEpochs[modeSessionID] = diag.started }

    func translationStrategyChanged() {
        pipelineSettingsChanged()
        if #available(iOS 26.0, *) { directSession?.cancel() }
        directSession = nil
        directKey = ""
        availCache.removeAll()
        langStatus.removeAll()
        warmupStatus = "Strategy changed; preparing model"
        Task { await refreshStatus() }
    }

    func powerPolicyChanged() {
        if !speculationAllowed { specQueued = nil }
        if activeTranslationSystem != .legacy {
            if !flag("keepWarm", true) || !runtimePolicy.allowsPrewarming { interruptWarmupForLiveWork() }
            else if !captureAlive { Task { [weak self] in await self?.prewarm() } }
        }
        syncConfig()
    }
}
