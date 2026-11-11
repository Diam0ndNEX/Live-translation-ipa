import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    func restoreModelRun(source: String, target: String, system: TranslationSystem) {
        guard modelReadiness.completedAt == nil else { return }
        let strategies: [RequestedTranslationStrategy] = system == .legacy ? [.appleDefault] : [.lowLatency]
        let previous = strategies.compactMap { strategy -> (at: Date, milliseconds: Double?)? in
            observedModelRuns[modelRunKey(source, target, strategy)]
        }.max(by: { $0.at < $1.at })
        guard let previous else { return }
        modelReadiness.completedAt = previous.at
        modelReadiness.durationMs = previous.milliseconds
        modelReadiness.execution = .idle
        modelReadiness.explanation = "A previous request completed successfully. Current model residency remains unknown."
    }

    var displayedReadiness: TranslationReadiness {
        if activeTranslationSystem != .legacy { return backendActivity.liveReadiness(modelReadiness) }
        var readiness = modelReadiness
        if !captureAlive && readiness.execution == .complete { readiness.execution = .idle }
        return readiness
    }

    var translationConditions: String {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Temperature normal"
        case .fair: thermal = "Device warming"
        case .serious: thermal = "High temperature · speculation reduced"
        case .critical: thermal = "Critical temperature · work restricted"
        @unknown default: thermal = "Temperature unknown"
        }
        return [captureStatus.title, thermal,
                ProcessInfo.processInfo.isLowPowerModeEnabled ? "Low Power Mode on" : "Low Power Mode off",
                activeTranslationSystem == .legacy ? (flag("keepWarm", true) ? "Idle warm-up enabled" : "Idle warm-up off") : (flag("keepWarm", true) ? "Initial warm-up enabled · no periodic samples" : "Initial warm-up off")].joined(separator: " · ")
    }

    struct ModeLayout: Equatable {
        let text: String
        let x: Double
        let y: Double
        let height: Double
        let width: Double?
        init(_ line: OCRLine) {
            text = line.t; x = line.x; y = line.y; height = line.h; width = line.w
        }
    }
    struct ModePlanIdentity: Equatable {
        let session: UUID
        let candidate: String
        let system: TranslationSystem
        let source: String
        let target: String
        let rules: String
        let configuration: Int
        let rotation: Int
        let context: Int
        let orientation: Int?
        let blocks: [String]
        let layout: [ModeLayout]
    }
    struct ModePreparedPlan {
        let rows: [[CaptionTranslationUnit]]
        let keys: [String]
        let inputs: [String]
    }
    struct ModeModelTiming {
        var speculative: Double?
        var confirmed: Double?
    }
    func modeModelKey(_ caption: ModeCaption) -> String {
        caption.session.uuidString + "|" + caption.caption + "|" + String(caption.revision)
    }
    func translationSystemChanged() {
        pendingTranslationSystem = TranslationSystem.migrate(ud).0
        diag.modePendingSystem = pendingTranslationSystem.rawValue
        if !captureAlive { activateTranslationSystem() }
        // Do not keep a stale "installed" result from a different model strategy.
        Task { [weak self] in await self?.loadLanguages() }
    }

    func refreshLegacyScanContext() {
        guard !legacyValidationBusy else { return }
        let installed = langStatus.filter { $0.value == .installed }.keys.sorted().joined(separator: ",")
        let fingerprint = "\(sourceCode)|\(targetCode)|\(memoryRuleToken)|\(memoryHealth?.totalEntries ?? 0)|\(memoryHealth?.legacyUnverified ?? 0)|\(installed)"
        if fingerprint != legacyScanFingerprint {
            legacyScanFingerprint = fingerprint
            legacyValidationCursor = 0
            legacyValidationExhausted = false
            legacyValidationInventory = [:]
            legacyScanReasons = [:]
        }
    }

    func rescanLegacyValidation() {
        guard idleValidationTask == nil else { return }
        legacyValidationCursor = 0
        legacyValidationExhausted = false
        startLegacyValidation()
    }

    var ram: TranslationRAMBank { processMemory.bank(for: memoryTestMode) }
    var allowsPersistentTranslations: Bool { memoryTestMode.allowsPersistentTranslations }
}
