// Screen Translator – App – v0.11.0
import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

enum TranslateMode: String, CaseIterable, Identifiable {
    case movie, game, comic
    var id: String { rawValue }
    var title: String {
        switch self { case .movie: "Movie / subtitles"; case .game: "Game / apps"; case .comic: "Comic / manga" }
    }
}
enum OCRArea: String, CaseIterable, Identifiable {
    case smart, full, bottom, top, middle, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: "Smart (auto)"; case .full: "Full screen"; case .bottom: "Bottom third"
        case .top: "Top half"; case .middle: "Middle band"; case .custom: "Custom…"
        }
    }
    func range(mode: TranslateMode) -> ClosedRange<Double> {   // y: 0 = bottom, 1 = top
        switch self {
        case .smart: return 0...1
        case .full: return 0...1
        case .bottom: return 0...0.33
        case .top: return 0.5...1
        case .middle: return 0.3...0.7
        case .custom:
            let a = (UserDefaults.standard.object(forKey: "customY0") as? Double) ?? 0
            let b = (UserDefaults.standard.object(forKey: "customY1") as? Double) ?? 0.5
            return ExportFormat.normalizedArea(a, b)
        }
    }
}
enum WindowSize: String, CaseIterable, Identifiable {
    case small, normal, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var size: CGSize {
        switch self {
        case .small: CGSize(width: 720, height: 200)
        case .normal: CGSize(width: 720, height: 360)
        case .large: CGSize(width: 720, height: 540)
        }
    }
}
enum SpeedPreset: String, CaseIterable, Identifiable {
    case fast, balanced, sharp, automatic
    var id: String { rawValue }
    var title: String {
        switch self { case .fast: "Fast"; case .balanced: "Balanced"; case .sharp: "Sharp (small text)"; case .automatic: "Auto (adaptive)" }
    }
    var maxEdge: Double {
        switch self { case .fast: 1000; case .balanced: 1400; case .sharp: 2000; case .automatic: 1400 }
    }
    var interval: Double {
        switch self { case .fast: 0.12; case .balanced: 0.22; case .sharp: 0.4; case .automatic: 0.22 }
    }
}

struct LangItem: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

struct HistoryItem: Identifiable, Codable {
    var id = UUID()
    let original: String
    let translated: String
    var date = Date()
    var starred = false
    var sourceLanguage: String? = nil
    var targetLanguage: String? = nil
    var note: String? = nil
}

@MainActor
final class TranslatorEngine: ObservableObject {
    /// Everything a preset remembers.
    static let presetKeys = [
        "source", "target", "mode", "area", "customY0", "customY1", "speed", "stability", "minTextH", "ignoreList",
        "frameRot", "dropNoise", "boost", "skipUnchanged", "subtitleAwareChangeDetection", "preserveRelatedMovieGroups", "cleanOCR", "slang", "speakerDetect", "highlightNames",
        "langLock", "neverTranslate", "sourceFixes", "glossary", "winSize", "theme", "textSize", "pipFont",
        "showOriginal", "autoClear", "clearHold", "minDisplay", "autoOpenPiP", "haptics", "speak", "speechRate",
        "autoCopy", "adaptive", "idleMinutes", "translateAhead", "keepWarm", "remember", "translationSystem", "lowLatencyTranslation", "incrementalBatchRecovery", "adaptiveSpeculation", "protectConfirmedPresentation", "predictiveWarmup",
        "displayPolicy", "pipWeight", "pipAlignment", "pipLineSpacing", "pipPadding", "originalFraction", "pipScale", "speakerAccent", "heartbeatInterval", "hapticStrength", "autoCopyFormat", "interruptSpeech", "ocrConfidence", "ocrCorrection", "idleBackoff", "coolMode", "adaptiveOCR", "adaptiveConfirmation", "subtitleTracking", "selectiveSpeculation", "speculationConfidence", "confirmationDeadline", "smartCool", "steadyCaptions", "languageRecovery", "deduplicateCopies", "continuousRotation", "contextualLanguage"
    ]
    /// App look & behaviour that presets do not touch.
    static let interfaceKeys = ["memoryRAMCapacity", "memorySoftLimit", "persistDiagnosticSessions", "suppressOwnInterface", "directPiPBuffer", "legacyIdleValidationEnabled", "accent", "keepAwake", "saveHistory", "historyRetentionDays", "uiHaptics", "homePresets", "homeTools", "homeQuick", "homeStatus", "homeRecent", "privateSession", "diagIncludeText", "readerFont", "readerSpacing", "readerWidth", "historyCapacity", "diagSamples", "diagnosticsEnabled", "detailedCollection", "freshTranslationTest", "temporaryMemoryTest", "showSessionSpeakers", "homeMetrics", "homeQuickExpanded", "homeDetailsExpanded", "photoOCREdge", "photoAutoTranslate", "sessionLimit", "readerSize", "readerOriginal", "readerAlignment"]
    static var settingKeys: [String] { presetKeys + interfaceKeys }
    static let defaults: [String: Any] = [
        "suppressOwnInterface": true, "memoryRAMCapacity": 3000, "memorySoftLimit": 100000, "persistDiagnosticSessions": false, "directPiPBuffer": false,
        "source": "auto", "target": "en", "mode": "movie", "area": "smart", "customY0": 0.0, "customY1": 0.5,
        "speed": "balanced", "stability": 2, "minTextH": 0.0, "ignoreList": "", "frameRot": "auto",
        "dropNoise": true, "boost": 1, "skipUnchanged": true, "subtitleAwareChangeDetection": false, "preserveRelatedMovieGroups": false, "cleanOCR": true, "slang": true,
        "speakerDetect": true, "highlightNames": true, "langLock": true, "neverTranslate": "", "sourceFixes": "",
        "glossary": "", "winSize": "normal", "theme": "dark", "textSize": "auto", "pipFont": "standard",
        "showOriginal": false, "autoClear": true, "clearHold": 1.0, "minDisplay": 0.0, "autoOpenPiP": true,
        "haptics": false, "speak": false, "speechRate": 0.5, "autoCopy": false, "adaptive": true, "idleMinutes": 0,
        "translateAhead": true, "keepWarm": true, "remember": true, "translationSystem": "legacy", "lowLatencyTranslation": false, "incrementalBatchRecovery": false,
        "adaptiveSpeculation": true, "protectConfirmedPresentation": true, "predictiveWarmup": true,
        "displayPolicy": "immediate", "pipWeight": "bold", "pipAlignment": "left", "pipLineSpacing": 0.0,
        "pipPadding": 24.0, "originalFraction": 0.27, "pipScale": 1.0, "speakerAccent": "blue", "heartbeatInterval": 1.0,
        "readerFont": "rounded", "readerSpacing": 8.0, "readerWidth": "full", "historyCapacity": 500,
        "diagSamples": 600, "homeMetrics": true, "homeQuickExpanded": false,
        "homeDetailsExpanded": false, "hapticStrength": "light", "autoCopyFormat": "translation", "interruptSpeech": true,
        "photoOCREdge": 2400, "photoAutoTranslate": false,
        "adaptiveOCR": true, "adaptiveConfirmation": false, "subtitleTracking": true, "selectiveSpeculation": true,
        "speculationConfidence": 0.85, "confirmationDeadline": 0.6, "smartCool": true, "steadyCaptions": true,
        "languageRecovery": true, "deduplicateCopies": true, "continuousRotation": false, "contextualLanguage": true,
        "coolMode": false, "diagnosticsEnabled": true, "detailedCollection": false, "freshTranslationTest": false, "temporaryMemoryTest": false, "showSessionSpeakers": true,
        "legacyIdleValidationEnabled": false, "privateSession": false, "diagIncludeText": false, "sessionLimit": 0, "readerSize": 28.0,
        "readerOriginal": true, "readerAlignment": false, "ocrConfidence": 0.3, "ocrCorrection": true, "idleBackoff": true
    ]

    // Settings that live in the engine
    @Published var sourceCode: String {
        didSet { guard oldValue != sourceCode else { return }; UserDefaults.standard.set(sourceCode, forKey: "source"); languageSelectionChanged(); directSession = nil; noteRecentPair() }
    }
    @Published var targetCode: String {
        didSet {
            guard oldValue != targetCode else { return }
            UserDefaults.standard.set(targetCode, forKey: "target"); languageSelectionChanged(); directSession = nil; langStatus = [:]; availCache.removeAll()
            noteRecentPair()
            Task { await refreshStatus(); await prewarm() }
        }
    }
    @Published var paused = false { didSet { invalidatePending(); syncConfig(); if !paused { enqueue(latestBlocks) } } }
    @Published var frozen = false
    @Published private(set) var manualMode = false
    @Published private(set) var sessionStarted: Date?
    @Published private(set) var sessionTranslations = 0
    @Published private(set) var sessionCharacters = 0
    @Published private(set) var downloadMessage = ""
    @Published var isTranslating = false
    @Published private(set) var waitingToDisplay = false
    private var presentationTask: Task<Void, Never>?
    private var presentationID = UUID()
    private var undoHistory: [HistoryItem]?
    @Published var toastText: String?
    @Published var detectedLang = "–"
    @Published var recentPairs: [String] = []
    @Published var memoryCount = 0
    // Languages
    @Published var languages: [LangItem] = TranslatorEngine.fallbackLanguages
    @Published var langStatus: [String: LanguageAvailability.Status] = [:]
    @Published var lockedLang: String? = nil { didSet { if diag.enabled { diag.s.lockedLang = lockedLang ?? "–" } } }
    // Output + diagnostics
    @Published var original = ""
    @Published var translated = ""
    @Published var status = "Idle"
    @Published private(set) var warmupStatus = "Waiting for source language"
    @Published private(set) var legacyIdleValidationStatus = "Disabled"
    @Published private(set) var legacyValidatedThisSession = 0
    @Published private(set) var legacyBatchTotal = 0
    @Published private(set) var legacyBatchCompleted = 0
    @Published private(set) var legacyBatchSkipped = 0
    @Published private(set) var legacyBatchWorkers = 0
    @Published private(set) var legacyBatchActive = false
    @Published private(set) var legacyBatchProcessed = 0
    @Published private(set) var legacyEntriesPerMinute = 0.0
    @Published private(set) var legacyEstimatedRemainingMinutes: Double?
    @Published private(set) var legacyValidationElapsedSeconds = 0.0
    @Published private(set) var warmupLastDurationMs: Double?
    @Published var captureAlive = false
    @Published private(set) var captureStatus = CaptureReadiness.State.idle
    private var captureReadiness = CaptureReadiness()
    @Published var frames = 0
    @Published var ocrCount = 0
    @Published var extensionVersion = "–"
    @Published var pipActive = false
    @Published var lastRaw = ""
    @Published var ocrMs: Double = 0
    @Published var translateMs: Double = 0
    @Published var extFreeMB: Double = 0
    @Published var history: [HistoryItem] = [] { didSet { saveHistory() } }
    // Translation session plumbing
    @Published var legacyConfig: TranslationSession.Configuration?
    @Published var downloadConfig: TranslationSession.Configuration?

    let pip = PiPRenderer()
    let server = LoopbackServer()
    let diag = Diagnostics()
    let presets = PresetStore()
    let latency = LatencyMonitor()

    @Published private(set) var activeTranslationSystem = TranslationSystem.legacy
    @Published private(set) var pendingTranslationSystem = TranslationSystem.legacy
    @Published private(set) var modeAvailability = ""
    @Published private(set) var modeWorkActivity: TranslationActivity?
    private var modeActivityCaption: ModeCaption?
    private var modeActivitySelected = false
    private var preparationTicket = UUID()

    @Published private(set) var modelReadiness = TranslationReadiness()
    @Published private(set) var backendActivity = TranslationBackendActivity()
    @Published private(set) var currentRuntimeConditions = ""

    var displayedReadiness: TranslationReadiness {
        activeTranslationSystem == .legacy ? modelReadiness : backendActivity.liveReadiness(modelReadiness)
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
                activeTranslationSystem == .legacy ? (flag("keepWarm", true) ? "Idle warm-up enabled" : "Idle warm-up off") : "Session preparation only · no dummy warm-ups"].joined(separator: " · ")
    }

    var translationActivity: TranslationActivity {
        if activeTranslationSystem != .legacy, let activity = backendActivity.activity { return activity }
        if paused { return TranslationActivity(title: "Translation paused", detail: captureAlive ? "Capture is still connected. Resume to translate." : "Resume translation when you are ready.", phase: .waiting) }
        if activeTranslationSystem != .legacy, let work = modeWorkActivity, work.phase == .working || work.phase == .attention { return work }
        if activeTranslationSystem != .legacy {
            if displayedReadiness.activity.phase == .attention { return displayedReadiness.activity }
            if sourceCode == "auto", modelReadiness.source.isEmpty {
                return TranslationActivity(title: "Waiting for source language", detail: "Read a caption or choose a source language before preparation can run.", phase: .waiting)
            }
            return TranslationBackendActivity.idle(capture: captureAlive,
                ownInterfaceVisible: appInterfaceVisible && flag("suppressOwnInterface", true), modelObserved: modelReadiness.completedAt != nil)
        }
        if activeTranslationSystem == .legacy, isTranslating, modelReadiness.execution != .working {
            return TranslationActivity(title: "Processing current caption", detail: "Checking memory and scheduling complete translation units", phase: .working)
        }
        if modelReadiness.activeSince != nil || modelReadiness.sessions == .complete || modelReadiness.languages == .blocked || modelReadiness.sessions == .blocked || modelReadiness.execution == .blocked {
            return modelReadiness.activity
        }
        if sourceCode == "auto", modelReadiness.source.isEmpty {
            return TranslationActivity(title: "Waiting for source language", detail: "Automatic needs a caption or a recent confirmed language before preparation can run.", phase: .waiting)
        }
        if activeTranslationSystem == .legacy {
            if !flag("keepWarm", true) { return TranslationActivity(title: "Idle warm-up is off", detail: "The model will run when live text requires translation.", phase: .waiting) }
            if !runtimePolicy.allowsPrewarming || ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
                return TranslationActivity(title: "Warm-up deferred by current conditions", detail: "Power, temperature or the current test policy limits idle work. Live text keeps priority.", phase: .waiting)
            }
            if directSession == nil, Date().timeIntervalSince(lastWarm) < 25 {
                return TranslationActivity(title: "Idle warm-up deferred", detail: "The existing warm-up cooldown is active. Live text can still request translation.", phase: .waiting)
            }
        }
        return modelReadiness.activity
    }

    private func refreshModePreparation(source: String, target: String, system: TranslationSystem) async {
        guard system == activeTranslationSystem, system != .legacy else { return }
        let ticket = UUID(), session = modeSessionID
        preparationTicket = ticket
        if modelReadiness.source != source || modelReadiness.target != target { modelReadiness = TranslationReadiness(source: source, target: target) }
        let result = await modeService.prepare(source: source, target: target, system: system) { [weak self] stage in
            guard let self, self.preparationTicket == ticket, self.modeSessionID == session else { return }
            self.modelReadiness.prepare(stage)
        }
        guard preparationTicket == ticket else { return }
        if result == "Preparation superseded" || Task.isCancelled {
            modelReadiness.activeSince = nil
            if modelReadiness.languages == .working { modelReadiness.languages = .pending }
            if modelReadiness.sessions == .working { modelReadiness.sessions = .pending }
        }
        guard !Task.isCancelled, session == modeSessionID, system == activeTranslationSystem,
              target == targetCode, source == (sourceCode == "auto" ? detectedLang : sourceCode), result != "Preparation superseded" else { return }
        modeAvailability = result; warmupStatus = result
    }
    private var captureIdentity = CaptureSessionIdentityGate()
    private var modeSessionID = UUID()
    private var modeDiagnosticEpochs: [UUID: Date] = [:]
    private var modeRevision = 0
    private var modeLastIdentity = ""
    private var modeMemoryOrigins: [String: String] = [:]
    private var modePlans: [String: ([[CaptionTranslationUnit]], Packet, ModeCaption)] = [:]
    private let modeService = ModeTranslationService()
    private lazy var modeCoordinator = ThreeModeCoordinator(
        lookup: { [weak self] caption in await self?.lookupModeMemory(caption) ?? caption.keys.map { _ in nil } },
        translate: { [weak self] caption, indices, strategy, speculative in
            await self?.modeService.translate(caption, indices: indices, strategy: strategy, speculation: speculative)
        },
        cancel: { [weak self] speculative in self?.modeService.cancel(speculation: speculative) },
        selected: { [weak self] caption, output, reason in self?.selectModeResult(caption, output: output, reason: reason) },
        event: { [weak self] caption, reason, ms in self?.noteModeEvent(caption, reason: reason, duration: ms) },
        status: { [weak self] message in
            self?.modeAvailability = message; self?.status = message; self?.isTranslating = false
            self?.modeWorkActivity = TranslationActivity(title: "Translation needs attention", detail: message, phase: .attention)
            self?.modeActivitySelected = true
        })

    func translationSystemChanged() {
        pendingTranslationSystem = TranslationSystem.migrate(ud).0
        diag.modePendingSystem = pendingTranslationSystem.rawValue
        if !captureAlive { activateTranslationSystem() }
    }

    private func activateTranslationSystem() {
        let selection = TranslationSystem.migrate(ud)
        pendingTranslationSystem = selection.0
        if activeTranslationSystem != selection.0 {
            modelReadiness = TranslationReadiness()
            startupWarmupTask?.cancel(); startupWarmupTask = nil
            idleValidationTask?.cancel(); idleValidationTask = nil
            invalidatePending()
            directSession = nil; directKey = ""; availCache.removeAll()
        }
        activeTranslationSystem = selection.0
        modeCoordinator.system = selection.0
        diag.modeActiveSystem = selection.0.rawValue
        diag.modePendingSystem = selection.0.rawValue
        diag.modeMigration = selection.1
        modeAvailability = selection.0 == .legacy ? "Apple default; effective model identity unavailable" : "Checking installed low-latency languages"
        if #unavailable(iOS 26.4), selection.0 != .legacy {
            modeAvailability = selection.0 == .lowLatency ? "Explicit low latency requires iOS 26.4 or later" : "Fast recovery needs iOS 26.4; Apple default fallback remains available"
        }
        if selection.0 != .legacy, sourceCode != "auto" {
            let session = modeSessionID, source = sourceCode, target = targetCode
            Task { [weak self] in
                guard let self else { return }
                guard session == self.modeSessionID else { return }
                await self.refreshModePreparation(source: source, target: target, system: selection.0)
            }
        }
        if selection.0 == .legacy, !captureAlive, directSession == nil {
            Task { [weak self] in await self?.prewarm() }
        }
    }

    private func noteModeEvent(_ caption: ModeCaption, reason: String, duration: Double?) {
        if caption.session == modeSessionID {
            if reason == "confirmed" || reason == "speculation_admitted" {
                modeActivityCaption = caption; modeActivitySelected = false
            }
            if modeActivityCaption?.matches(caption) == true, !modeActivitySelected,
               let activity = TranslationActivity.event(reason) {
                modeWorkActivity = activity
                if reason.hasPrefix("pip_enqueue_") || reason == "display_failed" { modeActivitySelected = true }
            }
            if modeActivityCaption?.matches(caption) == true {
                if modelReadiness.source != caption.source || modelReadiness.target != caption.target { modelReadiness = TranslationReadiness(source: caption.source, target: caption.target) }
                if reason == "speculative_model_submitted" || reason == "confirmed_model_submitted" {
                    modelReadiness.beginExecution(label: "Running translation request")
                } else if reason == "speculative_model_completed" || reason == "confirmed_model_completed" {
                    modelReadiness.finishExecution(success: true, milliseconds: duration)
                } else if reason == "model_batch_failed" {
                    if !modeActivitySelected {
                        modelReadiness.finishExecution(success: false, milliseconds: duration)
                    } else if modelReadiness.execution == .working {
                        modelReadiness.execution = modelReadiness.completedAt == nil ? .pending : .complete
                        modelReadiness.activeSince = nil
                        modelReadiness.explanation = "Unneeded model work ended after the caption result was selected."
                    }
                }
            }
        }
        guard modeDiagnosticEpochs[caption.session] == diag.started else { return }
        if ["speculative_model_submitted", "confirmed_model_submitted", "model_batch_failed", "model_batch_completed", "speculative_model_completed", "confirmed_model_completed"].contains(reason) {
            diag.noteModelState(reason, durationMs: duration, candidate: caption.caption)
        }
        if caption.session == modeSessionID, reason == "hybrid_default_fallback" {
            modeAvailability = "Fast recovery unavailable; using Apple default for this caption"
        }
        diag.noteModeEvent(session: caption.session, caption: caption.caption, revision: caption.revision,
            source: caption.source, target: caption.target,
            fingerprint: SHA256.hash(data: Data(caption.fingerprint.utf8)).map { String(format: "%02x", $0) }.joined(),
            reason: reason, firstOCR: caption.firstOCR, duration: duration, mode: caption.system?.rawValue)
    }

    private func handleModeCaption(_ blocks: [String], packet: Packet) {
        guard let choice = detectSource(blocks.joined(separator: "\n"), record: packet.stable != false),
              choice.language.languageCode != Locale.Language(identifier: targetCode).languageCode else { return }
        let source = choice.language.minimalIdentifier
        let text = blocks.joined(separator: "\n")
        let identity = "\(packet.candidateID ?? "manual")|\(source)|\(targetCode)|\(ConfirmedSourceIdentity.normalize(text))"
        if identity != modeLastIdentity { modeRevision += 1; modeLastIdentity = identity }
        var rows: [[CaptionTranslationUnit]] = []
        var keys: [String] = [], inputs: [String] = []
        for block in blocks {
            let clean = cleanedSource(block, enabled: flag("cleanOCR", true), fixes: pairs("sourceFixes"))
            let parts = preparedSourceUnits(clean, language: choice.language.languageCode?.identifier ?? source,
                slang: flag("slang", true), speakers: flag("speakerDetect", true), protected: list("neverTranslate", lower: false))
            var row: [CaptionTranslationUnit] = []
            for part in parts {
                row.append(CaptionTranslationUnit(label: part.label, sentences: part.sentences,
                    out: part.sentences.map { _ in nil }, tokens: part.tokens))
                for sentence in part.sentences {
                    inputs.append(sentence)
                    keys.append(PipelineSafety.cacheKey(source: source, target: targetCode, text: sentence,
                        protectedWords: part.tokens.map { "\($0.0)=\($0.1)" }, rules: memoryRuleToken))
                }
            }
            rows.append(row)
        }
        guard !inputs.isEmpty else { return }
        let captionID = packet.candidateID ?? "manual-\(modeRevision)"
        let monotonicOrigin = CaptionClockOrigin.monotonic(firstSeen: packet.firstSeenMonotonic,
            wallFirstSeen: packet.firstSeenAt ?? packet.ts ?? Date().timeIntervalSince1970,
            wallNow: Date().timeIntervalSince1970, uptimeNow: ProcessInfo.processInfo.systemUptime)
        let caption = ModeCaption(system: activeTranslationSystem, thermal: ProcessInfo.processInfo.thermalState.rawValue, session: modeSessionID, caption: captionID, revision: modeRevision,
            source: source, target: targetCode, rules: memoryRuleToken, text: text,
            units: inputs, keys: keys, firstOCR: monotonicOrigin)
        let confirmed = packet.stable != false
        if confirmed, let current = modeCoordinator.current, current.matches(caption), current.revision == caption.revision { return }
        if confirmed {
            isTranslating = true
            activeCandidateID = captionID; activeCandidateText = text
            activeCandidateConfirmed = true; activeCandidatePresented = false
            latestBlocks = blocks
            modePlans = [captionID: (rows, packet, caption)]
            detectedLang = source
            noteModeEvent(caption, reason: "confirmed", duration: nil)
        }
        let thermal = ProcessInfo.processInfo.thermalState
        let admitted = speculationAllowed && !ProcessInfo.processInfo.isLowPowerModeEnabled && memoryTestMode.allowsSpeculation && flag("translateAhead", true) &&
            thermal != .serious && thermal != .critical &&
            SpeculationPolicy.credible(lines: packet.lines, threshold: num("speculationConfidence", 0.85))
        modeCoordinator.allowsReuse = memoryTestMode.allowsReuse && !bypassMemory
        if confirmed, activeTranslationSystem != .legacy {
            let session = modeSessionID, system = activeTranslationSystem
            Task { [weak self] in
                guard let self else { return }
                guard session == self.modeSessionID else { return }
                await self.refreshModePreparation(source: source, target: caption.target, system: system)
            }
        }
        modeCoordinator.observe(caption, confirmed: confirmed, speculate: admitted)
    }

    private func lookupModeMemory(_ caption: ModeCaption) async -> [String?] {
        let bank = ram, context = contextRevision
        var output: [String?] = []
        for key in caption.keys {
            guard context == contextRevision, caption.session == modeSessionID else { return caption.keys.map { _ in nil } }
            if let hit = bank.values[key] {
                if modeMemoryOrigins.count >= 3000 { modeMemoryOrigins.removeAll() }
                modeMemoryOrigins[key] = bank.savedKeys.contains(key) ? "saved_ram" : "ram"
                noteModeEvent(caption, reason: bank.savedKeys.contains(key) ? "memory_saved_ram_hit" : "memory_session_hit", duration: nil)
                output.append(hit); continue
            }
            if allowsPersistentTranslations, memoryReady, flag("remember", true), !flag("privateSession", false) {
                let hit = await memoryStore.lookup(key: key)
                guard context == contextRevision else { return caption.keys.map { _ in nil } }
                if hit.value != nil {
                    if modeMemoryOrigins.count >= 3000 { modeMemoryOrigins.removeAll() }
                    modeMemoryOrigins[key] = hit.outcome == "normalized_hit" ? "normalized" : hit.origin
                    let origin = hit.origin == "legacy" ? "memory_legacy_hit" : (hit.origin == "normalized" ? "memory_normalized_hit" : "memory_persistent_hit")
                    noteModeEvent(caption, reason: origin, duration: hit.durationMs)
                }
                output.append(hit.value)
            } else { output.append(nil) }
        }
        return output
    }

    private func selectModeResult(_ caption: ModeCaption, output: ModeOutput, reason: String) {
        guard caption.session == modeSessionID, let (template, packet, expected) = modePlans[caption.caption],
              caption == expected, caption.source == (sourceCode == "auto" ? detectedLang : Locale.Language(identifier: sourceCode).minimalIdentifier),
              caption.target == targetCode, caption.rules == memoryRuleToken else { return }
        var rows = template, index = 0
        for b in rows.indices { for u in rows[b].indices { for i in rows[b][u].out.indices {
            guard index < output.values.count else { return }
            rows[b][u].out[i] = output.values[index]; index += 1
        } } }
        guard let result = CaptionAssembly.complete(rows, glossary: pairs("glossary")), index == output.values.count else { return }
        if diag.enabled {
            diag.s.translations += 1; diag.s.chars += caption.text.count; diag.s.sentences += output.values.count
            for i in output.values.indices {
                let origin = output.origins[i]
                if origin == "speculation" { diag.s.specHits += 1; diag.recordMemory(.speculativeHit, candidate: caption.caption) }
                else if origin == "compatible_memory" || origin == "session_low_latency" {
                    let provenance = origin == "session_low_latency" ? "ram" : (modeMemoryOrigins[caption.keys[i]] ?? "ram")
                    let saved = ["persistent", "legacy", "normalized", "saved_ram"].contains(provenance)
                    if saved { diag.s.savedHits += 1 } else { diag.s.cacheHits += 1 }
                    let outcome: MemoryDiagnosticOutcome = provenance == "persistent" ? .persistentHit : (provenance == "legacy" ? .legacyHit : (provenance == "normalized" ? .normalizedHit : .ramHit))
                    diag.recordMemory(outcome, candidate: caption.caption)
                } else { diag.s.cacheMisses += 1; diag.recordMemory(.miss, candidate: caption.caption) }
                if memoryTestMode == .temporaryMemory {
                    if origin == "speculation" || origin == "compatible_memory" || origin == "session_low_latency" { diag.noteTemporaryReuse() }
                    else { diag.recordMemory(.temporaryMiss, candidate: caption.caption) }
                }
            }
        }
        // LL values never enter the shared preferred namespace, even in RAM.
        if memoryTestMode.allowsReuse {
            for i in output.values.indices where output.strategies[i] == .appleDefault {
                ram.values[caption.keys[i]] = output.values[i]; touchCache(caption.keys[i])
                let confidence = sourceCode == "auto" ? (languageEvidence(caption.text, limit: 5).1.filter {
                    SourceLanguageRouter.sameLanguage($0.key.rawValue, caption.source)
                }.values.max() ?? 0) : 1
                if TranslationUnitPlanning.mayRemember(caption.units[i], confirmed: true),
                   MemoryRetentionPolicy.mayPersist(privateSession: flag("privateSession", false), selectedSource: sourceCode != "auto", confidence: confidence, confirmed: true) {
                    queueMemory(caption.keys[i], output.values[i], independentlyConfirmed: output.origins[i] == "recovery", knownDefault: true)
                }
            }
            trimCache()
        }
        let now = Date()
        let origin = now.timeIntervalSince1970 - max(0, ProcessInfo.processInfo.systemUptime - caption.firstOCR)
        let timing = PresentationTiming(packet: packet, firstSeen: origin, queuedAt: now,
            processingAt: now, processingMs: 0, savedRequests: output.origins.filter { $0 == "compatible_memory" }.count, readyAt: now)
        isTranslating = false
        status = "\(caption.source) → \(caption.target) ✓"
        let enqueued = show(caption.text, result, timing: timing)
        if enqueued {
            noteModeEvent(caption, reason: "pip_enqueue_" + reason,
                duration: max(0, ProcessInfo.processInfo.systemUptime - caption.firstOCR) * 1000)
        } else { noteModeEvent(caption, reason: "display_failed", duration: nil) }
    }

    private var contextRevision = 0
    private var generation = 0
    private var legacyRequestID = UUID()
    private var legacySpeculative = false
    private var latestBlocks: [String] = []
    private var lastHandled = ""
    private var queued: [String]?
    private var queuedTs: Double = 0
    private var currentTs: Double = 0
    private var queuedPacket: Packet?
    private var currentPacket: Packet?
    private var queuedAt = Date()
    private var currentQueuedAt = Date()
    private var processingStarted = Date()
    private var savedRequests = 0
    private var warming = false
    private var legacyValidationBusy = false
    private var idleValidationTask: Task<Void, Never>?
    private var legacyValidationCursor: Int64 = 0
    private var legacyValidationExhausted = false
    private var legacyScanFingerprint = ""
    @Published private(set) var legacyValidationInventory: [String: Int] = [:]
    @Published private(set) var legacyScanReasons: [String: Int] = [:]

    private func refreshLegacyScanContext() {
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

    private var lastIdleValidationAttempt = Date.distantPast
    private var legacyBatchStartedAt = Date.distantPast
    private var legacyAverageRate = 0.0
    private var languageCache: [String: (NLLanguage?, [NLLanguage: Double])] = [:]
    private var drainTask: Task<Void, Never>?
    private var activeCandidateText = ""
    private var activeCandidateID: String?
    private var activeCandidateConfirmed = false
    private var activeCandidatePresented = false
    private var activeCandidateConfirmedAt = Date.distantPast
    private var deferredConfirmedPacket: Packet?
    private var confirmedHandoffDeadlineTask: Task<Void, Never>?
    private var deferredConfirmedReceivedAt = Date.distantPast
    private var specPacket: Packet?
    private var currentSpeculativeText: String?
    private var subtitleRegions = SubtitleRegions()
    private var movieTextFocus = MovieTextFocus()
    private var languageFailures = 0
    private var rulesSnapshot = "", rulesDigest = ""
    private var busy = false
    private var activeQueueOwner = ModelQueueOwner.scheduling
    private var queuedWaitOwner = ModelQueueOwner.scheduling
    private var modelUnitKeysInFlight = Set<String>()
    private var modelContextInFlight: Int?
    private var showing = false
    private var pendingTexts: [String] = []
    private var legacyContinuation: CheckedContinuation<[String]?, Never>?
    private var lastPacketDate = Date.distantPast
    private var lastTextDate = Date()
    private var lastShowDate = Date.distantPast
    private let modelPerf = OSSignposter(subsystem: "com.diam0ndnex.screenlingo", category: "model")
    private var directSession: TranslationSession?
    private let speculativeSessions = SpeculativeSessionOwner<TranslationSession> { session in
        if #available(iOS 26.0, *) { session.cancel() }
    }
    private var directKey = ""
    private var clearTask: Task<Void, Never>?
    private var tickCount = 0
    private var toastToken = 0
    // Translation speed system
    private var specQueued: [String]?
    private var lastSpecText = ""
    private var lastWarm = Date.distantPast
    private var lastUnresolvedWarmupNotice = Date.distantPast
    private var startupWarmupTask: Task<Void, Never>?
    private var warmupSession: TranslationSession?
    private var warmupSuperseded = false
    let memoryStore = TranslationMemoryStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScreenLingo/TranslationMemory", isDirectory: true))
    @Published var memoryHealth: MemoryStoreHealth?
    @Published var memoryPendingWrites = 0
    @Published var memoryFailure: String?
    private var pendingMemory: [String: String] = [:]
    private var pendingDefaultStrategy: [String: String] = [:]
    // A proof is recorded only when the current model generated the result for a
    // confirmed subtitle; speculative/ RAM/ SQLite reuse never counts as proof.
    private var pendingLegacyProof: [String: String] = [:]
    private var memorySaving = false
    private var memoryCoalescingTask: Task<Void, Never>?
    private var appInterfaceVisible = true
    private var memoryMutationInProgress = false
    private var memoryRetryAttempts = 0
    private var storageFullRetryNotBefore = Date.distantPast
    private var memoryPressureCapacity: Int?
    private let processMemory = ProcessTranslationMemory()
    @Published private(set) var memoryTestMode = TranslationTestMode.normal
    @Published private(set) var temporaryMemoryEntries = 0
    private var ram: TranslationRAMBank { processMemory.bank(for: memoryTestMode) }
    private var allowsPersistentTranslations: Bool { memoryTestMode.allowsPersistentTranslations }

    private var memoryReady = false
    private var segmentationCache = SegmentationCache(capacity: 512)
    private var bypassMemory = false
    private var memoryRevision = 0
    private var memoryDirty = false
    private var lastMemorySave = Date.distantPast
    private var availCache: [String: (Date, LanguageAvailability.Status)] = [:]
    private var suppressRecent = false
    private let speech = AVSpeechSynthesizer()
    // Reading-order calibration
    private var orderVote = 0.0
    private var votesSinceChange = 0
    private var trial = 0
    private var autoRot = 0
    private var rotRev = 0
    private var calibrated = false
    // Language lock
    private var languageRouter = SourceLanguageRouter()
    private var languageContext = LanguageContext()
    private var rotationBudget = RotationBudget()
    private var lastConfiguredRotation = "auto"
    private var lastCaptureOrientation: Int?

    // Self-reading protection: what the PiP window currently shows, and where it is on screen
    private let placeholderGrams = TextSim.grams("Waiting for screen text… Listening…")
    private var renderedGrams = TextSim.grams("Waiting for screen text… Listening…")
    private var sourceGrams: Set<String> = []
    private var pipRegion: CGRect?
    private var pipRegionStamp = Date.distantPast

    // MARK: Settings readers
    private var ud: UserDefaults { .standard }
    private func flag(_ k: String, _ d: Bool) -> Bool { (ud.object(forKey: k) as? Bool) ?? d }
    private func num(_ k: String, _ d: Double) -> Double { (ud.object(forKey: k) as? Double) ?? d }
    private func int(_ k: String, _ d: Int) -> Int { (ud.object(forKey: k) as? Int) ?? d }
    private func list(_ k: String, lower: Bool) -> [String] {
        (ud.string(forKey: k) ?? "")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { lower ? $0.trimmingCharacters(in: .whitespaces).lowercased() : $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    private func pairs(_ k: String) -> [(String, String)] {
        (ud.string(forKey: k) ?? "").split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let from = parts[0].trimmingCharacters(in: .whitespaces)
            let to = parts[1].trimmingCharacters(in: .whitespaces)
            return from.isEmpty ? nil : (from, to)
        }
    }
    private var mode: TranslateMode { TranslateMode(rawValue: ud.string(forKey: "mode") ?? "") ?? .movie }
    private var area: OCRArea { OCRArea(rawValue: ud.string(forKey: "area") ?? "") ?? .smart }
    private var windowSize: WindowSize { WindowSize(rawValue: ud.string(forKey: "winSize") ?? "") ?? .normal }
    private var speed: SpeedPreset { SpeedPreset(rawValue: ud.string(forKey: "speed") ?? "") ?? .balanced }
    private var frameRotMode: String { ud.string(forKey: "frameRot") ?? "auto" }
    private var showOriginal: Bool { flag("showOriginal", false) }
    private var pipStyle: PiPStyle {
        var st = PiPStyle.make(theme: PiPTheme(rawValue: ud.string(forKey: "theme") ?? "") ?? .dark,
                               size: PiPTextSize(rawValue: ud.string(forKey: "textSize") ?? "") ?? .auto,
                               font: PiPFont(rawValue: ud.string(forKey: "pipFont") ?? "") ?? .standard)
        st.highlightNames = flag("highlightNames", true)
        return st
    }

    init() {
        let migration = TranslationSystem.migrate(UserDefaults.standard)
        activeTranslationSystem = migration.0; pendingTranslationSystem = migration.0
        diag.modeActiveSystem = migration.0.rawValue; diag.modePendingSystem = migration.0.rawValue
        diag.modeMigration = migration.1
        modeAvailability = migration.0 == .legacy ? "Apple default; effective model identity unavailable" : "Checking installed low-latency languages"
        sourceCode = UserDefaults.standard.string(forKey: "source") ?? "auto"
        targetCode = UserDefaults.standard.string(forKey: "target") ?? "en"
        memoryTestMode = TranslationTestMode(freshRequests: flag("freshTranslationTest", false),
                                           temporaryMemory: flag("temporaryMemoryTest", false))
        diag.translationTestMode = memoryTestMode
        diag.ramEntryCount = { [weak self] in
            guard let self, self.memoryTestMode.allowsReuse else { return 0 }
            return self.ram.values.count
        }
        modeDiagnosticEpochs[modeSessionID] = diag.started
        modeCoordinator.system = activeTranslationSystem
        modeService.hostedDefault = { [weak self] texts, source, target, speculative in
            await self?.translateLegacy(texts, source: source, target: target, speculative: speculative)
        }
        modeService.event = { [weak self] caption, reason, ms in self?.noteModeEvent(caption, reason: reason, duration: ms) }
        modeService.activityChanged = { [weak self] activity in self?.backendActivity = activity }
        modeService.status = { [weak self] message in self?.modeAvailability = message }
        server.onPacket = { [weak self] packet in self?.handle(packet) }
        server.start()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        pip.setSize(windowSize.size)
        pip.onStatus = { [weak self] s in Task { @MainActor in self?.status = s } }
        pip.onActiveChange = { [weak self] a in
            Task { @MainActor in
                self?.pipActive = a
                if a { self?.idleValidationTask?.cancel() }
                self?.diag.log(a ? "Floating window opened" : "Floating window closed")
            }
        }
        if ud.object(forKey: "displayPolicy") == nil {
            ud.set(PresentationSchedule.inferredPolicy(saved: nil, minimum: num("minDisplay", 0)), forKey: "displayPolicy")
        }
        lastConfiguredRotation = frameRotMode
        recentPairs = ud.stringArray(forKey: "recentPairs") ?? []
        loadHistory()
        loadMemory()
        presets.onApplied = { [weak self] in
            self?.reloadSettings()
            if let n = self?.presets.active?.name { self?.diag.log("Preset applied: \(n)") }
        }
        presets.applyStartup()
        diag.log("App started \(AppVersion.full)")
        diag.noteRuntimeState("app_started")
        startupWarmupTask = Task { [weak self] in
            await self?.prewarm()
            self?.startupWarmupTask = nil
        } // Prepare a recent source pair before capture, when possible.
    }

    func captureRequested() {
        captureReadiness.requested(at: ProcessInfo.processInfo.systemUptime)
        publishCaptureStatus()
    }

    private func publishCaptureStatus() {
        if captureStatus != captureReadiness.state { captureStatus = captureReadiness.state }
    }

    private func tick() {
        tickCount += 1
        let conditions = translationConditions
        if currentRuntimeConditions != conditions { currentRuntimeConditions = conditions }
        captureReadiness.tick(at: ProcessInfo.processInfo.systemUptime)
        publishCaptureStatus()
        let alive = Date().timeIntervalSince(lastPacketDate) < 5
        if captureAlive && !alive {
            status = "Capture stopped – iOS may have closed the capture extension. Tap the broadcast icon again (try Speed: Fast)."
            diag.log("Capture stopped")
            diag.noteRuntimeState("heartbeat_timeout")
            if activeTranslationSystem != .legacy { invalidatePending() }
        }
        if captureAlive != alive { captureAlive = alive }
        if alive, let started = sessionStarted, int("sessionLimit", 0) > 0,
           Date().timeIntervalSince(started) >= Double(int("sessionLimit", 0)) * 60, !paused {
            paused = true
            toast("Session timer reached – translation paused")
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
            let fair = ProcessInfo.processInfo.thermalState == .fair
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
            status = "Paused after \(idle) min without text. Turn Pause off to resume."
            diag.log("Auto-paused (idle)")
            diag.noteRuntimeState("idle_auto_pause")
        }
    }

    // MARK: Settings → capture extension
    private var effectiveRot: Int {
        if frameRotMode == "auto" { return autoRot }
        return ((Int(frameRotMode) ?? 0) / 90) & 3
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

    private func languageSelectionChanged() {
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
    }

    var unconsumedSpeculation: Int { ram.specKeys.count }
    private var speculationAllowed: Bool {
        if !memoryTestMode.allowsSpeculation { return false }
        if !flag("coolMode", false) { return true }
        return flag("smartCool", true) && ocrMs < 100 && queued == nil
            && !ProcessInfo.processInfo.isLowPowerModeEnabled && ProcessInfo.processInfo.thermalState == .nominal
    }

    private var runtimePolicy: RuntimePolicy {
        RuntimePolicy(coolMode: flag("coolMode", false), diagnosticsEnabled: flag("diagnosticsEnabled", true),
                      detailedRequested: flag("detailedCollection", false))
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

    func diagnosticsSettingsChanged() {
        diag.collectionChanged()
        if diag.enabled {
            diag.s.lockedLang = lockedLang ?? "–"
            diag.s.rotation = effectiveRot
            diag.s.orderVote = orderVote
            diag.s.calibrated = calibrated && !rotationBudget.exhausted
        }
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

    func pipelineSettingsChanged() {
        diag.noteRuntimeState("capture_config_changed")
        invalidatePending()
        rotRev += 1
        syncConfig()
    }

    func powerPolicyChanged() {
        if !speculationAllowed { specQueued = nil }
        syncConfig()
    }

    /// Sends OCR area, source-language hint, speed and rotation to the extension.
    func syncConfig() {
        let r = area.range(mode: mode)
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
        if diag.enabled { diag.s.rotation = effectiveRot }
        server.send(Config(lang: SourceLanguageRouter.captureLanguage(selected: sourceCode, locked: lockedLang), y0: r.lowerBound, y1: r.upperBound,
                           maxEdge: maxEdge, interval: interval, paused: paused || manualMode,
                           stability: int("stability", 2), rot: effectiveRot, rev: rotRev,
                           boost: int("boost", 1), skipUnchanged: flag("skipUnchanged", true),
                           subtitleAwareChangeDetection: flag("subtitleAwareChangeDetection", false),
                           speculate: speculationAllowed && flag("translateAhead", true), confidence: num("ocrConfidence", 0.3),
                           correction: flag("ocrCorrection", true), idleBackoff: flag("idleBackoff", true),
                           movieMode: mode == .movie,
                           captureDiagnostics: diag.enabled,
                           adaptiveOCR: speed == .automatic || (speed == .balanced && flag("adaptiveOCR", true)),
                           adaptiveConfirmation: flag("adaptiveConfirmation", false), subtitleTracking: flag("subtitleTracking", true),
                           confirmationDeadline: num("confirmationDeadline", 0.6), smartCool: intelligentCool,
                           pressure: flag("adaptive", true) && (intelligentCool || speed == .automatic || (speed == .balanced && flag("adaptiveOCR", true))) && (ProcessInfo.processInfo.thermalState != .nominal || (busy && queued != nil)),
                           selectiveSpeculation: flag("selectiveSpeculation", true), speculationConfidence: num("speculationConfidence", 0.85),
                           detailCeiling: (ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical || (extFreeMB > 0 && extFreeMB < 12)) ? maxEdge : 2400,
                           confirmationBurst: !flag("coolMode", false),
                           appInterfaceVisible: appInterfaceVisible && flag("suppressOwnInterface", true),
                           focusedCaptionOCR: activeTranslationSystem != .legacy && flag("subtitleTracking", true),
                           strictCaptionIdentity: activeTranslationSystem != .legacy))
    }

    // MARK: PiP
    /// Starts the PiP window (retrying while iOS gets ready), then calls `done`.
    func startPiP(then done: @escaping () -> Void = {}) {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? s.setActive(true)
        pip.setSize(windowSize.size)
        attemptPiP(0, done)
    }
    private func attemptPiP(_ n: Int, _ done: @escaping () -> Void) {
        if pip.isActive { done(); return }
        if pip.start() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { done() }
            return
        }
        if n >= 8 {
            status = "PiP couldn't start – stay on the Home tab and tap Start again"
            done(); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.attemptPiP(n + 1, done) }
    }
    func swapLanguages() {
        guard sourceCode != "auto" else { status = "Pick a source language to swap"; return }
        let s = sourceCode
        suppressRecent = true
        sourceCode = targetCode
        targetCode = s
        suppressRecent = false
        noteRecentPair()
    }
    func applyWindowSize() { pip.setSize(windowSize.size) }
    func applyStyle() { pip.style = pipStyle; pip.rerender(showOriginal: showOriginal); pip.configureHeartbeat() }

    /// A shareable picture of one history entry.
    func image(for h: HistoryItem) -> UIImage {
        PiPRenderer.image(original: h.original, translated: h.translated, showOriginal: true,
                          size: CGSize(width: 720, height: 420), style: pipStyle)
    }

    /// Invalidate suspended work before changing language, capture state, or settings.
    private func invalidatePending() {
        if activeTranslationSystem != .legacy {
            modelReadiness.sessions = .pending; modelReadiness.execution = .pending
            modelReadiness.activeSince = nil
            modelReadiness.explanation = "Sessions were invalidated; the next request needs preparation."
        } else if modelReadiness.execution == .working {
            modelReadiness.execution = .pending; modelReadiness.activeSince = nil
            modelReadiness.explanation = "Previous work was interrupted; waiting for the current request."
        }
        modeWorkActivity = nil; modeActivityCaption = nil; modeActivitySelected = false
        preparationTicket = UUID()
        interruptWarmupForLiveWork()
        modeSessionID = UUID(); modeLastIdentity = ""; modePlans.removeAll(); modeMemoryOrigins.removeAll()
        if modeDiagnosticEpochs.count >= 64 { modeDiagnosticEpochs.removeAll() }
        modeDiagnosticEpochs[modeSessionID] = diag.started
        modeCoordinator.reset(); modeService.reset()
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

    func resetSession() {
        sessionStarted = Date(); sessionTranslations = 0; sessionCharacters = 0
        toast("Session restarted")
    }

    func clearOutput() {
        invalidatePending()
        showing = false; original = ""; translated = ""
        renderedGrams = placeholderGrams; sourceGrams = []
        pip.render(original: "", translated: "Listening…", showOriginal: false)
    }

    func deleteHistory(ids: Set<UUID>) {
        undoHistory = history.filter { ids.contains($0.id) }
        history.removeAll { ids.contains($0.id) }
        toast("Deleted. Undo is available in History.")
    }

    func eraseHistory() {
        undoHistory = nil
        history = []
        ud.removeObject(forKey: "historyData")
        ud.removeObject(forKey: "screenlingo.history.v1")
    }

    func undoHistoryDeletion() {
        guard let saved = undoHistory else { toast("Nothing to undo"); return }
        let existing = Set(history.map(\.id))
        history += saved.filter { !existing.contains($0.id) }
        history.sort { $0.date > $1.date }
        undoHistory = nil
        toast("History restored")
    }

    func historyCSV(_ entries: [HistoryItem]) -> String {
        ExportFormat.csv([["date", "source", "target", "original", "translation", "starred", "note"]]
            + entries.map { [$0.date.ISO8601Format(), $0.sourceLanguage ?? "", $0.targetLanguage ?? "",
                             $0.original, $0.translated, $0.starred ? "true" : "false", $0.note ?? ""] })
    }

    func historyJSON(_ entries: [HistoryItem]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    func importHistory(_ data: Data) -> Bool {
        guard data.count < 5_000_000, let entries = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return false }
        var ids = Set(history.map(\.id))
        history += entries.filter { ids.insert($0.id).inserted }
        history = Array(history.sorted { $0.date > $1.date }.prefix(historyCapacity))
        applyHistoryRetention()
        return true
    }

    func timingSettingsChanged() {
        invalidatePending()
        pip.configureHeartbeat()
        syncConfig()
        if !paused, !manualMode { enqueue(latestBlocks) }
    }

    func applyStorageSettings() {
        if history.count > historyCapacity { history = Array(history.prefix(historyCapacity)) }
        if ram.values.count > max(500, min(6000, int("memoryRAMCapacity", 3000))) { trimCache(); memoryDirty = true }
        saveMemory()
    }

    // MARK: Small helpers
    /// Short message that slides in at the top of the screen.
    func toast(_ text: String) {
        toastToken += 1
        let token = toastToken
        toastText = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            if self?.toastToken == token { self?.toastText = nil }
        }
    }

    /// Light tick under the finger (can be turned off in Settings → Interface).
    func tap() { if flag("uiHaptics", true) { UISelectionFeedbackGenerator().selectionChanged() } }

    private func noteRecentPair() {
        guard !suppressRecent else { return }
        let pair = "\(sourceCode)>\(targetCode)"
        var r = recentPairs.filter { $0 != pair }
        r.insert(pair, at: 0)
        recentPairs = Array(r.prefix(5))
        ud.set(recentPairs, forKey: "recentPairs")
    }

    func applyPair(_ pair: String) {
        let p = pair.split(separator: ">", maxSplits: 1).map(String.init)
        guard p.count == 2 else { return }
        suppressRecent = true
        sourceCode = p[0]
        targetCode = p[1]
        suppressRecent = false
        noteRecentPair()
        tap()
    }

    private var historyCapacity: Int { max(100, min(1000, int("historyCapacity", 500))) }

    // MARK: History storage
    private func saveHistory() {
        // Private translations are excluded when history is populated in show().
        // Explicit edits/deletions of existing history must still survive restart.
        guard flag("saveHistory", true) else { return }
        let days = int("historyRetentionDays", 0)
        let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 86400) : Date.distantPast
        let retained = Array(history.filter { $0.starred || $0.date >= cutoff }.prefix(historyCapacity))
        if let d = try? JSONEncoder().encode(retained) { ud.set(d, forKey: "historyData") }
    }
    private func loadHistory() {
        guard flag("saveHistory", true) else { return }
        struct Stored: Decodable {
            let id: UUID?
            let original: String
            let translated: String
            let date: Date
            let starred: Bool?
            let sourceLanguage: String?
            let targetLanguage: String?
            let note: String?
        }
        let data = ud.data(forKey: "historyData") ?? ud.data(forKey: "screenlingo.history.v1")
        guard let data, let records = try? JSONDecoder().decode([Stored].self, from: data) else { return }
        history = records.map { HistoryItem(id: $0.id ?? UUID(), original: $0.original,
                                            translated: $0.translated, date: $0.date, starred: $0.starred ?? false,
                                            sourceLanguage: $0.sourceLanguage, targetLanguage: $0.targetLanguage, note: $0.note) }
        applyHistoryRetention()
    }

    func applyHistoryRetention() {
        let days = int("historyRetentionDays", 0)
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        history.removeAll { !$0.starred && $0.date < cutoff }
    }

    // MARK: Packets from the extension
    private func handle(_ incoming: Packet) {
        let p = incoming
        let now = Date()
        if p.kind == "stopped" {
            guard captureIdentity.stop(p.captureSessionID) else { return }
            captureReadiness.receive(frames: p.frames, session: p.captureSessionID, stopped: true, at: ProcessInfo.processInfo.systemUptime)
            publishCaptureStatus()
            captureAlive = false; lastPacketDate = .distantPast
            invalidatePending()
            diag.noteRuntimeState("heartbeat_timeout")
            return
        }
        let captureAdmission = captureIdentity.admit(p.captureSessionID)
        guard captureAdmission != .rejected else { return }
        captureReadiness.receive(frames: p.frames, session: p.captureSessionID, stopped: false, at: ProcessInfo.processInfo.systemUptime)
        publishCaptureStatus()
        if captureAdmission == .newSession, captureAlive { invalidatePending(); captureAlive = false }
        let wasAlive = captureAlive
        lastPacketDate = now
        if !captureAlive { captureAlive = true }
        if frames != p.frames { frames = p.frames }
        if extensionVersion != p.version { extensionVersion = p.version }
        if let t = p.ocrMs, t != ocrMs { ocrMs = t }
        if let m = p.memFreeMB, m != extFreeMB { extFreeMB = m }
        if p.kind != "ocr" || p.rev == nil || p.rev == rotRev {
            diag.onPacket(p, transport: p.ts.map { max(0, now.timeIntervalSince1970 - $0) * 1000 })
        }

        if !wasAlive {
            activateTranslationSystem()
            interruptWarmupForLiveWork()
            startupWarmupTask?.cancel() // Live capture takes priority over idle prewarming.
            startupWarmupTask = nil
            idleValidationTask?.cancel()
            idleValidationTask = nil
            sessionStarted = now
            sessionTranslations = 0; sessionCharacters = 0
            diag.log("Capture connected (extension v\(p.version))")
            diag.noteRuntimeState("capture_connected")
            lastTextDate = now
            syncConfig()
            // Do not launch a second synthetic model job as capture starts.
            // Startup preparation runs before capture; live text owns first use.
            // Capture just started: make sure the floating window is up too.
            if flag("autoOpenPiP", true), !pip.isActive, UIApplication.shared.applicationState == .active { startPiP() }
        }
        if let orientation = p.orient {
            if let previous = lastCaptureOrientation, previous != orientation, frameRotMode == "auto" {
                rotationSettingChanged()
                diag.log("Capture orientation changed; restarting bounded calibration")
            }
            lastCaptureOrientation = orientation
        }
        if p.kind == "ping" { syncConfig(); return }          // keeps the extension's settings fresh
        handleContent(p, receivedAt: now)
    }

    /// Local handoffs never masquerade as fresh transport packets, extend the
    /// capture heartbeat, or count OCR/confirmation work twice.
    private func handleContent(_ incoming: Packet, receivedAt: Date, replayed: Bool = false) {
        var p = incoming
        let now = Date()
        if replayed {
            guard captureAlive, now.timeIntervalSince(receivedAt) >= 0,
                  now.timeIntervalSince(receivedAt) < 1.2 else {
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                    stage: "stability", reason: "handoff_expired")
                return
            }
            diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                stage: "stability", reason: "handoff_replayed")
        }
        if paused || manualMode || (appInterfaceVisible && flag("suppressOwnInterface", true)) { return }
        if let rev = p.rev, rev != rotRev { return }
        if p.kind == "clear" {
            deferredConfirmedPacket = nil
            confirmedHandoffDeadlineTask?.cancel()
            confirmedHandoffDeadlineTask = nil
            invalidatePending(); latestBlocks = []; handleClear(); return
        }
        guard p.kind == "ocr" else { return }
        if diag.detailedCollection && !replayed {
            diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                                      stage: "frame_arrival", reason: "accepted")
        }
        let candidateTexts = extractTexts(p.lines, count: p.stable != false && !replayed)
        guard !candidateTexts.isEmpty else {
            if diag.detailedCollection {
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                                          stage: "ocr_filtering", reason: "rejected_empty")
            }
            return
        }
        if activeTranslationSystem != .legacy {
            handleModeCaption(candidateTexts, packet: p)
            return
        }
        let candidateText = candidateTexts.map(TextSim.norm).joined(separator: "\n")
        if p.stable != false && !replayed && diag.enabled { diag.s.confirmedCandidatePackets += 1 }
        // Admission must precede generation changes, cancellation and continuity
        // accounting. Rejected fragments never become active confirmed work.
        if SubtitleAcquisitionPolicy.rejectsDisplayedFragment(confirmed: p.stable != false,
            text: candidateTexts.joined(separator: "\n"), displayed: original,
            age: Date().timeIntervalSince(lastShowDate)) {
            if diag.detailedCollection {
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                    stage: "duplicate_detection", reason: "rejected_recent_fragment")
            }
            return
        }
        let equivalentActiveCaption = SubtitleAcquisitionPolicy.isSameUnpresentedCaption(
            activeConfirmed: activeCandidateConfirmed,
            activePresented: activeCandidatePresented,
            previousBlocks: latestBlocks,
            incomingBlocks: candidateTexts)
        let handoffDelay = SubtitlePerformancePolicy.confirmedHandoffDelay(
            age: now.timeIntervalSince(activeCandidateConfirmedAt))
        if !replayed, handoffDelay > 0, flag("protectConfirmedPresentation", true),
           flag("steadyCaptions", true), p.candidateID != nil,
           activeCandidateText != candidateText,
           activeCandidateConfirmed, !activeCandidatePresented,
           p.stable != false, busy || queued != nil || waitingToDisplay,
           !equivalentActiveCaption {
            // One-slot, latest-wins handoff. The existing result gets a bounded
            // completion opportunity; replacement never renews the deadline.
            deferredConfirmedPacket = p
            deferredConfirmedReceivedAt = receivedAt
            // Keep the first deadline when the one-slot replacement changes.
            // Repeated packets cannot renew the grace period indefinitely.
            if confirmedHandoffDeadlineTask == nil {
                confirmedHandoffDeadlineTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(handoffDelay))
                    guard let self, !Task.isCancelled,
                          let pending = self.deferredConfirmedPacket else { return }
                    self.deferredConfirmedPacket = nil
                    self.confirmedHandoffDeadlineTask = nil
                    // Replay once, bypassing handoff protection to prevent a loop.
                    self.handleContent(pending, receivedAt: self.deferredConfirmedReceivedAt, replayed: true)
                }
            }
            if diag.enabled { diag.s.confirmedHandoffDeferred += 1 }
            diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                stage: "stability", reason: "confirmed_handoff_deferred")
            return
        }
        if flag("steadyCaptions", true), let candidate = p.candidateID,
           activeCandidateText != candidateText && !equivalentActiveCaption {
            let confirmed = p.stable != false
            // Tentative OCR jitter must never cancel a previously confirmed subtitle.
            // Its confirmed replacement can still supersede outdated work.
            guard SubtitleAcquisitionPolicy.shouldSupersedeActive(
                activeConfirmed: activeCandidateConfirmed, activePresented: activeCandidatePresented,
                incomingConfirmed: confirmed) else {
                if diag.enabled { diag.s.deferredEarlyCandidates += 1 }
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                    stage: "stability", reason: "deferred_early_candidate")
                return
            }
            if let previous = activeCandidateID {
                diag.trace(previous, stage: "superseded", detail: "Confirmed replacement or early candidate")
                if activeCandidateConfirmed && !activeCandidatePresented && diag.enabled {
                    diag.s.supersededUnpresentedConfirmed += 1
                }
            }
            activeCandidateID = candidate; activeCandidateText = candidateText
            activeCandidateConfirmed = confirmed; activeCandidatePresented = false
            activeCandidateConfirmedAt = confirmed ? now : .distantPast
            deferredConfirmedPacket = nil
            confirmedHandoffDeadlineTask?.cancel()
            confirmedHandoffDeadlineTask = nil
            clearTask?.cancel(); clearTask = nil
            generation += 1
            cancelPresentation()
            queued = nil; specQueued = nil
            let shared = sharedInFlightUnits(candidateTexts)
            if shared == 0 { cancelDrain(preemptSpeculation: confirmed) }
            else if activeQueueOwner == .confirmed { diag.noteSharedModelUnits(shared, confirmed: true) }
        } else if p.stable != false {
            if !activeCandidateConfirmed { activeCandidateConfirmedAt = now }
            activeCandidateConfirmed = true
            if equivalentActiveCaption && activeCandidateText != candidateText {
                diag.notePipelineDecision(candidate: activeCandidateID,
                    frameIndex: p.frames, stage: "duplicate_detection",
                    reason: "preserved_confirmed_work")
            }
        }
        // Overlay-only OCR changes must not supersede the same filtered subtitle.
        if flag("steadyCaptions", true), p.candidateID != nil { p.candidateID = activeCandidateID }
        if p.stable == false, let firstSeen = p.firstSeenAt {
            diag.trace(p.candidateID, stage: "first OCR", detail: "Capture first sighting",
                       at: Date(timeIntervalSince1970: firstSeen), frameIndex: p.frames)
        }
        diag.trace(p.candidateID, stage: p.stable == false ? "seen" : "confirmed", detail: p.confirmationReason ?? "legacy confirmation")
        if let candidate = p.candidateID {
            let first = p.firstSeenAt ?? p.ts ?? Date().timeIntervalSince1970
            diag.registerLegacyModeCaption(session: modeSessionID, caption: candidate,
                source: sourceCode == "auto" ? (detectedLang == "–" ? "auto" : detectedLang) : sourceCode,
                target: targetCode,
                fingerprint: SHA256.hash(data: Data(ConfirmedSourceIdentity.normalize(candidateTexts.joined(separator: "\n")).utf8)).map { String(format: "%02x", $0) }.joined(),
                firstOCR: ProcessInfo.processInfo.systemUptime - max(0, Date().timeIntervalSince1970 - first),
                confirmed: p.stable != false)
        }
        // First, unconfirmed sighting: translate quietly now so the result is ready the moment the text is confirmed.
        if p.stable == false {
            if speculationAllowed && flag("translateAhead", true) {
                if !ram.speculationWindow.allowsOpportunity(enabled: flag("adaptiveSpeculation", true)) {
                    if diag.enabled { diag.s.adaptiveSpeculationSkipped += 1 }
                    if ram.speculationWindow.savedMemoryDominant { diag.noteMemoryAwareSpeculationSkip() }
                    diag.notePipelineDecision(candidate: p.candidateID,
                        frameIndex: p.frames, stage: "stability",
                        reason: "adaptive_speculation_backoff")
                    return
                }
                if flag("selectiveSpeculation", true), !SpeculationPolicy.credible(lines: p.lines, threshold: flag("coolMode", false) ? max(0.95, num("speculationConfidence", 0.85)) : num("speculationConfidence", 0.85)) {
                    if diag.enabled { diag.s.specSkipped += 1 }
                    if diag.detailedCollection {
                        diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                            stage: "stability", reason: "rejected_low_confidence")
                    }
                    return
                }
                specPacket = p
                speculate(candidateTexts)
            }
            return
        }
        ocrCount += 1
        lastRaw = String(p.lines.map(\.t).joined(separator: " ").prefix(160))

        // Is text arriving upside down? Votes only count packets made with the current rotation.
        let revision = rotRev
        updateOrderVote(removeOwnOutput(p.lines))
        guard revision == rotRev else {
            if diag.detailedCollection {
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                                          stage: "rotation", reason: "rejected_revision")
            }
            return
        }

        let texts = candidateTexts
        latestBlocks = texts
        clearTask?.cancel()
        clearTask = nil
        queuedTs = p.firstSeenAt ?? p.ts ?? now.timeIntervalSince1970
        queuedPacket = p
        enqueue(texts.map { String($0.prefix(400)) })
    }

    /// Turns raw OCR lines into the text blocks worth translating (area, rules, own window, blocks, noise…).
    /// `count` is false for early sightings so the statistics are not counted twice.
    private func extractTexts(_ lines: [OCRLine], count: Bool) -> [String] {
        let range = area.range(mode: mode)
        let minH = num("minTextH", 0)
        let ignore = list("ignoreList", lower: true)
        var cand: [OCRLine] = []
        for l in lines {
            if count && diag.enabled { diag.s.linesIn += 1 }
            if !range.contains(l.y) { if count && diag.enabled { diag.s.dropArea += 1 }; continue }
            if l.h < minH { if count && diag.enabled { diag.s.dropSmall += 1 }; continue }
            if ignore.contains(where: { l.t.lowercased().contains($0) }) { if count && diag.enabled { diag.s.dropIgnore += 1 }; continue }
            cand.append(l)
        }
        let n1 = cand.count
        cand = removeOwnOutput(cand)
        if count && diag.enabled { diag.s.dropSelf += n1 - cand.count }
        var allBlocks = makeBlocks(cand)
        if flag("deduplicateCopies", true) {
            var regions = subtitleRegions
            allBlocks = regions.deduplicated(allBlocks)
            if count { subtitleRegions = regions }
        }
        if count && diag.enabled { diag.s.blocksIn += allBlocks.count }
        let blocks = selectBlocks(allBlocks, diagnosticCount: count)
        if count && diag.enabled { diag.s.blocksKept += blocks.count }
        var texts: [String] = []
        for b in blocks {
            let t = blockText(b)
            if TextSim.norm(t).count < 2 { continue }
            if flag("dropNoise", true) && TextIntel.isNoise(t) { if count && diag.enabled { diag.s.dropNoise += 1 }; continue }
            if isTargetLanguage(t) { if count && diag.enabled { diag.s.dropTarget += b.count }; continue }
            texts.append(t)
        }
        return dedupe(texts).map { String($0.prefix(400)) }
    }

    /// Queues a quiet, low-priority translation that only fills the cache.
    private func speculate(_ blocks: [String]) {
        guard speculationAllowed else { return }
        // Confirmed translations own the model. A changing subtitle should not
        // multiply low-priority speculative work while a confirmed job is busy.
        guard !busy, queued == nil else {
            if diag.enabled { diag.s.specSkipped += 1 }
            return
        }
        let thermal = ProcessInfo.processInfo.thermalState
        if ProcessInfo.processInfo.isLowPowerModeEnabled || thermal == .serious || thermal == .critical { return }
        let joined = blocks.joined(separator: "\n")
        guard !frozen, joined != lastHandled, joined != lastSpecText else { return }
        if flag("selectiveSpeculation", true), TextSim.similar(joined, lastSpecText, 0.97) {
            if diag.enabled { diag.s.specSkipped += 1 }
            return
        }
        lastSpecText = joined
        specQueued = blocks
        startDrain()
    }

    // MARK: Reading-order calibration
    /// Reads each text block forwards and backwards; if backwards reads more naturally, the frame is upside down.
    private func updateOrderVote(_ lines: [OCRLine]) {
        guard !calibrated || flag("continuousRotation", false) else { return }
        var diff = 0.0
        for b in makeBlocks(lines) where b.count >= 2 {
            let fwd = readingOrder(b).map(\.t)
            diff += TextIntel.orderScore(fwd) - TextIntel.orderScore(Array(fwd.reversed()))
        }
        guard diff != 0 else { return }
        orderVote = max(-30, min(30, orderVote * 0.8 + diff))
        votesSinceChange += 1
        if diag.enabled { diag.s.orderVote = orderVote }
        guard frameRotMode == "auto" else { return }
        if RotationBudget.sufficientEvidence(vote: orderVote, samples: votesSinceChange) {
            if calibrated && flag("continuousRotation", false) { rotationBudget.reset() }
            guard let nextRotation = rotationBudget.next() else { return }
            autoRot = nextRotation
            rotRev += 1
            invalidatePending()
            orderVote = 0; votesSinceChange = 0; calibrated = false
            if diag.enabled { diag.s.calibrated = false }
            if rotationBudget.exhausted {
                calibrated = true
                if diag.enabled { diag.s.calibrated = false }
                diag.log("Rotation probes exhausted; holding capture orientation until device orientation or settings change")
            } else { diag.log("Reading order looks reversed → trying rotation \(autoRot * 90)°") }
            syncConfig()
        } else if orderVote > 4 && !calibrated {
            calibrated = true
            if diag.enabled { diag.s.calibrated = true }
            diag.log("Reading order OK at rotation \(autoRot * 90)°")
        }
    }

    // MARK: Text blocks
    /// Lines in reading order: top to bottom, left to right within a row.
    private func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        OCRGrouping.readingOrder(lines)
    }

    private func makeBlocks(_ lines: [OCRLine]) -> [[OCRLine]] {
        OCRGrouping.makeBlocks(lines, movie: mode == .movie)
    }

    private func blockHeight(_ b: [OCRLine]) -> Double {
        let h = b.map(\.h).sorted()
        return h.isEmpty ? 0 : h[h.count / 2]
    }
    private func blockWeight(_ b: [OCRLine]) -> Double {
        blockHeight(b) * Double(b.reduce(0) { $0 + $1.t.count }).squareRoot()
    }

    /// Movie mode keeps the dominant block(s); other modes keep everything that isn't tiny.
    private func selectBlocks(_ blocks: [[OCRLine]], diagnosticCount: Bool) -> [[OCRLine]] {
        guard !blocks.isEmpty else { return [] }
        let maxH = blocks.map { blockHeight($0) }.max() ?? 0
        var kept = blocks
        if mode == .movie {
            let beforeHeightFilter = kept.count
            // Tiny dialogue must not be excluded because a persistent label uses a larger font.
            kept = blocks.filter { blockHeight($0) >= max(0.006, maxH * 0.20) }
            if kept.isEmpty { kept = blocks }
            // Aligned visible lyrics are one reading group, even with separate OCR boxes.
            let sorted = kept.sorted { ($0.first?.y ?? 0) > ($1.first?.y ?? 0) }
            var groups: [[[OCRLine]]] = []
            for block in sorted {
                let x = block.map(\.x).reduce(0, +) / Double(block.count)
                let y = block.map(\.y).reduce(0, +) / Double(block.count)
                if let i = groups.firstIndex(where: { group in
                    guard let previous = group.last else { return false }
                    let px = previous.map(\.x).reduce(0, +) / Double(previous.count)
                    let py = previous.map(\.y).reduce(0, +) / Double(previous.count)
                    return abs(px - x) <= 0.12 && abs(py - y) <= max(0.12, blockHeight(block) * 4.2)
                }) { groups[i].append(block) } else { groups.append([block]) }
            }
            let summaries = groups.map { group -> MovieTextGroup in
                let lines = group.flatMap { $0 }
                let x = lines.reduce(0.0) { $0 + $1.x } / Double(max(1, lines.count))
                let y = lines.reduce(0.0) { $0 + $1.y } / Double(max(1, lines.count))
                return MovieTextGroup(text: lines.map(\.t).joined(separator: " "), x: x, y: y,
                    weight: group.reduce(0.0) { $0 + blockWeight($1) })
            }
            // A label becomes background only after repeated, spatially stable OCR.
            // A lone held subtitle/lyrics group remains eligible for translation.
            let strongest = summaries.indices.max(by: { summaries[$0].weight < summaries[$1].weight })
            let chosen = movieTextFocus.preferredIndex(in: summaries, at: Date().timeIntervalSince1970)
            diag.noteMovieSelection(groups: groups.count,
                filteredSmall: beforeHeightFilter - kept.count,
                temporalOverride: chosen != nil && chosen != strongest,
                confirmed: diagnosticCount)
            if let chosen {
                kept = groups[chosen]
                if flag("preserveRelatedMovieGroups", false) {
                    // Opt-in lyrics mode: keep only nearby aligned secondary groups.
                    let focus = summaries[chosen]
                    for index in groups.indices where index != chosen {
                        let other = summaries[index]
                        let aligned = abs(focus.x - other.x) <= 0.10
                        let close = abs(focus.y - other.y) <= 0.24
                        let substantial = other.weight >= focus.weight * 0.26
                        if aligned && close && substantial { kept.append(contentsOf: groups[index]) }
                    }
                }
            } else { kept = [] }
        } else if area == .smart {
            kept = blocks.filter { blockHeight($0) >= maxH * 0.4 }
        }
        kept = Array(kept.sorted { blockWeight($0) > blockWeight($1) }.prefix(6))
        func top(_ b: [OCRLine]) -> Double { b.map { $0.y + $0.h / 2 }.max() ?? 0 }
        func left(_ b: [OCRLine]) -> Double { b.map { $0.x - ($0.w ?? 0) / 2 }.min() ?? 0 }
        return kept.sorted { a, b in
            let ra = Int((1 - top(a)) * 14), rb = Int((1 - top(b)) * 14)
            return ra != rb ? ra < rb : left(a) < left(b)
        }
    }

    private func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xFF00...0xFFEF).contains(v)
    }

    /// One block's lines joined into running text ("p-" + "pq" → "p-pq").
    private func blockText(_ lines: [OCRLine]) -> String {
        var out = ""
        for l in readingOrder(lines) {
            let t = l.t.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if out.isEmpty { out = t }
            else if out.hasSuffix("-") { out += t }
            else if let last = out.last, isCJK(last) { out += t }
            else { out += " " + t }
        }
        return out
    }

    private func languageEvidence(_ text: String, limit: Int) -> (NLLanguage?, [NLLanguage: Double]) {
        let key = "\(limit)|\(text)"
        if let hit = languageCache[key] { return hit }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let evidence = (recognizer.dominantLanguage, recognizer.languageHypotheses(withMaximum: limit))
        if languageCache.count >= 128 { languageCache.removeAll(keepingCapacity: true) }
        languageCache[key] = evidence
        return evidence
    }

    /// Removes lines that are the floating window's own text, and learns where that window sits.
    private func removeOwnOutput(_ lines: [OCRLine]) -> [OCRLine] {
        var mine: [OCRLine] = []
        var rest: [OCRLine] = []
        for l in lines {
            if TextSim.norm(l.t).count >= 3 {
                let inOutput = TextSim.containment(of: l.t, in: renderedGrams)
                let inSource = TextSim.containment(of: l.t, in: sourceGrams)
                if inOutput >= 0.85 && inOutput > inSource + 0.1 { mine.append(l); continue }
            }
            rest.append(l)
        }
        if !mine.isEmpty {
            var r = CGRect.null
            for l in mine {
                let w = l.w ?? 0.25
                r = r.union(CGRect(x: l.x - w / 2, y: l.y - l.h / 2, width: w, height: l.h))
            }
            // The original text can sit above the translation, so reach further up when it is shown
            pipRegion = r.insetBy(dx: -0.04, dy: showOriginal ? -0.18 : -0.06)
            pipRegionStamp = Date()
            if let g = pipRegion {
                if diag.enabled { diag.s.pipRegion = "x \(Int(g.minX * 100))–\(Int(g.maxX * 100))%, y \(Int(g.minY * 100))–\(Int(g.maxY * 100))%" }
            }
        }
        if let reg = pipRegion, Date().timeIntervalSince(pipRegionStamp) < 15 {
            rest.removeAll { reg.contains(CGPoint(x: $0.x, y: $0.y)) }
        }
        return rest
    }

    private func dedupe(_ lines: [String]) -> [String] {
        var out: [String] = []
        for l in lines where !out.contains(where: { TextSim.similar($0, l, 0.9) }) { out.append(l) }
        return out
    }

    private func enqueue(_ blocks: [String]) {
        if activeTranslationSystem != .legacy {
            guard !blocks.isEmpty else { return }
            var packet = Packet(kind: "ocr", version: AppVersion.full, frames: frames, lines: [])
            packet.candidateID = "manual-\(UUID().uuidString)"; packet.stable = true
            packet.firstSeenAt = Date().timeIntervalSince1970
            handleModeCaption(blocks, packet: packet)
            return
        }
        let joined = blocks.joined(separator: "\n")
        guard !blocks.isEmpty, joined != lastHandled else { return }
        if PipelineSafety.isDuplicate(blocks, previous: lastHandled.components(separatedBy: "\n")) { return }
        generation += 1
        cancelPresentation()
        lastHandled = joined
        if queued != nil { diag.noteQueueReplacement() }
        queued = blocks
        queuedAt = Date()
        queuedWaitOwner = busy ? activeQueueOwner : .scheduling
        if presentQueuedFromRAMIfComplete() { return }
        if SubtitlePerformancePolicy.preemptSpeculation(activeText: currentSpeculativeText, confirmedText: joined) {
            // Different input cannot supply an exact whole-caption reuse result.
            // Cancellation unwinds the single drain before confirmed work starts.
            let shared = sharedInFlightUnits(blocks)
            if shared == 0 {
                if diag.enabled { diag.s.specPreemptionRequested += 1 }
                cancelDrain(preemptSpeculation: true)
            }
            else { diag.noteSharedModelUnits(shared) }
        } else if currentSpeculativeText == joined {
            if diag.enabled { diag.s.specMatchingConfirmation += 1 }
        }
        startDrain()
    }

    @discardableResult
    private func presentQueuedFromRAMIfComplete() -> Bool {
        guard let blocks = queued else { return false }
        let joined = blocks.joined(separator: "\n")
        // A complete exact RAM result needs no model lane. Never bypass OCR
        // confirmation, generation checks or the presentation policy.
        let cacheProbeStarted = Date()
        if busy, !bypassMemory, memoryTestMode.allowsReuse,
           let key = ExactCaptionIdentity.key(blocks: blocks, source: sourceCode,
                                              target: targetCode, rules: memoryRuleToken),
           let ready = cachedCaption(blocks, identity: key) {
            queued = nil
            if diag.enabled { diag.s.translations += 1; diag.s.chars += blocks.joined().count }
            translateMs = Date().timeIntervalSince(cacheProbeStarted) * 1000
            languageFailures = 0
            diag.recordQueueWait(owner: queuedWaitOwner,
                durationMs: max(0, cacheProbeStarted.timeIntervalSince(queuedAt) * 1000),
                candidate: queuedPacket?.candidateID)
            status = "\(sourceCode) → \(targetCode) ✓"
            if memoryTestMode == .temporaryMemory { diag.noteTemporaryReuse(count: ready.sentences) }
            let now = Date()
            let timing = PresentationTiming(packet: queuedPacket, firstSeen: queuedTs,
                queuedAt: queuedAt, processingAt: cacheProbeStarted, processingMs: translateMs,
                savedRequests: 0, readyAt: now)
            diag.recordTranslate(ms: translateMs, sentences: ready.sentences, from: sourceCode,
                                 to: targetCode, preview: ready.translated)
            diag.trace(queuedPacket?.candidateID, stage: "ready", detail: "Complete exact RAM caption")
            schedulePresentation(joined, ready.translated, generation: generation,
                                 context: contextRevision, timing: timing)
            return true
        }
        return false
    }

    private func handleClear() {
        guard !frozen, flag("autoClear", true), showing, clearTask == nil else { return }
        let hold = num("clearHold", 1.0)
        if hold <= 0 { performClear(); return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled else { return }
            self?.performClear()
        }
    }

    private func performClear() {
        clearTask = nil
        guard showing, !frozen else { return }
        diag.event(.translation, "Cleared – the text ended")
        showing = false
        lastHandled = ""
        original = ""
        translated = ""
        renderedGrams = placeholderGrams
        pip.render(original: "", translated: "Listening…", showOriginal: false)
    }

    /// Only strong, long Automatic-mode evidence may discard target-language background text.
    private func isTargetLanguage(_ text: String) -> Bool {
        guard sourceCode == "auto" else { return false }
        let evidence = languageEvidence(text, limit: 5).1
        return SourceLanguageRouter.shouldDropTarget(selected: sourceCode, target: targetCode,
            hypotheses: Dictionary(uniqueKeysWithValues: evidence.map { ($0.key.rawValue, $0.value) }),
            letters: text.filter(\.isLetter).count)
    }

    /// Swift Task cancellation alone may leave Apple's model request running.
    /// Only the disposable speculative session receives explicit cancellation;
    /// confirmed work retains its own warm session and the drain still awaits unwind.
    private func cancelDrain(preemptSpeculation: Bool) {
        drainTask?.cancel()
        if preemptSpeculation, speculativeSessions.cancelActive() {
            diag.noteModelState("speculative_stop_requested")
        }
    }

    private func startDrain() {
        guard !busy, drainTask == nil, queued != nil || specQueued != nil else { return }
        interruptWarmupForLiveWork()
        drainTask = Task(priority: .userInitiated) { await drain() }
    }

    /// Warm-up owns a disposable session, so cancelling it cannot invalidate
    /// the retained live session. Task cancellation alone may leave model work
    /// running; explicitly ask the iOS 26 session to stop synthetic work.
    private func interruptWarmupForLiveWork() {
        guard let session = warmupSession else { return }
        warmupSuperseded = true
        if #available(iOS 26.0, *) { session.cancel() }
    }

    private func drain() async {
        guard !busy else { return }
        busy = true
        defer {
            busy = false
            activeQueueOwner = .scheduling
            drainTask = nil
            replayDeferredConfirmedIfPossible()
            startDrain()
        }
        while queued != nil || specQueued != nil {
            guard !Task.isCancelled else { return }
            if deferredConfirmedPacket != nil, activeCandidatePresented, !waitingToDisplay { return }
            if let b = queued {
                queued = nil
                currentTs = queuedTs; currentPacket = queuedPacket; currentQueuedAt = queuedAt
                diag.recordQueueWait(owner: queuedWaitOwner,
                    durationMs: max(0, Date().timeIntervalSince(queuedAt) * 1000),
                    candidate: queuedPacket?.candidateID)
                activeQueueOwner = .confirmed
                await process(b, display: true)
            } else if let sp = specQueued {
                specQueued = nil
                currentPacket = specPacket
                if speculationAllowed {
                    activeQueueOwner = .speculative
                    currentSpeculativeText = sp.joined(separator: "\n")
                    await process(sp, display: false)
                    currentSpeculativeText = nil
                }
            }
        }
    }

    /// A one-slot bounded handoff; if a delayed presentation is pending, its
    /// display callback replays the newest confirmed candidate.
    private func replayDeferredConfirmedIfPossible() {
        guard !busy, !waitingToDisplay, let packet = deferredConfirmedPacket else { return }
        deferredConfirmedPacket = nil
        confirmedHandoffDeadlineTask?.cancel()
        confirmedHandoffDeadlineTask = nil
        guard !paused, !manualMode, captureAlive else { return }
        handleContent(packet, receivedAt: deferredConfirmedReceivedAt, replayed: true)
    }

    // MARK: Translation
    private var memoryRuleToken: String {
        let keys = ["cleanOCR", "slang", "speakerDetect", "neverTranslate", "sourceFixes", "glossary"]
        var snapshot = keys.map { key in "\(key)=\(ud.object(forKey: key) ?? Self.defaults[key] ?? "")" }.joined(separator: "\u{1F}")
        // Preserve the original v4 memory rule digest when the optional model
        // strategy is OFF. Only isolate outputs when a genuinely distinct
        // low-latency model was selected on a supported OS.
        if #available(iOS 26.4, *) {
            snapshot = TranslationModelMemoryPolicy.rulesContext(
                base: snapshot, lowLatency: false)
        }
        if snapshot != rulesSnapshot {
            rulesSnapshot = snapshot
            rulesDigest = SHA256.hash(data: Data(snapshot.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return rulesDigest
    }

    private func detectSource(_ text: String, record: Bool = true) -> (language: Locale.Language, origin: SourceLanguageOrigin)? {
        if sourceCode != "auto" { return (Locale.Language(identifier: sourceCode), .selected) }
        var evidence = languageEvidence(text, limit: 5).1
        var usedContext = false
        let now = Date().timeIntervalSince1970
        let rawHypotheses = Dictionary(uniqueKeysWithValues: evidence.map { ($0.key.rawValue, $0.value) })
        if flag("contextualLanguage", true), languageContext.mayAssist(rawHypotheses, now: now) {
            let combined = languageEvidence(languageContext.text + " " + text, limit: 5).1
            if let best = combined.max(by: { $0.value < $1.value }), best.value >= 0.8,
               SourceLanguageRouter.sameLanguage(best.key.rawValue, languageContext.code) {
                evidence = combined; usedContext = true
            }
        }
        let previous = languageRouter.locked
        let choice = languageRouter.resolve(
            hypotheses: Dictionary(uniqueKeysWithValues: evidence.map { ($0.key.rawValue, $0.value) }),
            target: targetCode, letters: text.filter(\.isLetter).count,
            useLock: flag("langLock", true), record: record)
        if record, previous != languageRouter.locked {
            lockedLang = languageRouter.locked
            diag.log(lockedLang.map { "Language locked to \($0)" } ?? "Language lock released")
        }
        guard let choice else { return nil }
        if record && diag.enabled {
            diag.s.languageConfidence = evidence.filter { SourceLanguageRouter.sameLanguage($0.key.rawValue, choice.code) }.values.max() ?? 0
            diag.s.languageContextUsed = usedContext
        }
        if record, !SourceLanguageRouter.sameLanguage(choice.code, targetCode) {
            let currentConfidence = languageEvidence(text, limit: 5).1.filter { SourceLanguageRouter.sameLanguage($0.key.rawValue, choice.code) }.values.max() ?? 0
            languageContext.record(text, code: choice.code, confidence: currentConfidence, now: now)
        }
        return (Locale.Language(identifier: choice.code), choice.origin)
    }

    private func pairStatus(_ src: Locale.Language, _ target: Locale.Language) async -> LanguageAvailability.Status {
        if target.minimalIdentifier == Locale.Language(identifier: targetCode).minimalIdentifier,
           src.minimalIdentifier == Locale.Language(identifier: sourceCode).minimalIdentifier,
           let s = langStatus[sourceCode] { return s }
        let k = "\(src.minimalIdentifier)>\(target.minimalIdentifier)|\((activeTranslationSystem == .lowLatency) ? "low" : "default")"
        if let c = availCache[k], Date().timeIntervalSince(c.0) < 60 { return c.1 }
        let availability: LanguageAvailability
        if #available(iOS 26.4, *), (activeTranslationSystem == .lowLatency) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }
        let s = await availability.status(from: src, to: target)
        availCache[k] = (Date(), s)
        return s
    }

    /// Splits a block into sentences so each is translated on its own (better quality, cacheable).
    private func splitSentences(_ text: String) -> [String] {
        guard text.count > 24 else { return [text] }
        // Include effective language context: an OCR language correction must not
        // borrow the segmentation calculated for a different configuration.
        let key = "seg\(TranslationUnitPlanning.version)|\(sourceCode)|\(detectedLang)|\(targetCode)|\(text)"
        let started = ProcessInfo.processInfo.systemUptime
        if let cached = segmentationCache.lookup(key) {
            diag.noteSegmentation(candidate: activeCandidateID, reused: true,
                durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000)
            return cached
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var units: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.isEmpty { return true }
            if sentence.count < 4, let previous = units.popLast() {
                units.append(previous + " " + sentence)
            } else {
                units.append(sentence)
            }
            return true
        }
        let result = TranslationUnitPlanning.units(source: text, candidates: units.isEmpty ? [text] : units)
        segmentationCache.insert(key, units: result)
        diag.noteSegmentation(candidate: activeCandidateID, reused: false,
            durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        return result
    }

    /// Keep a completed unit, never a partial sentence. The old caption is not
    /// presented or persisted; a queued replacement must assemble every unit.
    private func retainCompletedModelUnit(key: String, value: String,
        context: Int, rules: String, destination: String, mode: TranslationTestMode,
        bank: TranslationRAMBank, confirmed: Bool, speculativeID: UInt64?, epoch: Date) {
        guard context == contextRevision, mode == memoryTestMode, bank === ram,
              mode.allowsReuse, !bypassMemory, rules == memoryRuleToken,
              destination == targetCode,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bank.values[key] == nil else { return }
        bank.values[key] = value
        bank.savedKeys.remove(key)
        if !confirmed {
            if bank.specKeys.insert(key).inserted, diag.started == epoch { diag.noteSpeculativeUnit("retained") }
            if let speculativeID { bank.speculativeOrigins[key] = speculativeID }
        }
        touchCache(key)
        trimCache()
        if diag.started == epoch {
            if confirmed { diag.noteCompletedWorkRecovery(1) }
            else if diag.enabled { diag.s.specRetainedUnits += 1 }
        }
        // A needed result may arrive before unrelated units in the old batch.
        // This uses the existing complete-caption and presentation safeguards.
        presentQueuedFromRAMIfComplete()
    }

    private struct PreparedSourceUnit {
        let label: String?
        let sentences: [String]
        let tokens: [(String, String)]
    }

    private func cleanedSource(_ raw: String, enabled: Bool, fixes: [(String, String)]) -> String {
        var text = enabled ? TextIntel.cleanOCR(raw) : raw
        for (from, to) in fixes { text = text.replacingOccurrences(of: from, with: to, options: [.caseInsensitive]) }
        return text
    }

    /// Shared by real processing and the in-flight exact-key overlap check.
    private func preparedSourceUnits(_ text: String, language: String, slang: Bool,
                                     speakers: Bool, protected: [String]) -> [PreparedSourceUnit] {
        let expanded = slang ? TextIntel.expandSlang(text, lang: language) : text
        let parts = speakers ? TextIntel.splitDialogue(expanded) : [(label: String?.none, text: expanded)]
        return parts.map { part in
            let tokens = TextIntel.protect(part.text, words: protected)
            return PreparedSourceUnit(label: part.label, sentences: splitSentences(tokens.text), tokens: tokens.tokens)
        }
    }

    /// Synchronous and RAM-only: safe while the model lane is awaiting unrelated work.
    /// Probe every current unit before consuming provenance or confirming any result.
    private func cachedCaption(_ blocks: [String], identity: String) -> ExactCaptionResult? {
        if let ready = ram.captions[identity] {
            diag.noteExactCaptionReuse()
            return ready
        }
        guard sourceCode != "auto", memoryTestMode.allowsReuse, !bypassMemory else { return nil }
        let source = Locale.Language(identifier: sourceCode)
        guard source.languageCode != Locale.Language(identifier: targetCode).languageCode else { return nil }
        let id = source.minimalIdentifier
        let rules = memoryRuleToken
        let never = list("neverTranslate", lower: false)
        let fixes = pairs("sourceFixes")
        var units: [[CaptionTranslationUnit]] = []
        var hits: [(key: String, text: String, value: String, lookupMs: Double)] = []
        for raw in blocks {
            let text = cleanedSource(raw, enabled: flag("cleanOCR", true), fixes: fixes)
            var row: [CaptionTranslationUnit] = []
            for part in preparedSourceUnits(text, language: source.languageCode?.identifier ?? id,
                    slang: flag("slang", true), speakers: flag("speakerDetect", true), protected: never) {
                var values: [String?] = []
                for sentence in part.sentences {
                    let key = PipelineSafety.cacheKey(source: id, target: targetCode, text: sentence,
                        protectedWords: part.tokens.map { "\($0.0)=\($0.1)" }, rules: rules)
                    let lookupStarted = ProcessInfo.processInfo.systemUptime
                    guard let value = ram.values[key],
                          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    hits.append((key, sentence, value,
                        (ProcessInfo.processInfo.systemUptime - lookupStarted) * 1000))
                    values.append(value)
                }
                row.append(CaptionTranslationUnit(label: part.label, sentences: part.sentences,
                                                  out: values, tokens: part.tokens))
            }
            units.append(row)
        }
        guard let result = CaptionAssembly.complete(units, glossary: pairs("glossary")) else { return nil }
        // No suspension above: mode, rules, bank and candidate cannot change mid-probe.
        let mayPersist = allowsPersistentTranslations && !flag("privateSession", false)
        for hit in hits {
            touchCache(hit.key)
            let speculative = ram.specKeys.remove(hit.key) != nil
            let saved = ram.savedKeys.remove(hit.key) != nil
            ram.speculationWindow.recordConfirmedOutcome(saved: saved && !speculative)
            if speculative {
                diag.noteSpeculativeUnit("reused")
                if let origin = ram.speculativeOrigins.removeValue(forKey: hit.key) { ram.speculationWindow.reuse(origin) }
            }
            diag.recordMemory(speculative ? .speculativeHit : .ramHit,
                durationMs: hit.lookupMs,
                candidate: queuedPacket?.candidateID, frameIndex: queuedPacket?.frames, unitKey: hit.key)
            if mayPersist, TranslationUnitPlanning.mayRemember(hit.text, confirmed: true),
               ram.confirmedKeys.insert(hit.key).inserted, !saved {
                queueMemory(hit.key, hit.value, independentlyConfirmed: speculative)
            }
            if diag.enabled {
                if speculative { diag.s.specHits += 1 }
                else if saved { diag.s.savedHits += 1 }
                else { diag.s.cacheHits += 1 }
            }
        }
        for row in units { for unit in row { if let label = unit.label { diag.learn(label) } } }
        diag.recordSourceLanguage(id, origin: .selected)
        if diag.enabled { diag.s.sentences += hits.count }
        diag.noteRAMCaptionBypass()
        let ready = ExactCaptionResult(translated: result, sentences: hits.count)
        ram.retainCaption(key: identity, result: ready)
        return ready
    }

    private func sharedInFlightUnits(_ blocks: [String]) -> Int {
        guard activeQueueOwner != .scheduling, drainTask?.isCancelled == false,
              sourceCode != "auto", memoryTestMode.allowsReuse, !bypassMemory,
              !modelUnitKeysInFlight.isEmpty else { return 0 }
        let source = Locale.Language(identifier: sourceCode)
        let id = source.minimalIdentifier
        let rules = memoryRuleToken
        let never = list("neverTranslate", lower: false)
        var keys = Set<String>()
        for raw in blocks {
            let text = cleanedSource(raw, enabled: flag("cleanOCR", true), fixes: pairs("sourceFixes"))
            for part in preparedSourceUnits(text, language: source.languageCode?.identifier ?? id,
                    slang: flag("slang", true), speakers: flag("speakerDetect", true), protected: never) {
                for sentence in part.sentences {
                    keys.insert(PipelineSafety.cacheKey(source: id, target: targetCode, text: sentence,
                        protectedWords: part.tokens.map { "\($0.0)=\($0.1)" }, rules: rules))
                }
            }
        }
        return ExactModelWorkPolicy.sharedUnits(inFlight: modelUnitKeysInFlight, required: keys,
            workContext: modelContextInFlight, currentContext: contextRevision, reuseAllowed: true)
    }

    private func process(_ blocks: [String], display: Bool = true) async {
        if display { isTranslating = true }
        defer { if display { isTranslating = false } }
        let t0 = Date()
        if display { processingStarted = t0; savedRequests = 0 }
        let workGeneration = generation
        let workContext = contextRevision
        let workMode = memoryTestMode
        let workRAM = ram
        let workCandidate = activeCandidateID
        let rules = memoryRuleToken
        let destination = targetCode
        let speculativeStart = Date()
        let diagnosticEpoch = diag.started
        let speculativeID: UInt64? = display ? nil : ram.speculationWindow.begin()
        if !display && diag.enabled { diag.s.specStarted += 1 }
        defer {
            let discarded = Task.isCancelled || workContext != contextRevision || workCandidate != activeCandidateID
            if let speculativeID { workRAM.speculationWindow.finish(speculativeID, discarded: discarded) }
            if !display && diag.enabled && diag.started == diagnosticEpoch {
                let ms = Date().timeIntervalSince(speculativeStart) * 1000
                diag.s.specProcessingMs += ms
                if Task.isCancelled || workContext != contextRevision || workCandidate != activeCandidateID {
                    diag.s.specDiscarded += 1; diag.s.specDiscardedMs += ms
                } else { diag.s.specCompleted += 1 }
            }
        }
        diag.trace(currentPacket?.candidateID, stage: display ? "processing" : "speculating",
                   detail: "Translation started", frameIndex: currentPacket?.frames)
        let target = Locale.Language(identifier: destination)
        let cleanOn = flag("cleanOCR", true), slangOn = flag("slang", true), speakerOn = flag("speakerDetect", true)
        let fixes = pairs("sourceFixes")
        let never = list("neverTranslate", lower: false)

        var units: [[CaptionTranslationUnit]] = []
        var pending: [String: [(b: Int, u: Int, s: Int, text: String, key: String)]] = [:]
        var srcLangs: [String: Locale.Language] = [:]
        var eligibleMemoryKeys = Set<String>()
        var resolvedLookups: [String: MemoryLookupResult] = [:]
        var translatedAny = false
        var unresolvedSource = false
        var failureReason: String? = nil
        func isCurrent() -> Bool {
            let current = !Task.isCancelled && workContext == contextRevision && workMode == memoryTestMode &&
                (!display || workGeneration == generation) &&
                CandidateValidity.isCurrent(workCandidate, active: activeCandidateID,
                    enabled: flag("steadyCaptions", true))
            if display && !current && diag.detailedCollection && diag.started == diagnosticEpoch {
                diag.trace(workCandidate, stage: "cancelled",
                           detail: "Obsolete translation generation or candidate")
            }
            return current
        }

        /// Remembers a finished sentence. Early (translate-ahead) results are marked so we can show how often they pay off.
        func store(_ key: String, _ out: String) {
            guard isCurrent(), memoryTestMode.allowsReuse else { return }
            guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            ram.values[key] = out
            ram.savedKeys.remove(key)
            if display && eligibleMemoryKeys.contains(key) && !flag("freshTranslationTest", false) {
                ram.confirmedKeys.insert(key)
                queueMemory(key, out, independentlyConfirmed: true)
            }
            memoryDirty = true
            touchCache(key)
            if !display {
                if ram.specKeys.insert(key).inserted { diag.noteSpeculativeUnit("retained") }
                if let speculativeID { ram.speculativeOrigins[key] = speculativeID }
            }
        }

        for (bi, raw) in blocks.enumerated() {
            let text = cleanedSource(raw, enabled: cleanOn, fixes: fixes)
            if display && diag.detailedCollection && text != raw {
                diag.trace(workCandidate, stage: "ocrCorrection",
                           detail: "Recognized text was cleaned or corrected")
            }
            guard let choice = detectSource(text, record: display) else {
                if display && diag.detailedCollection {
                    diag.trace(workCandidate, stage: "language",
                               detail: "No compatible source language selected")
                }
                unresolvedSource = true
                units.append([CaptionTranslationUnit(label: nil, sentences: [text], out: [text], tokens: [])])
                continue
            }
            guard choice.language.languageCode != target.languageCode else {
                units.append([CaptionTranslationUnit(label: nil, sentences: [text], out: [text], tokens: [])])
                continue
            }
            let src = choice.language
            let id = src.minimalIdentifier
            if display && diag.detailedCollection {
                diag.trace(workCandidate, stage: "language",
                           detail: "Source language resolved for current candidate")
            }
            if display {
                if diag.s.sourceUsed != id || diag.s.sourceOrigin != choice.origin.title {
                    diag.event(.language, "Source resolved: \(id) (\(choice.origin.title))")
                }
                diag.recordSourceLanguage(id, origin: choice.origin)
                if choice.origin != .selected, detectedLang != id { detectedLang = id }
            }
            srcLangs[id] = src
            let sourceConfidence = sourceCode == "auto" ? (languageEvidence(text, limit: 5).1.filter {
                SourceLanguageRouter.sameLanguage($0.key.rawValue, id)
            }.values.max() ?? 0) : 0
            let memoryEligible = MemoryRetentionPolicy.mayPersist(privateSession: flag("privateSession", false),
                selectedSource: sourceCode != "auto", confidence: sourceConfidence, confirmed: display) && allowsPersistentTranslations
            let parts = preparedSourceUnits(text, language: src.languageCode?.identifier ?? id,
                slang: slangOn, speakers: speakerOn, protected: never)
            var row: [CaptionTranslationUnit] = []
            for (ui, d) in parts.enumerated() {
                if display, let name = d.label { diag.learn(name) }
                let sentences = d.sentences
                if display && diag.detailedCollection {
                    diag.trace(workCandidate, stage: "segmentation",
                               detail: "Translation units assigned to stable block")
                }
                if display && diag.enabled { diag.s.sentences += sentences.count }
                var outs: [String?] = []
                for (si, s) in sentences.enumerated() {
                    let key = PipelineSafety.cacheKey(source: id, target: destination, text: s, protectedWords: d.tokens.map { "\($0.0)=\($0.1)" }, rules: rules)
                    if memoryEligible && TranslationUnitPlanning.mayRemember(s, confirmed: display) {
                        eligibleMemoryKeys.insert(key)
                    }
                    let lookupStart = ProcessInfo.processInfo.systemUptime
                    let bypassReuse = bypassMemory || flag("freshTranslationTest", false)
                    if display && bypassReuse {
                        diag.recordMemory(.bypassed, candidate: workCandidate, unitKey: key)
                    }
                    var resolvedHit = bypassReuse ? nil : ram.values[key]
                    var diskHit = false
                    if resolvedHit == nil, !bypassReuse, allowsPersistentTranslations, memoryReady, flag("remember", true), !flag("privateSession", false) {
                        let lookup: MemoryLookupResult
                        if let previous = resolvedLookups[key] { lookup = previous }
                        else {
                            lookup = await memoryStore.lookup(key: key)
                            resolvedLookups[key] = lookup
                        }
                        guard isCurrent() else {
                            if display {
                                // Never attribute an obsolete result to the newer
                                // packet. Count it as cancelled, not as a usable hit.
                                if diag.started == diagnosticEpoch {
                                    diag.recordMemory(.cancelled, durationMs: lookup.durationMs,
                                        candidate: workCandidate, unitKey: key)
                                }
                            }
                            return
                        }
                        resolvedHit = lookup.value
                        diskHit = lookup.value != nil
                        if display {
                            let outcome: MemoryDiagnosticOutcome
                            switch lookup.outcome {
                            case "timeout": outcome = .timeout
                            case "normalized_hit": outcome = .normalizedHit
                            case "incompatible", "conflict": outcome = .compatibilityRejected
                            case "database_error", "unavailable": outcome = .databaseUnavailable
                            default: outcome = diskHit ? (lookup.origin == "legacy" ? .legacyHit : .persistentHit) : .miss
                            }
                            diag.recordMemory(outcome, durationMs: lookup.durationMs,
                                              candidate: currentPacket?.candidateID,
                                              frameIndex: currentPacket?.frames, unitKey: key)
                        }
                        if let value = resolvedHit {
                            ram.values[key] = value; ram.savedKeys.insert(key); touchCache(key)
                        }
                    }
                    if let hit = resolvedHit {
                        touchCache(key)
                        outs.append(hit); translatedAny = true
                        if display {
                            if memoryTestMode == .temporaryMemory { diag.noteTemporaryReuse() }
                            let speculativeHit = ram.specKeys.remove(key) != nil
                            if speculativeHit { diag.noteSpeculativeUnit("reused") }
                            if speculativeHit, let origin = ram.speculativeOrigins.removeValue(forKey: key) {
                                ram.speculationWindow.reuse(origin)
                            }
                            let savedFromRAM = ram.savedKeys.remove(key) != nil
                            let savedHit = diskHit || savedFromRAM
                            ram.speculationWindow.recordConfirmedOutcome(saved: savedHit && !speculativeHit)
                            if !diskHit { diag.recordMemory(speculativeHit ? .speculativeHit : .ramHit,
                                                                  durationMs: (ProcessInfo.processInfo.systemUptime - lookupStart) * 1000,
                                                                  candidate: currentPacket?.candidateID,
                                                                  frameIndex: currentPacket?.frames, unitKey: key) }
                            // A speculative result was produced by the current on-device
                            // model, not by historical memory. Once this exact key is
                            // independently confirmed by stable OCR, it is safe to use
                            // as evidence for lazy legacy reconciliation without another
                            // model call. Ordinary RAM/SQLite hits remain untrusted proof.
                            if memoryEligible && ram.confirmedKeys.insert(key).inserted && !savedHit {
                                queueMemory(key, hit, independentlyConfirmed: speculativeHit)
                            }
                            if diag.enabled {
                                if speculativeHit { diag.s.specHits += 1 }
                                else if savedHit { diag.s.savedHits += 1 }
                                else { diag.s.cacheHits += 1 }
                            }
                            diag.trace(currentPacket?.candidateID, stage: "cache", detail: speculativeHit ? "Speculative hit" : (savedHit ? "Saved-memory hit" : "Session hit"))
                        }
                    } else {
                        outs.append(nil)
                        if display && memoryTestMode == .temporaryMemory {
                            diag.recordMemory(.temporaryMiss, candidate: workCandidate, unitKey: key)
                        }
                        if display {
                            ram.speculationWindow.recordConfirmedOutcome(saved: false)
                            if diag.enabled { diag.s.cacheMisses += 1 }
                        }
                        pending[id, default: []].append((bi, ui, si, s, key))
                    }
                }
                row.append(CaptionTranslationUnit(label: d.label, sentences: sentences, out: outs, tokens: d.tokens))
            }
            units.append(row)
        }

        var failed = false
        for (id, items) in pending {
            guard let src = srcLangs[id] else { continue }
            guard isCurrent() else { return }
            let availability = await pairStatus(src, target)
            guard isCurrent() else { return }
            if availability == .unsupported {
                failureReason = "\(id) → \(targetCode) isn't supported"
                if display { status = failureReason ?? "Unsupported language pair"; diag.event(.language, status) }
                failed = true; continue
            }
            if availability == .supported {
                if !display { continue }
                failureReason = "Download the \(id) → \(targetCode) language packs in Languages"
                status = failureReason ?? "Language pack missing"
                diag.event(.language, status)
            }
            if display && diag.enabled { diag.s.batches += 1 }
            let installed = availability == .installed
            let plan = TranslationBatchPlan(items.map { $0.text }, contexts: items.map { $0.key })
            if display { savedRequests += items.count - plan.unique.count }
            diag.noteExactUnitCoalescing(items.count - plan.unique.count)
            if !display && diag.enabled { diag.s.specModelRequests += plan.unique.count }
            if display && diag.detailedCollection {
                diag.trace(workCandidate, stage: "freshTranslation",
                           detail: "Uncached units submitted to on-device translation")
            }
            let streamPartials = installed && workMode.allowsReuse &&
                (display || flag("incrementalBatchRecovery", false))
            var completedParts: [Int: String] = [:]
            var partialHandler: (@MainActor (Int, String) -> Void)?
            if streamPartials {
                let exactKeys = plan.uniqueContexts
                partialHandler = { [weak self] index, value in
                    guard index >= 0, index < exactKeys.count else { return }
                    completedParts[index] = value
                    self?.retainCompletedModelUnit(key: exactKeys[index], value: value,
                        context: workContext, rules: rules, destination: destination,
                        mode: workMode, bank: workRAM, confirmed: display,
                        speculativeID: speculativeID, epoch: diagnosticEpoch)
                }
            }
            modelUnitKeysInFlight = Set(items.map { $0.key })
            modelContextInFlight = workContext
            let batch = await translateBatch(plan.unique, source: src, target: target, installed: installed,
                                             speculative: !display, partial: partialHandler)
            modelUnitKeysInFlight.removeAll()
            modelContextInFlight = nil
            if !isCurrent() {
                // Cancellation is cooperative: confirmed or speculative model work
                // can finish after a different caption arrives. Recover only completed exact-key
                // units in the SAME context, never publish this old caption,
                // never retry it and never write unconfirmed output to disk.
                let recovered = SubtitlePerformancePolicy.retainedSpeculativeResults(
                    keys: items.map { $0.key },
                    values: batch.flatMap { plan.expand($0.map(Optional.some)) },
                    workContext: workContext, currentContext: contextRevision,
                    reuseAllowed: workMode == memoryTestMode && !bypassMemory && !flag("freshTranslationTest", false) &&
                        rules == memoryRuleToken && destination == targetCode)
                var retained = 0
                for (key, value) in recovered where ram.values[key] == nil {
                    ram.values[key] = value
                    ram.savedKeys.remove(key)
                    if !display, ram.specKeys.insert(key).inserted { diag.noteSpeculativeUnit("retained") }
                    if let speculativeID { ram.speculativeOrigins[key] = speculativeID }
                    touchCache(key)
                    retained += 1
                }
                trimCache()
                if diag.enabled && diag.started == diagnosticEpoch {
                    if !display { diag.s.specRetainedUnits += retained }
                    else { diag.noteCompletedWorkRecovery(retained) }
                }
                return
            }
            guard isCurrent() else { return }
            if display && diag.detailedCollection {
                diag.trace(workCandidate, stage: "translationResult",
                           detail: (batch?.count == plan.unique.count) ?
                                   "On-device model batch returned expected count" :
                                   "Translation batch was incomplete; retry policy applies")
            }
            var uniqueResults: [String?]
            if let batch, batch.count == plan.unique.count {
                uniqueResults = batch.map(Optional.some)
            } else {
                // Tentative work gets one attempt. Let confirmed processing own
                // retries instead of holding its queue behind speculative retries.
                if !display { return }
                diag.log("Batch failed – retrying unique sentences")
                uniqueResults = []
                for (index, sentence) in plan.unique.enumerated() {
                    guard isCurrent() else { return }
                    if let completed = completedParts[index] {
                        uniqueResults.append(completed)
                        continue
                    }
                    if !display && diag.enabled { diag.s.specModelRequests += 1 }
                    let result = await translateBatch([sentence], source: src, target: target, installed: installed, speculative: !display)
                    uniqueResults.append(result?.count == 1 ? result?.first : nil)
                }
            }
            guard isCurrent(), let results = plan.expand(uniqueResults) else { return }
            for (index, item) in items.enumerated() {
                if let value = results[index] {
                    units[item.b][item.u].out[item.s] = value
                    store(item.key, value)
                    translatedAny = true
                } else {
                    failed = true
                    if display && diag.enabled { diag.s.failures += 1 }
                }
            }
        }
        guard isCurrent(), (!paused || manualMode) else { return }
        trimCache()
        bypassMemory = false

        guard translatedAny else {
            if display {
                if failed, failureReason == nil, !Task.isCancelled, sourceCode == "auto", flag("languageRecovery", true) {
                    languageFailures += 1
                    if languageFailures >= 2 {
                        languageRouter.reset(); languageContext.reset(); lockedLang = nil; languageCache.removeAll(); languageFailures = 0
                        diag.event(.language, "Automatic source recovery after repeated translation failures")
                        rotRev += 1; syncConfig()
                    }
                }
                lastHandled = ""
                status = failed ? (failureReason ?? "Translation failed – check the language packs in Languages")
                    : (unresolvedSource ? "Could not identify the source – choose a source language in Languages" : "Text is already in the target language")
            }
            return
        }
        if !display { return }          // translate-ahead: the result now waits in the active RAM bank
        guard !failed else {
            lastHandled = ""
            status = failureReason ?? "Translation incomplete – keeping the previous result. Tap Retry."
            return
        }
        guard let assembled = CaptionAssembly.complete(units, glossary: pairs("glossary")) else {
            lastHandled = ""
            status = "Translation incomplete – keeping the previous result. Tap Retry."
            return
        }
        languageFailures = 0
        translateMs = Date().timeIntervalSince(t0) * 1000
        diag.trace(currentPacket?.candidateID, stage: "ready", detail: "Translation assembled")
        var sentenceCount = 0
        for row in units { for u in row { sentenceCount += u.sentences.count } }
        if memoryTestMode.allowsReuse,
           let key = ExactCaptionIdentity.key(blocks: blocks, source: sourceCode,
                                              target: targetCode, rules: rules) {
            ram.retainCaption(key: key, result: ExactCaptionResult(
                translated: assembled, sentences: sentenceCount))
        }
        diag.recordTranslate(ms: translateMs, sentences: sentenceCount,
                             from: srcLangs.keys.sorted().joined(separator: "+"), to: targetCode,
                             preview: assembled)
        if diag.enabled { diag.s.translations += 1 }
        if diag.enabled { diag.s.chars += blocks.joined().count }
        status = "\(srcLangs.keys.sorted().joined(separator: "+")) → \(targetCode) ✓"
        let timing = PresentationTiming(packet: currentPacket, firstSeen: currentTs,
            queuedAt: currentQueuedAt, processingAt: processingStarted, processingMs: translateMs,
            savedRequests: savedRequests, readyAt: Date())
        schedulePresentation(blocks.joined(separator: "\n"), assembled,
                             generation: workGeneration, context: workContext, timing: timing)
    }

    /// Translates many sentences in one call.
    private func translateBatch(_ texts: [String], source: Locale.Language, target: Locale.Language,
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

    private func runBatch(_ session: TranslationSession, _ texts: [String],
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

    private struct PresentationTiming {
        let packet: Packet?
        let firstSeen: Double
        let queuedAt: Date
        let processingAt: Date
        let processingMs: Double
        let savedRequests: Int
        let readyAt: Date
    }

    private func cancelPresentation() {
        presentationTask?.cancel(); presentationTask = nil
        presentationID = UUID()
        if waitingToDisplay { waitingToDisplay = false }
    }

    private func schedulePresentation(_ text: String, _ result: String, generation: Int, context: Int, timing: PresentationTiming) {
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

    @discardableResult
    private func show(_ text: String, _ result: String, timing: PresentationTiming) -> Bool {
        clearTask?.cancel()
        clearTask = nil
        guard !frozen, (!paused || manualMode),
              CandidateValidity.isCurrent(timing.packet?.candidateID, active: activeCandidateID, enabled: flag("steadyCaptions", true), allowLegacy: true) else { return false }
        if activeTranslationSystem == .legacy, PipelineSafety.isRecentFragment(text, of: original, age: Date().timeIntervalSince(lastShowDate)) { return false }
        let renderStart = Date()
        pip.style = pipStyle
        guard pip.render(original: text, translated: result, showOriginal: showOriginal,
                         size: windowSize.size) else {
            lastHandled = ""
            status = "Frame preparation failed – keeping the previous subtitle. Tap Retry."
            diag.notePipelineDecision(candidate: timing.packet?.candidateID,
                frameIndex: timing.packet?.frames, stage: "pip_enqueue", reason: "enqueue_failed")
            return false
        }
        original = text
        translated = result
        showing = true
        lastTextDate = Date()
        lastShowDate = Date()
        let presented = Date()
        let packet = timing.packet
        let sent = packet?.ts ?? timing.queuedAt.timeIntervalSince1970
        let first = packet?.firstSeenAt ?? timing.firstSeen
        let read = packet?.readStartedAt ?? sent
        let total = timing.firstSeen > 0 ? max(0, presented.timeIntervalSince1970 - timing.firstSeen) * 1000 : 0
        latency.last = LatencyBreakdown(
            recognition: packet?.ocrMs ?? 0,
            confirmation: max(0, read - first) * 1000,
            delivery: max(0, timing.queuedAt.timeIntervalSince1970 - read - (packet?.ocrMs ?? 0) / 1000) * 1000,
            queue: max(0, timing.processingAt.timeIntervalSince(timing.queuedAt)) * 1000,
            translation: timing.processingMs,
            displayHold: max(0, renderStart.timeIntervalSince(timing.readyAt)) * 1000,
            rendering: presented.timeIntervalSince(renderStart) * 1000,
            total: total, requestsSaved: timing.savedRequests)
        diag.trace(packet?.candidateID, stage: "enqueued", detail: "PiP frame prepared in \(Int(latency.last.rendering)) ms; physical presentation unmeasured")
        if packet?.candidateID == activeCandidateID {
            activeCandidatePresented = true
        }
        if diag.enabled { diag.s.enqueuedCandidateFrames += 1 }
        if total >= 1200 {
            if diag.enabled { diag.s.slowTailEnqueues += 1 }
            diag.notePipelineDecision(candidate: packet?.candidateID,
                frameIndex: packet?.frames, stage: "pip_enqueue",
                reason: "slow_tail", durationMs: total)
        }
        if activeTranslationSystem == .legacy, let candidate = packet?.candidateID {
            diag.legacyModeEnqueued(candidate, duration: total, source: sourceCode == "auto" ? detectedLang : sourceCode)
        }
        diag.recordPipeline(latency.last)
        if total > 0 { diag.recordLatency(ms: total) }
        if history.first?.original != text {
            sessionTranslations += 1; sessionCharacters += text.count
            if memoryTestMode.allowsHistoryInsertion && !flag("privateSession", false) {
                history.insert(HistoryItem(original: text, translated: result,
                                           sourceLanguage: sourceCode == "auto" ? detectedLang : sourceCode,
                                           targetLanguage: targetCode), at: 0)
                if history.count > historyCapacity { history.removeLast() }
            }
            if flag("speak", false) { speak(result) }
            if flag("haptics", false) {
                let strength = ud.string(forKey: "hapticStrength") ?? "light"
                UIImpactFeedbackGenerator(style: strength == "strong" ? .heavy : (strength == "medium" ? .medium : .light)).impactOccurred()
            }
            if flag("autoCopy", false) {
                let format = ud.string(forKey: "autoCopyFormat") ?? "translation"
                UIPasteboard.general.string = format == "original" ? text : (format == "bilingual" ? text + "\n" + result : result)
            }
        }
        renderedGrams = TextSim.grams(result).union(placeholderGrams)
        sourceGrams = TextSim.grams(text)
        // Only a successfully displayed, independently resolved source should
        // influence a future predictive model warm-up; never change Auto OCR.
        let sourceToRemember = sourceCode == "auto" ? detectedLang : sourceCode
        if sourceToRemember != "–", !sourceToRemember.isEmpty {
            ud.set(sourceToRemember, forKey: "lastEffectiveSource")
            ud.set(Date().timeIntervalSince1970, forKey: "lastEffectiveSourceAt")
        }
        replayDeferredConfirmedIfPossible()
        return true
    }

    func speak(_ s: String) {
        let voices = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "pt": "pt-BR", "en": "en-US", "es": "es-ES",
                      "fr": "fr-FR", "de": "de-DE", "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR", "ru": "ru-RU",
                      "ar": "ar-SA", "tr": "tr-TR", "hi": "hi-IN", "id": "id-ID", "nl": "nl-NL", "pl": "pl-PL",
                      "th": "th-TH", "vi": "vi-VN", "uk": "uk-UA"]
        if speech.isSpeaking, !flag("interruptSpeech", true) { return }
        speech.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: s)
        u.voice = AVSpeechSynthesisVoice(language: voices[targetCode] ?? targetCode)
        u.rate = Float(num("speechRate", 0.5))
        speech.speak(u)
    }

    // MARK: Translation memory (kept between launches)
    private var memoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenLingo", isDirectory: true).appendingPathComponent("translation-memory-v4.json")
    }

    private func loadMemory() {
        diag.memoryStore = memoryStore
        let legacy = [memoryURL, FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("translation-memory.json")]
        Task { [weak self] in
            guard let self else { return }
            do {
                let health = try await self.memoryStore.prepare(legacyURLs: legacy)
                self.memoryReady = true
                self.applyMemoryHealth(health)
                self.saveMemory(force: true)
            } catch {
                self.memoryFailure = "Memory unavailable; fresh translation remains available"
                self.diag.log("Memory initialization failed; preserved data requires recovery")
            }
        }
    }

    private func touchCache(_ key: String) {
        if temporaryMemoryEntries != processMemory.temporary.values.count {
            temporaryMemoryEntries = processMemory.temporary.values.count
        }
        ram.clock &+= 1
        ram.use[key] = ram.clock
    }

    private func queueMemory(_ key: String, _ value: String, independentlyConfirmed: Bool = false, knownDefault: Bool = false) {
        guard allowsPersistentTranslations, flag("remember", true), !flag("privateSession", false),
              !flag("freshTranslationTest", false) else { return }
        // Bound pending writes without claiming unsaved entries are durable.
        guard pendingMemory[key] != nil || pendingMemory.count < 3000 else {
            memoryFailure = "Memory write queue full; new entries remain session-only"
            return
        }
        pendingMemory[key] = value
        if independentlyConfirmed || knownDefault || ram.specKeys.contains(key) { pendingDefaultStrategy[key] = value }
        if independentlyConfirmed { pendingLegacyProof[key] = value }
        else if pendingLegacyProof[key] != value { pendingLegacyProof[key] = nil }
        memoryPendingWrites = pendingMemory.count
        memoryDirty = true
        if memoryCoalescingTask == nil {
            memoryCoalescingTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 75_000_000)
                guard !Task.isCancelled, let self else { return }
                self.memoryCoalescingTask = nil
                self.saveMemory()
            }
        }
    }

    func saveMemory(force: Bool = false) {
        if force { memoryCoalescingTask?.cancel(); memoryCoalescingTask = nil }
        guard memoryReady, !memorySaving, !memoryMutationInProgress, !pendingMemory.isEmpty,
              force || Date() >= storageFullRetryNotBefore else { return }
        memorySaving = true
        let snapshot = pendingMemory
        let freshKeys = Set(snapshot.compactMap { key, value in
            pendingLegacyProof[key] == value ? key : nil
        })
        memoryRevision += 1
        let revision = memoryRevision
        let diagnosticEpoch = diag.started
        Task { [weak self] in
            guard let self else { return }
            let writeStart = ProcessInfo.processInfo.systemUptime
            var committed = false
            var storageFull = false
            var committedHealth: MemoryStoreHealth?
            do {
                committedHealth = try await self.memoryStore.save(snapshot,
                    revision: revision, independentlyConfirmedKeys: freshKeys,
                    knownDefaultStrategyKeys: Set(snapshot.keys.filter { self.pendingDefaultStrategy[$0] == snapshot[$0] }))
                committed = true
                if self.memoryRevision == revision {
                    for (key, value) in snapshot where self.pendingMemory[key] == value {
                        self.pendingMemory[key] = nil
                        if self.pendingDefaultStrategy[key] == value { self.pendingDefaultStrategy[key] = nil }
                        if self.pendingLegacyProof[key] == value {
                            self.pendingLegacyProof[key] = nil
                        }
                    }
                }
                self.memoryFailure = nil
                if self.diag.started == diagnosticEpoch {
                    self.diag.recordMemory(.persisted, durationMs: (ProcessInfo.processInfo.systemUptime - writeStart) * 1000)
                }
            } catch MemoryStoreError.storageFull {
                storageFull = true
                // Avoid retry storms on every changed subtitle when storage is full.
                // Confirmed results remain pending for the next explicit/periodic retry.
                self.storageFullRetryNotBefore = Date().addingTimeInterval(30)
                self.memoryFailure = "Device storage full; remembered translations are pending, not saved"
                if self.diag.started == diagnosticEpoch {
                    self.diag.recordMemory(.writeFailed,
                        durationMs: (ProcessInfo.processInfo.systemUptime - writeStart) * 1000)
                }
            } catch {
                self.memoryFailure = "Memory write failed; pending entries will retry"
                if self.diag.started == diagnosticEpoch {
                    self.diag.recordMemory(.writeFailed,
                        durationMs: (ProcessInfo.processInfo.systemUptime - writeStart) * 1000)
                }
            }
            self.memorySaving = false
            self.memoryPendingWrites = self.pendingMemory.count
            self.memoryDirty = !self.pendingMemory.isEmpty
            if committed {
                self.memoryRetryAttempts = 0
                self.storageFullRetryNotBefore = .distantPast
            }
            if let committedHealth { self.applyMemoryHealth(committedHealth) }
            else { await self.refreshMemoryHealth() }
            guard !self.pendingMemory.isEmpty else { return }
            if committed {
                // Confirmations queued during the previous commit must not get stranded.
                self.saveMemory(force: true)
            } else if !storageFull && self.memoryRetryAttempts < 3 {
                self.memoryRetryAttempts += 1
                let delay: UInt64 = [2, 5, 15][self.memoryRetryAttempts - 1] * 1_000_000_000
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: delay)
                    self?.saveMemory(force: true)
                }
            }
        }
    }

    /// Best-effort bounded persistence for iOS suspension. Returning false means
    /// confirmed entries remain visibly pending; it is never a durability claim.
    func flushPendingMemory(maxWaitSeconds: Double = 2.5) async -> Bool {
        guard memoryReady else { return pendingMemory.isEmpty && !memorySaving }
        let seconds = min(5.0, max(0.1, maxWaitSeconds))
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var retries = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            if pendingMemory.isEmpty && !memorySaving { return true }
            if !memorySaving && !memoryMutationInProgress && retries < 2 {
                retries += 1
                saveMemory(force: true)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        memoryPendingWrites = pendingMemory.count
        if !pendingMemory.isEmpty {
            memoryFailure = "Confirmed translations remain pending after background flush"
        }
        return pendingMemory.isEmpty && !memorySaving
    }

    func refreshMemoryHealth() async {
        do { applyMemoryHealth(try await memoryStore.health()) }
        catch { memoryFailure = "Memory health unavailable" }
    }

    /// Reuse the health snapshot already returned after COMMIT. A second full
    /// health query would occupy the same SQLite actor that serves live lookups.
    private func applyMemoryHealth(_ health: MemoryStoreHealth) {
        memoryHealth = health
        memoryCount = health.totalEntries
        var diagnosticHealth = diag.memoryHealth
        diagnosticHealth.totalEntries = health.totalEntries
        diagnosticHealth.readyEntries = health.readyEntries
        diagnosticHealth.needsValidation = health.needsValidation
        diagnosticHealth.legacyValidated = health.legacyValidated
        diagnosticHealth.legacySuperseded = health.legacySuperseded
        diagnosticHealth.legacyUnverified = health.legacyUnverified
        diagnosticHealth.suggestedOCRMatches = health.suggestedOCRMatches
        diagnosticHealth.suggestedFragmentMatches = health.suggestedFragmentMatches
        diagnosticHealth.conflicts = health.conflicts
        diagnosticHealth.databaseBytes = health.databaseBytes
        diagnosticHealth.migrationStatus = health.migrationStatus
        diagnosticHealth.integrity = health.integrity
        diagnosticHealth.failedWrites = health.failedWrites
        diagnosticHealth.pendingWrites = memoryPendingWrites
        diagnosticHealth.ramEntries = ram.values.count
        diagnosticHealth.categoryCounts = health.categoryCounts
        diag.memoryHealth = diagnosticHealth
    }

    func clearRAMCache() {
        invalidatePending()
        processMemory.normal.clear()
        segmentationCache.clear()
        // Temporary test entries are process-owned and are not reset by normal
        // memory maintenance, diagnostics reset, mode toggles or app switches.
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

    func removeMemoryEntries(ids: [Int64]) async throws {
        guard memoryReady, !memorySaving, !memoryMutationInProgress, pendingMemory.isEmpty
        else { throw MemoryStoreError.unavailable }
        memoryMutationInProgress = true
        defer {
            memoryMutationInProgress = false
            saveMemory(force: true)
        }
        clearRAMCache()
        try await memoryStore.delete(ids: ids)
        await refreshMemoryHealth()
    }


    /// Storage imports and review operations are serialized against engine writes.
    /// New confirmations arriving while a maintenance operation awaits the store
    /// remain in pendingMemory and are flushed after its commit.
    func importMemoryData(_ data: Data) async throws {
        guard memoryReady, !memorySaving, !memoryMutationInProgress, pendingMemory.isEmpty
        else { throw MemoryStoreError.unavailable }
        memoryMutationInProgress = true
        defer {
            memoryMutationInProgress = false
            saveMemory(force: true)
        }
        let health = try await memoryStore.importData(data)
        clearRAMCache()
        applyMemoryHealth(health)
    }

    func quarantineMemoryEntries(ids: [Int64]) async throws {
        guard memoryReady, !memorySaving, !memoryMutationInProgress, pendingMemory.isEmpty
        else { throw MemoryStoreError.unavailable }
        memoryMutationInProgress = true
        defer {
            memoryMutationInProgress = false
            saveMemory(force: true)
        }
        let health = try await memoryStore.quarantineEntries(ids: ids)
        clearRAMCache()
        applyMemoryHealth(health)
    }

    func mergeMemoryRecoverySnapshot(named name: String) async throws {
        guard memoryReady, !memorySaving, !memoryMutationInProgress, pendingMemory.isEmpty
        else { throw MemoryStoreError.unavailable }
        memoryMutationInProgress = true
        defer {
            memoryMutationInProgress = false
            saveMemory(force: true)
        }
        let health = try await memoryStore.mergeRecoverySnapshot(named: name)
        clearRAMCache()
        applyMemoryHealth(health)
    }

    /// The management UI must not report deletion until the SQLite transaction commits.
    /// Existing callers can still invoke the fire-and-forget compatibility entry point.
    func clearMemory() {
        Task { _ = await clearMemoryConfirmed() }
    }

    @discardableResult
    func clearMemoryConfirmed() async -> Bool {
        // Enforce a barrier across the suspension: new confirmed translations
        // remain pending and cannot be written until the clear completes.
        guard memoryReady, !memoryMutationInProgress, !memorySaving, pendingMemory.isEmpty else {
            memoryFailure = "Wait for pending memory writes before deleting"
            return false
        }
        memoryMutationInProgress = true
        clearRAMCache()
        memoryRevision += 1
        let revision = memoryRevision
        defer {
            memoryMutationInProgress = false
            // Any new confirmations queued while SQLite was busy are still owed a write.
            saveMemory(force: true)
        }
        do {
            try await memoryStore.clear(revision: revision)
            clearRAMCache()
            await refreshMemoryHealth()
            memoryFailure = nil
            toast("Translation memory cleared")
            return true
        } catch {
            memoryFailure = "Memory could not be cleared; saved data was preserved"
            return false
        }
    }

    /// Only call after clearMemoryConfirmed() succeeded and the user explicitly
    /// requested erasure of recoverable memory originals and snapshots.
    func purgePreservedMemoryCopies() async throws {
        let legacy = [memoryURL,
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("translation-memory.json")]
        try await memoryStore.deletePreservedCopies(legacyURLs: legacy)
        await refreshMemoryHealth()
    }

    /// Explicit maintenance route when SQLite initialization failed. A failed
    /// recovery leaves pending confirmations intact and fresh translation active.
    func restoreUnavailableMemoryFromSnapshot(named name: String) async throws {
        guard !memoryReady, !memorySaving, !memoryMutationInProgress else {
            throw MemoryStoreError.unavailable
        }
        memoryMutationInProgress = true
        defer {
            memoryMutationInProgress = false
            if memoryReady { saveMemory(force: true) }
        }
        let health = try await memoryStore.recoverUnavailableStore(named: name)
        memoryReady = true
        clearRAMCache()
        applyMemoryHealth(health)
        memoryFailure = nil
        diag.log("Unavailable memory database restored from verified snapshot; damaged originals retained")
    }

    /// Called from the live app on an iOS memory warning. Persistent SQLite entries
    /// remain untouched; only evictable RAM entries are reduced.
    func handleMemoryPressure() {
        if activeTranslationSystem != .legacy { modeCoordinator.reduceSpeculation(memoryPressure: true) }
        let configured = max(250, min(6000, int("memoryRAMCapacity", 3000)))
        memoryPressureCapacity = max(250, configured / 4)
        trimCache()
    }

    private func trimCache() {
        let configured = max(250, min(6000, int("memoryRAMCapacity", 3000)))
        let limit = min(configured, memoryPressureCapacity ?? configured)
        let excess = ram.values.count - limit
        guard excess > 0 else { return }
        // The common case is one insertion beyond capacity. Finding the oldest
        // key with a linear scan avoids sorting the entire cache on every frame.
        let victims: [String]
        if excess == 1 {
            victims = ram.use.min(by: { $0.value < $1.value }).map { [$0.key] } ??
                      Array(ram.values.keys.prefix(1))
        } else {
            victims = ram.use.sorted(by: { $0.value < $1.value }).prefix(excess).map(\.key)
        }
        for key in victims {
            ram.values[key] = nil; ram.use[key] = nil
            if ram.specKeys.remove(key) != nil { diag.noteSpeculativeUnit("evictedUnused") }; ram.speculativeOrigins.removeValue(forKey: key); ram.savedKeys.remove(key); ram.confirmedKeys.remove(key)
        }
        // Report entries evicted, not maintenance batches; persistence is untouched.
        if temporaryMemoryEntries != processMemory.temporary.values.count {
            temporaryMemoryEntries = processMemory.temporary.values.count
        }
        diag.recordMemory(.ramEviction, count: victims.count)
    }

    // MARK: Bounded concurrent, foreground-only legacy validation

    private var mayRunIdleValidation: Bool {
        activeTranslationSystem == .legacy && memoryReady && !memorySaving && !memoryMutationInProgress &&
        pendingMemory.isEmpty && !legacyValidationBusy && !warming &&
        !captureAlive && !pipActive && !busy &&
        UIApplication.shared.applicationState == .active &&
        allowsPersistentTranslations && !flag("privateSession", false) && !flag("freshTranslationTest", false) &&
        !ProcessInfo.processInfo.isLowPowerModeEnabled &&
        ProcessInfo.processInfo.thermalState != .serious &&
        ProcessInfo.processInfo.thermalState != .critical
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
    private nonisolated static func translateIdleChunk(source: String, target: String,
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
        let fair = ProcessInfo.processInfo.thermalState == .fair
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

    // MARK: Keep the translator warm
    private static let warmWords = ["en": "Hello.", "pt": "Olá.", "es": "Hola.", "fr": "Bonjour.", "de": "Hallo.",
                                    "it": "Ciao.", "ja": "こんにちは。", "ko": "안녕하세요.", "zh": "你好。", "ru": "Привет."]
    private static let warmSentences = [
        "en": "We need to find out what happened here.",
        "pt": "Precisamos descobrir o que aconteceu aqui.",
        "es": "Tenemos que descubrir qué pasó aquí.",
        "fr": "Nous devons découvrir ce qui s’est passé ici.",
        "de": "Wir müssen herausfinden, was hier passiert ist.",
        "it": "Dobbiamo scoprire cosa è successo qui.",
        "ja": "ここで何が起きたのか調べなければなりません。",
        "ko": "여기서 무슨 일이 있었는지 알아봐야 합니다.",
        "zh": "我们需要弄清楚这里发生了什么。",
        "ru": "Нам нужно выяснить, что здесь произошло."]

    /// Loads the translation models before they're needed so the first real sentence isn't slow.
    func prewarm() async {
        if activeTranslationSystem != .legacy {
            guard #available(iOS 26.4, *) else {
                modelReadiness.prepare(.unavailable)
                modeAvailability = activeTranslationSystem == .lowLatency ? "Explicit low latency requires iOS 26.4 or later" : "Fast recovery needs iOS 26.4; Apple default fallback remains available"
                return
            }
            guard sourceCode != "auto", !captureAlive else { return }
            await refreshModePreparation(source: sourceCode, target: targetCode, system: activeTranslationSystem)
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
        if modelReadiness.source != code || modelReadiness.target != destination { modelReadiness = TranslationReadiness(source: code, target: destination) }
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
        // Direct sessions can warm independently; the iOS 18 hosted path has one continuation.
        guard #available(iOS 26.0, *) else { return }
        lastWarm = Date()
        let t0 = Date()
        warmupStatus = predicted ? "Predictive warm-up…" : "Warming up…"
        modelReadiness.prepare(.creatingSessions)
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

    func toggleStar(_ id: UUID) {
        if let i = history.firstIndex(where: { $0.id == id }) { history[i].starred.toggle() }
    }

    // iOS 18 path (needs the hosted .translationTask view in RootView)
    private func translateLegacy(_ texts: [String], source: Locale.Language, target: Locale.Language,
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

    // MARK: Languages / downloads
    func loadLanguages() async {
        let availability: LanguageAvailability
        if #available(iOS 26.4, *), activeTranslationSystem == .lowLatency {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else { availability = LanguageAvailability() }
        let supported = await availability.supportedLanguages
        var seen = Set<String>()
        var items: [LangItem] = []
        for l in supported {
            let code = l.minimalIdentifier
            guard seen.insert(code).inserted else { continue }
            items.append(LangItem(code: code, name: Locale.current.localizedString(forIdentifier: code) ?? code))
        }
        if !items.isEmpty { languages = items.sorted { $0.name < $1.name } }
        await refreshStatus()
    }

    func refreshStatus() async {
        availCache.removeAll()
        let destination = targetCode
        let target = Locale.Language(identifier: destination)
        let av: LanguageAvailability
        if #available(iOS 26.4, *), (activeTranslationSystem == .lowLatency) {
            av = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            av = LanguageAvailability()
        }
        var out: [String: LanguageAvailability.Status] = [:]
        // Read the active pair first so readiness does not wait behind every other language.
        var seen = Set<String>()
        let preferred = sourceCode == "auto" ? [] : [sourceCode]
        let codes = (preferred + languages.map(\.code)).filter { seen.insert($0).inserted }
        for code in codes {
            let source = Locale.Language(identifier: code)
            let availability = await av.status(from: source, to: target)
            guard destination == targetCode else { return }
            out[code] = availability
            availCache["\(source.minimalIdentifier)>\(target.minimalIdentifier)"] = (Date(), availability)
            if code == sourceCode { langStatus[code] = availability }
        }
        guard destination == targetCode else { return }
        langStatus = out
    }

    func download(_ code: String) {
        if pendingTranslationSystem != .legacy {
            guard #available(iOS 26.4, *) else { downloadMessage = "Explicit low latency requires iOS 26.4"; return }
            downloadConfig = .init(source: Locale.Language(identifier: code), target: Locale.Language(identifier: targetCode), preferredStrategy: .lowLatency)
            return
        }
        let src = Locale.Language(identifier: code)
        let tgt = Locale.Language(identifier: targetCode)
        if var c = downloadConfig, c.source == src, c.target == tgt {
            c.invalidate(); downloadConfig = c
        } else {
            downloadConfig = .init(source: src, target: tgt)
        }
    }
    func runDownload(_ session: TranslationSession) async {
        let workContext = contextRevision
        var prepared = false
        do {
            try await session.prepareTranslation()
            prepared = true
            downloadMessage = "Language pack ready"
            toast(downloadMessage)
        } catch {
            downloadMessage = "Download failed: " + error.localizedDescription
            toast("Download failed. Check Languages for details.")
        }
        await refreshStatus()
        if prepared, workContext == contextRevision, !paused, !manualMode {
            invalidatePending(); rotRev += 1; syncConfig()
        }
    }

    // MARK: Backup + bulk changes
    private func snapshot() -> [String: Any] {
        var snap: [String: Any] = [:]
        for k in Self.settingKeys { if let v = ud.object(forKey: k) { snap[k] = v } }
        return snap
    }
    func exportSettings() -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: snapshot(), options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
    func importSettings(_ text: String) -> Bool {
        guard let d = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        for k in Self.settingKeys {
            guard let v = o[k], !(v is NSNull), v is String || v is NSNumber else { continue }
            ud.set(v, forKey: k)
        }
        if let minimum = o["minDisplay"] as? NSNumber {
            ud.set(PresentationSchedule.inferredPolicy(saved: o["displayPolicy"] as? String,
                minimum: minimum.doubleValue), forKey: "displayPolicy")
        }
        reloadSettings()
        return true
    }
    /// Puts the given settings back to their defaults (used by every "Reset this page" button).
    func resetKeys(_ keys: [String]) {
        for k in keys { ud.removeObject(forKey: k) }
        reloadSettings()
        toast("Reset to defaults")
    }
    func resetAllSettings() { resetKeys(Self.settingKeys) }
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
    /// A picture of the current translation, for sharing.
    func snapshotImage() -> UIImage {
        PiPRenderer.image(original: original, translated: translated.isEmpty ? "Nothing translated yet" : translated,
                          showOriginal: showOriginal, size: windowSize.size, style: pipStyle)
    }

    // MARK: Test
    func runTest() {
        let samples = ["en": "Hello, how are you today?", "pt": "Olá, como você está hoje?",
                       "es": "Hola, ¿cómo estás hoy?", "fr": "Bonjour, comment allez-vous aujourd'hui ?",
                       "de": "Hallo, wie geht es dir heute?", "it": "Ciao, come stai oggi?",
                       "ja": "こんにちは、今日はお元気ですか？", "ko": "안녕하세요, 오늘 어떠세요?",
                       "zh": "你好，你今天好吗？", "ru": "Привет, как дела сегодня?"]
        var key = Locale.Language(identifier: sourceCode == "auto" ? "en" : sourceCode).languageCode?.identifier ?? "en"
        if key == (Locale.Language(identifier: targetCode).languageCode?.identifier ?? "") { key = "es" }
        lastHandled = ""
        status = "Testing…"
        queuedTs = Date().timeIntervalSince1970
        queuedPacket = nil
        enqueue([samples[key] ?? samples["en"]!])
    }

    static let fallbackLanguages: [LangItem] = [
        ("en","English"),("es","Spanish"),("fr","French"),("de","German"),("it","Italian"),
        ("pt","Portuguese"),("ru","Russian"),("ja","Japanese"),("ko","Korean"),
        ("zh-Hans","Chinese (Simplified)"),("zh-Hant","Chinese (Traditional)"),("ar","Arabic"),
        ("tr","Turkish"),("hi","Hindi"),("id","Indonesian"),("nl","Dutch"),("pl","Polish"),
        ("th","Thai"),("vi","Vietnamese"),("uk","Ukrainian")
    ].map { LangItem(code: $0.0, name: $0.1) }
}
