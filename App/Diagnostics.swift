import CryptoKit
// ScreenLingo – App
import SwiftUI
import Charts
import os
import Darwin

// MARK: - Models
struct Sample: Identifiable {
    let id = UUID()
    let t: Date
    let v: Double
}

enum EventKind: String, CaseIterable, Identifiable {
    case capture, pip, translation, language, rotation, preset, state, error, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .capture: "Capture"
        case .pip: "Window"
        case .translation: "Translation"
        case .language: "Language"
        case .rotation: "Rotation"
        case .preset: "Preset"
        case .state: "State"
        case .error: "Problem"
        case .system: "System"
        }
    }
    var icon: String {
        switch self {
        case .capture: "record.circle"
        case .pip: "rectangle.on.rectangle"
        case .translation: "character.bubble"
        case .language: "globe"
        case .rotation: "rotate.right"
        case .preset: "square.stack.3d.up"
        case .state: "circle.dotted"
        case .error: "exclamationmark.triangle.fill"
        case .system: "gearshape"
        }
    }
    var color: Color {
        switch self {
        case .capture: Color.green
        case .pip: Color.blue
        case .translation: Color.cyan
        case .language: Color.purple
        case .rotation: Color.orange
        case .preset: Color.pink
        case .state: Color.gray
        case .error: Color.red
        case .system: Color.secondary
        }
    }
    /// Sorts a plain log line into a category.
    static func classify(_ t: String) -> EventKind {
        let s = t.lowercased()
        if s.contains("failed") || s.contains("couldn't") || s.contains("error") || s.contains("stopped") { return .error }
        if s.contains("floating window") { return .pip }
        if s.contains("capture") { return .capture }
        if s.contains("rotation") || s.contains("reading order") { return .rotation }
        if s.contains("preset") || s.contains("profile") { return .preset }
        if s.contains("language") { return .language }
        if s.contains("translat") || s.contains("cleared") { return .translation }
        if s.contains("paused") || s.contains("now ") { return .state }
        return .system
    }
}

struct TimelineEvent: Identifiable {
    let id = UUID()
    let time: Date
    let kind: EventKind
    let text: String
    var detail: String? = nil
}

enum EngineState: String {
    case idle, live, paused, frozen
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .idle: Color.gray
        case .live: Color.green
        case .paused: Color.orange
        case .frozen: Color.blue
        }
    }
}

struct StateSpan: Identifiable {
    let id = UUID()
    let start: Date
    var end: Date?
    let state: EngineState
}

enum Fix: String {
    case fastSpeed, instantStability, immediateDisplay, fixedRotation, narrowArea, openLanguages, startCapture, translateAhead
    var label: String {
        switch self {
        case .fastSpeed: "Use Fast speed"
        case .instantStability: "Use Instant mode"
        case .immediateDisplay: "Show ready results immediately"
        case .fixedRotation: "Turn off auto-rotation"
        case .narrowArea: "Read the bottom third only"
        case .openLanguages: "Open Languages"
        case .startCapture: "Open Translate"
        case .translateAhead: "Turn on translate-ahead"
        }
    }
}

struct Issue: Identifiable {
    let id = UUID()
    let severity: Int          // 0 tip, 1 warning, 2 problem
    let title: String
    let detail: String
    let fix: Fix?
}

struct Assessment {
    var score: Int
    var headline: String
    var issues: [Issue]
}

struct Summary {
    var n = 0
    var min = 0.0
    var avg = 0.0
    var p50 = 0.0
    var p95 = 0.0
    var max = 0.0
    var last = 0.0
}

struct Stats: Equatable {
    var packets = 0, ocrPackets = 0, clearPackets = 0
    var frames = 0, passes = 0, skippedFrames = 0
    var fps = 0.0
    var bufferSize = "–", cropSize = "–", orientation = "–"
    var extFreeMB = 0.0, minExtFreeMB = 9999.0
    var linesIn = 0, dropArea = 0, dropSmall = 0, dropIgnore = 0, dropSelf = 0, dropTarget = 0, dropNoise = 0, dropLanguage = 0
    var blocksIn = 0, blocksKept = 0
    var sentences = 0, cacheHits = 0, specHits = 0, cacheMisses = 0, batches = 0, failures = 0, translations = 0, chars = 0
    var sessionKind = "–"
    var detected = "–"
    var sourceUsed = "–"
    var sourceOrigin = "–"
    var lockedLang = "–"
    var orderVote = 0.0
    var rotation = 0
    var calibrated = false
    var pipRegion = "–"
    var savedHits = 0
    var specModelRequests = 0
    var specStarted = 0, specCompleted = 0, specDiscarded = 0, specSkipped = 0
    var adaptiveSpeculationSkipped = 0, confirmedHandoffDeferred = 0
    var legacyAdaptiveLowYieldSkips = 0, legacyAdaptiveSavedSkips = 0
    var legacyLowConfidenceSkips = 0, legacyBusySpeculationSkips = 0
    var legacyDuplicateSpeculationSkips = 0
    var slowTailEnqueues = 0
    var specPreemptionRequested = 0, specMatchingConfirmation = 0
    var specRetainedUnits = 0
    var legacyBatchEntries = 0, legacyBatchVerified = 0, legacyBatchSkipped = 0
    var legacyBatchPeakWorkers = 0, legacyBatchElapsedMs = 0.0
    var specProcessingMs = 0.0, specDiscardedMs = 0.0
    var languageContextUsed = false
    var languageConfidence = 0.0, ocrConfidence = 0.0
    var recognitionReason = "–", confirmationReason = "–"
    var unchangedSkipped = 0, cadenceSkipped = 0, pausedSkipped = 0, emptyReads = 0, retryCount = 0
    var captureDrops = 0
    var rotationTries = 0
    var confirmedCandidatePackets = 0, deferredEarlyCandidates = 0
    var supersededUnpresentedConfirmed = 0, enqueuedCandidateFrames = 0
    var movieSelections = 0, movieTemporalOverrides = 0, movieRejectedSmall = 0
    var queueReplacements = 0, visualChanges = 0, earlyVisualWakes = 0, emptyOCRPasses = 0
    var largePackets = 0, packetSendErrors = 0
    var pixelConfirmations = 0, pixelRejections = 0, watchSkippedOCR = 0, watchTriggeredOCR = 0
    var firstSightVisualChangeLagMs = 0.0
    var effectiveOCRIntervalMs = 0.0
}

// MARK: - Recorder
@MainActor
final class Diagnostics: ObservableObject {
    private static var hardwareModelCode: String {
        var machine = utsname()
        _ = uname(&machine)
        // The hw.machine family code is not a device name or unique identifier.
        return withUnsafeBytes(of: &machine.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    @Published var s = Stats()
    @Published var ocr: [Sample] = []
    @Published var translate: [Sample] = []
    @Published var latency: [Sample] = []
    @Published var pipeline: [PipelineMeasurement] = []
    @Published var transport: [Sample] = []
    @Published var fps: [Sample] = []
    @Published var lineCounts: [Sample] = []
    @Published var extMem: [Sample] = []
    @Published var appMem: [Sample] = []
    @Published var thermal: [Sample] = []
    @Published var battery: [Sample] = []
    @Published var cacheRate: [Sample] = []
    @Published var events: [TimelineEvent] = []
    @Published var spans: [StateSpan] = []
    @Published private(set) var subtitleTraces: [SubtitleTrace] = []
    @Published var memoryHealth = MemoryDiagnosticHealth()
    @Published private(set) var structuredEvents: [StructuredDiagnosticEvent] = []
    @Published private(set) var archiveStatus = "Not saved"
    // v2.0.0 build 84 Test Runs (spec §11): runs are stored by TestRunStore, not in the memory database.
    struct ActiveRun {
        let id: UUID
        let startedAt: Date
        let mode: String
        var modeChanges: [String] = []
        var startingRAMEntries: Int
        var lastCheckpointAt: Date
    }
    struct RunBanner: Identifiable {
        let id = UUID()
        let result: TestRunSaveResult
        let mode: String
        let seconds: Double
        let at = Date()
    }
    @Published private(set) var activeRun: ActiveRun?
    @Published private(set) var testRuns: [TestRunMeta] = []
    @Published private(set) var runPruneNote: String?
    @Published private(set) var lastRunBanner: RunBanner?
    @Published private(set) var lastCheckpointCaptureMs: Double?
    let runStore = TestRunStore(directory: TestRunStore.defaultDirectory())
    private var unsavedEndedRun: (meta: TestRunMeta, snapshot: DiagnosticSessionExport)?
    private var checkpointInFlight = false
    private var checkpointCaptureMicros = 0
    @Published private(set) var exportInProgress = false
    var memoryStore: TranslationMemoryStore?
    private let exportWriter = DiagnosticExportWriter()
    private var diagnosticSessionID = UUID()
    // A 15-second full-session summary survives recent-event ring eviction.
    // No user text, OCR boxes, cache keys or untrusted labels enter these buckets.
    private var intervalStart = Date()
    private var intervalBaseline: [String: Int] = [:]
    private var intervalHistory: [DiagnosticIntervalBucket] = []
    // Independent 1s and 5s buckets preserve timing distributions from the
    // actual samples. Never average medians from smaller buckets.
    private var oneSecondStart = Date()
    private var oneSecondBaseline: [String: Int] = [:]
    private var oneSecondHistory: [DiagnosticIntervalBucket] = []
    private var fiveSecondStart = Date()
    private var fiveSecondBaseline: [String: Int] = [:]
    private var fiveSecondHistory: [DiagnosticIntervalBucket] = []
    private var openingEvents: [StructuredDiagnosticEvent] = []
    private var earlyEventsSeen = 0
    private var eventTotals: [String: Int] = [:]
    private var lastCaptureConnected = false
    private var lastRecordedThermalState: String?
    private(set) var captureReductionReasons = ["none"]
    private var requestedCaptureIntervalMs = 0
    private var requestedCaptureEdgePx = 0

    /// App-to-extension configuration, not a claim about actual Vision cadence.
    func noteCapturePolicy(edge: Double, interval: Double, coolMode: Bool,
                           memoryPressure: Bool, workloadPressure: Bool) {
        requestedCaptureEdgePx = max(0, Int(edge))
        requestedCaptureIntervalMs = max(0, Int((interval * 1000).rounded()))
        captureReductionReasons = ThermalPerformancePolicy.reductionReasons(
            state: ProcessInfo.processInfo.thermalState, coolMode: coolMode,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            memoryPressure: memoryPressure, workloadPressure: workloadPressure)
    }
    private var candidateIDs: [String: UUID] = [:]
    private var frameIDs: [Int: UUID] = [:]
    private var unitIDs: [String: UUID] = [:]
    private var memoryOutcomes: [MemoryDiagnosticOutcome: Int] = [:]
    private var modelTimingSamples: [String: [Double]] = [:]
    var translationTestMode = TranslationTestMode.normal
    var startingRAMEntries = 0
    var ramEntryCount: (() -> Int)?
    private var sharedModelUnits = 0
    private var sharedConfirmedModelUnits = 0
    private var memoryAwareSpeculationSkipped = 0
    private var ramCaptionBypasses = 0
    private var exactCaptionHits = 0
    private var exactUnitsCoalesced = 0
    private var speculativeUnitCounts: [String: Int] = [:]
    private var queueWaitSamples: [ModelQueueOwner: [Double]] = [:]
    private var temporaryMemoryHits = 0
    private var completedWorkRecoveredUnits = 0
    private var lookupSamples: [Double] = []
    private var writeSamples: [Double] = []
    private(set) var recorderCosts = RecorderCosts()
    private var recorderDepth = 0
    private struct CostToken { let start: Double; let outer: Bool; let detailed: Bool }
    private func beginRecorder() -> CostToken? {
        guard enabled else { return nil }
        recorderDepth += 1
        return CostToken(start: ProcessInfo.processInfo.systemUptime, outer: recorderDepth == 1, detailed: detailedCollection)
    }
    private func endRecorder(_ token: CostToken?) {
        guard let token else { return }
        recorderDepth -= 1
        if token.outer { recorderCosts.record(ms: (ProcessInfo.processInfo.systemUptime-token.start)*1000, detailed: token.detailed) }
    }
    private func stableCandidateID(_ candidate: String?) -> UUID? {
        guard let candidate else { return nil }
        if let existing = candidateIDs[candidate] { return existing }
        if candidateIDs.count >= 2400 { candidateIDs.removeAll(keepingCapacity: true) }
        let id = UUID()
        candidateIDs[candidate] = id
        return id
    }

    private func stableFrameID(_ index: Int?) -> UUID? {
        guard let index else { return nil }
        if let id = frameIDs[index] { return id }
        if frameIDs.count >= 2400 { frameIDs.removeAll(keepingCapacity: true) }
        let id = UUID(); frameIDs[index] = id
        return id
    }

    private func stableUnitID(_ canonicalKey: String?) -> UUID? {
        guard let canonicalKey else { return nil }
        if let id = unitIDs[canonicalKey] { return id }
        if unitIDs.count >= 2400 { unitIDs.removeAll(keepingCapacity: true) }
        let id = UUID(); unitIDs[canonicalKey] = id
        return id
    }

    func trace(_ candidate: String?, stage: String, detail: String, at time: Date = Date(),
               frameIndex: Int? = nil) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard detailedCollection, let candidate else { return }
        // Never export a caller's identifier: historical candidates can encode input text.
        guard let safeID = stableCandidateID(candidate) else { return }
        let stages: Set<String> = [
            "first OCR", "seen", "confirmed", "processing", "speculating", "cache",
            "ready", "enqueued", "superseded", "memory", "cancelled",
            "ocrCorrection", "language", "segmentation", "freshTranslation",
            "translationResult"
        ]
        let safeStage = stages.contains(stage) ? stage : "other"
        appendStructured(candidate: safeID, frameIndex: frameIndex, stage: safeStage,
                         outcome: "observed", reason: safeStage, durationMs: nil, at: time)
        subtitleTraces.append(SubtitleTrace(candidate: safeID.uuidString, stage: safeStage, time: time, detail: detail))
        if subtitleTraces.count > 300 { subtitleTraces.removeFirst(subtitleTraces.count - 300) }
    }


    /// Correlates a processing/rejection decision to the frame and candidate.
    /// Reason codes and stages are hard-coded allowlists; raw OCR/source text,
    /// user-provided candidate identifiers and paths never reach the archive.
    func notePipelineDecision(candidate: String?, frameIndex: Int?,
                              stage: String, reason: String, durationMs: Double? = nil) {
        guard detailedCollection else { return }
        let allowedStages: Set<String> = [
            "frame_arrival", "rotation", "ocr_execution", "duplicate_detection", "ocr_filtering",
            "stability", "text_grouping", "ocr_correction", "language_detection",
            "segmentation", "memory_lookup", "translation", "pip_preparation",
            "pip_enqueue", "model_state", "cancellation"
        ]
        let allowedReasons: Set<String> = [
            "accepted", "completed", "rejected_duplicate", "rejected_recent_fragment",
            "rejected_empty", "rejected_revision", "rejected_unstable",
            "rejected_low_confidence", "rejected_stale", "filtered", "deferred_early_candidate",
            "preserved_confirmed_work", "confirmed_handoff_deferred",
            "adaptive_speculation_backoff", "slow_tail", "handoff_expired", "handoff_replayed", "enqueue_failed",
            "changing_group_preferred", "dominant_group", "queue_replaced",
            "confirmed", "speculative", "ready", "enqueued", "cancelled"
        ]
        guard allowedStages.contains(stage), allowedReasons.contains(reason) else { return }
        let token = beginRecorder(); defer { endRecorder(token) }
        appendStructured(candidate: stableCandidateID(candidate), frameIndex: frameIndex,
                         stage: stage, outcome: reason, reason: reason, durationMs: durationMs)
    }

    /// Bounded, privacy-safe segmentation timing. Source text and cache keys are
    /// never stored in structured events; only opaque candidate IDs are emitted.
    /// Keep state transitions even when there is no OCR candidate. This is how
    /// 'translation suddenly stopped' can be distinguished from missed text.
    func noteRuntimeState(_ reason: String) {
        guard enabled else { return }
        let allowed: Set<String> = [
            "heartbeat_timeout", "capture_connected", "idle_auto_pause", "session_time_limit",
            "app_started", "app_interface_visible", "external_capture_period", "capture_config_changed", "capture_idle", "capture_live",
            "capture_paused", "capture_frozen",
            "thermal_nominal", "thermal_fair", "thermal_serious", "thermal_critical"
        ]
        guard allowed.contains(reason) else { return }
        appendStructured(stage: "runtime_state", outcome: reason, reason: reason,
                         durationMs: nil)
    }

    /// Only count events after the selection is known; never record the label text.
    func noteMovieSelection(groups: Int, filteredSmall: Int, temporalOverride: Bool,
                            confirmed: Bool) {
        guard enabled, confirmed else { return }
        s.movieSelections += 1
        s.movieRejectedSmall += max(0, filteredSmall)
        if temporalOverride {
            s.movieTemporalOverrides += 1
            if detailedCollection {
                appendStructured(stage: "text_grouping", outcome: "changing_group_preferred",
                    reason: "changing_group_preferred", durationMs: nil)
            }
        } else if detailedCollection && groups > 1 && s.movieSelections % 24 == 0 {
            // Sample aggregate selections; avoid flooding the short candidate ring.
            appendStructured(stage: "text_grouping", outcome: "dominant_group",
                reason: "dominant_group", durationMs: nil)
        }
    }

    /// Aggregate-only idle reconciliation performance. Never export source
    /// sentences, translated outputs, memory keys, or device identifiers.
    func noteLegacyBatch(selected: Int, committed: Int, skipped: Int,
                         workers: Int, durationMs: Double) {
        guard enabled else { return }
        s.legacyBatchEntries += max(0, selected)
        s.legacyBatchVerified += max(0, committed)
        s.legacyBatchSkipped += max(0, skipped)
        s.legacyBatchPeakWorkers = max(s.legacyBatchPeakWorkers, max(0, workers))
        if durationMs.isFinite && durationMs >= 0 { s.legacyBatchElapsedMs += durationMs }
        noteModelState("legacy_batch_committed", durationMs: durationMs)
    }

    private var legacyValidationSnapshot: [String: Int] = [:]
    private var legacyValidationPair: [String: String] = [:]
    func recordLegacyValidationSnapshot(inventory: [String: Int], reasons: [String: Int], source: String, target: String) {
        guard enabled else { return }
        let inventoryKeys = ["Pending legacy records": "legacyInventoryPending",
            "Different target language": "legacyInventoryOtherTarget",
            "Different source language": "legacyInventoryOtherSource",
            "Outside 4–240 character range": "legacyInventoryOutsideLength",
            "Scan candidates before safety checks": "legacyInventoryCandidates"]
        let reasonKeys = ["Unreadable key or protected context": "legacySkipKeyContext",
            "Needs cleanup or slang review": "legacySkipCleanup",
            "Needs sentence-unit review": "legacySkipSegmentation",
            "Language model unavailable": "legacySkipModel"]
        legacyValidationSnapshot = [:]
        for (label, key) in inventoryKeys { legacyValidationSnapshot[key] = max(0, inventory[label, default: 0]) }
        for (label, key) in reasonKeys { legacyValidationSnapshot[key] = max(0, reasons[label, default: 0]) }
        legacyValidationPair = ["legacyInventorySource": source, "legacyInventoryTarget": target]
    }

    func noteTemporaryReuse(count: Int = 1) {
        guard enabled else { return }
        temporaryMemoryHits += max(0, count)
    }

    func noteSharedModelUnits(_ count: Int, confirmed: Bool = false) {
        guard enabled else { return }
        sharedModelUnits += max(0, count)
        if confirmed { sharedConfirmedModelUnits += max(0, count) }
    }
    func noteMemoryAwareSpeculationSkip() {
        guard enabled else { return }
        memoryAwareSpeculationSkipped += 1
    }
    func noteRAMCaptionBypass() {
        guard enabled else { return }
        ramCaptionBypasses += 1
    }
    func noteExactCaptionReuse() {
        guard enabled else { return }
        exactCaptionHits += 1
    }
    func noteExactUnitCoalescing(_ count: Int) {
        guard enabled else { return }
        exactUnitsCoalesced += max(0, count)
    }
    func noteSpeculativeUnit(_ outcome: String) {
        guard enabled, ["retained", "reused", "evictedUnused"].contains(outcome) else { return }
        speculativeUnitCounts[outcome, default: 0] += 1
    }
    func recordQueueWait(owner: ModelQueueOwner, durationMs: Double, candidate: String?) {
        guard enabled, durationMs.isFinite, durationMs >= 0 else { return }
        queueWaitSamples[owner, default: []].append(durationMs)
        if queueWaitSamples[owner, default: []].count > 1200 { queueWaitSamples[owner]?.removeFirst() }
        appendStructured(candidate: stableCandidateID(candidate), stage: "queue_wait",
                         outcome: owner.rawValue, reason: owner.rawValue, durationMs: durationMs)
    }

    func noteCompletedWorkRecovery(_ count: Int) {
        guard enabled else { return }
        completedWorkRecoveredUnits += max(0, count)
    }

    func noteModelState(_ reason: String, durationMs: Double? = nil, candidate: String? = nil) {
        guard enabled else { return }
        let allowed: Set<String> = [
            "warmup_started", "warmup_succeeded", "warmup_failed",
            "warmup_model_submitted", "speculative_model_submitted", "confirmed_model_submitted", "model_batch_cancelled",
            "warmup_model_completed", "speculative_model_completed", "confirmed_model_completed",
            "model_session_created", "model_batch_failed", "model_batch_completed",
            "speculative_session_created", "speculative_stop_requested", "speculative_stop_released",
            "warmup_source_unresolved", "warmup_predicted_source", "warmup_preempted",
            "model_batch_first_30s", "legacy_batch_committed", "legacy_idle_started",
            "legacy_idle_completed", "legacy_idle_deferred",
            "legacy_confirmed_after_switch", "legacy_confirmed_no_switch", "legacy_shared_session_used"
        ]
        guard allowed.contains(reason) else { return }
        if modeActiveSystem == "legacy", let candidate {
            if reason == "confirmed_model_submitted" {
                legacyModeContexts[candidate]?.fresh = true
                legacyModeEvent(candidate, reason: "requested_appleDefault")
            }
            if reason == "speculative_model_submitted" { legacyModeEvent(candidate, reason: "requested_appleDefault") }
            if reason == "confirmed_model_completed" { legacyModeEvent(candidate, reason: "recovery_service_ms", duration: durationMs) }
            if reason == "speculative_model_completed" { legacyModeEvent(candidate, reason: "speculative_service_ms", duration: durationMs) }
        }
        if ["model_batch_completed", "confirmed_model_completed", "speculative_model_completed", "speculative_stop_released",
            "legacy_confirmed_after_switch", "legacy_confirmed_no_switch"].contains(reason),
           let durationMs, durationMs.isFinite, durationMs >= 0 {
            modelTimingSamples[reason, default: []].append(durationMs)
            if modelTimingSamples[reason, default: []].count > 1200 {
                modelTimingSamples[reason]?.removeFirst()
            }
        }
        appendStructured(candidate: stableCandidateID(candidate), stage: "model_state", outcome: reason, reason: reason,
            durationMs: durationMs)
    }

    func noteQueueReplacement() {
        guard enabled else { return }
        s.queueReplacements += 1
        if detailedCollection {
            appendStructured(stage: "cancellation", outcome: "queue_replaced",
                reason: "queue_replaced", durationMs: nil)
        }
    }

    func noteThermalState() {
        guard enabled else { return }
        let reason: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: reason = "thermal_nominal"
        case .fair: reason = "thermal_fair"
        case .serious: reason = "thermal_serious"
        case .critical: reason = "thermal_critical"
        @unknown default: return
        }
        guard lastRecordedThermalState != reason else { return }
        lastRecordedThermalState = reason
        noteRuntimeState(reason)
    }

    func noteSegmentation(candidate: String?, reused: Bool, durationMs: Double) {
        let token = beginRecorder(); defer { endRecorder(token) }
        guard detailedCollection else { return }
        let outcome = reused ? "cache_hit" : "computed"
        appendStructured(candidate: stableCandidateID(candidate), stage: "segmentation",
                         outcome: outcome, reason: outcome, durationMs: durationMs)
    }

    private func appendStructured(candidate: UUID? = nil, frameIndex: Int? = nil,
                                  unitKey: String? = nil, stage: String, outcome: String,
                                  reason: String, durationMs: Double?, at time: Date = Date()) {
        let key: String?
        switch stage {
        case "first OCR": key = "firstSeen"
        case "superseded": key = "superseded"
        case "cancelled": key = "cancelled"
        case "cancellation": key = reason == "queue_replaced" ? nil : "cancelled"
        case "runtime_state": key = "runtimeTransition"
        case "model_state": key = reason
        case "stability", "pip_enqueue":
            key = ["handoff_replayed", "handoff_expired", "enqueue_failed"].contains(reason) ? reason : nil
        default: key = nil
        }
        if let key { eventTotals[key, default: 0] += 1 }
        let event = StructuredDiagnosticEvent(id: UUID(), timestamp: time,
            sessionID: diagnosticSessionID, candidateID: candidate,
            frameID: stableFrameID(frameIndex), unitID: stableUnitID(unitKey),
            stage: stage, outcome: outcome, reasonCode: reason,
            durationMs: durationMs.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, privacy: "metadataOnly")
        structuredEvents.append(event)
        if structuredEvents.count > 2400 { structuredEvents.removeFirst(structuredEvents.count - 2400) }
        // Reserve 128 of the 2,400 exported events for sparse early-session
        // evidence, so an initial 90-second stall is not erased by late activity.
        if Date().timeIntervalSince(started) <= 120, openingEvents.count < 128 {
            earlyEventsSeen += 1
            if earlyEventsSeen % 20 == 0 || stage == "runtime_state" ||
               stage == "model_state" {
                openingEvents.append(event)
            }
        }
    }

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

    private struct LegacyModeContext {
        let session: UUID
        var source: String
        let target: String
        let fingerprint: String
        let firstOCR: Double
        var fresh = false
        var speculativeHit = false
        var mismatch = false
    }
    private var legacyModeContexts: [String: LegacyModeContext] = [:]
    private var lastLegacySpeculation: String?

    func registerLegacyModeCaption(session: UUID, caption: String, source: String, target: String,
                                   fingerprint: String, firstOCR: Double, confirmed: Bool) {
        guard enabled, modeActiveSystem == "legacy" else { return }
        if !confirmed { lastLegacySpeculation = fingerprint }
        if legacyModeContexts[caption] == nil {
            if legacyModeContexts.count >= 128 { legacyModeContexts.removeAll() }
            legacyModeContexts[caption] = LegacyModeContext(session: session, source: source, target: target,
                fingerprint: fingerprint, firstOCR: firstOCR, mismatch: confirmed && lastLegacySpeculation != nil && lastLegacySpeculation != fingerprint)
        }
        if confirmed, let previous = lastLegacySpeculation {
            legacyModeContexts[caption]?.mismatch = previous != fingerprint
        }
        legacyModeEvent(caption, reason: confirmed ? "confirmed" : "speculation_admitted")
    }

    private func legacyModeEvent(_ caption: String, reason: String, duration: Double? = nil) {
        guard let context = legacyModeContexts[caption], modeActiveSystem == "legacy" else { return }
        noteModeEvent(session: context.session, caption: caption, revision: 0, source: context.source,
            target: context.target, fingerprint: context.fingerprint, reason: reason,
            firstOCR: context.firstOCR, duration: duration)
    }

    func legacyModeEnqueued(_ caption: String, duration: Double, source: String) {
        legacyModeContexts[caption]?.source = source
        guard let context = legacyModeContexts[caption], modeActiveSystem == "legacy" else { return }
        let reason: String
        if context.fresh { reason = context.mismatch ? "pip_enqueue_legacy_recovery" : "pip_enqueue_confirmed_fresh" }
        else if context.speculativeHit { reason = "pip_enqueue_speculation_match_ready" }
        else { reason = "pip_enqueue_memory_hit" }
        legacyModeEvent(caption, reason: reason, duration: duration)
    }

    var modeActiveSystem = "legacy"
    var modePendingSystem = "legacy"
    var modeMigration = "persisted"
    private var modeTrace: [TranslationModeTrace] = []
    private var openingModeTrace: [TranslationModeTrace] = []
    private var modeTimingSamples: [String: [Double]] = [:]
    private var modeEventCounts: [String: Int] = [:]
    private var initialWarmupTrace: [InitialWarmupEvent] = []

    func noteInitialWarmup(_ observation: InitialWarmupEvent) {
        guard enabled else { return }
        initialWarmupTrace.append(observation)
        if initialWarmupTrace.count > 512 { initialWarmupTrace.removeFirst(initialWarmupTrace.count - 512) }
        let strategy = observation.strategy.rawValue
        let counter = "initial_warmup_\(strategy)_\(observation.phase)"
        modeEventCounts[counter, default: 0] += 1
        if observation.phase == "model_submitted" {
            // A real model request is the common denominator across all three modes.
            // Do not count a policy claim or a skipped preparation as an attempt.
            noteModelState("warmup_started")
            noteModelState("warmup_model_submitted")
        } else if observation.phase == "model_completed" {
            noteModelState("warmup_succeeded")
            noteModelState("warmup_model_completed", durationMs: observation.durationMs)
        } else if observation.phase == "model_batch_failed" || observation.phase == "model_timeout" {
            noteModelState("warmup_failed", durationMs: observation.durationMs)
        }
        if let duration = observation.durationMs, duration.isFinite, duration >= 0 {
            let metric = "initial_warmup_\(strategy)_\(observation.phase)_ms"
            modeTimingSamples[metric, default: []].append(duration)
            if modeTimingSamples[metric, default: []].count > 1200 { modeTimingSamples[metric]?.removeFirst() }
        }
    }

    func noteModeEvent(session: UUID, caption: String, revision: Int, source: String, target: String,
                       fingerprint: String, reason: String, firstOCR: Double, duration: Double?, mode: String? = nil) {
        guard enabled else { return }
        // Caption identifiers are hashed by the producer, never OCR text.
        let safeCaption = SHA256.hash(data: Data(caption.utf8)).map { String(format: "%02x", $0) }.joined()
        let entry = TranslationModeTrace(mode: mode ?? modeActiveSystem, testMode: translationTestMode.rawValue,
            session: session, caption: safeCaption, revision: revision,
            source: source, target: target, fingerprint: fingerprint, reason: reason,
            monotonicTime: ProcessInfo.processInfo.systemUptime, firstOCR: firstOCR,
            durationMs: duration, thermal: ProcessInfo.processInfo.thermalState.rawValue)
        modeTrace.append(entry)
        if modeTrace.count > 2400 {
            let discarded = modeTrace.count - 2400
            modeTrace.removeFirst(discarded)
            modeEventCounts["mode_trace_ring_overwritten", default: 0] += discarded
        }
        // Keep early and late execution boundaries in the same export for comparisons.
        if Date().timeIntervalSince(started) < 120, openingModeTrace.count < 160,
           (reason.hasPrefix("recovery_decision_") || reason.hasPrefix("pip_enqueue_") ||
            reason == "pip_held_unchanged" || reason == "confirmed" ||
            reason == "hybrid_cross_strategy_overlap" || reason == "hybrid_speculation_throttled" ||
            reason == "hybrid_speculation_backend_busy" || reason == "backend_lane_admission_rejected" ||
            reason == "speculative_model_completed" || reason == "confirmed_model_completed") {
            openingModeTrace.append(entry)
        }
        modeEventCounts[reason, default: 0] += 1
        if let duration, duration.isFinite, duration >= 0 {
            modeTimingSamples[reason, default: []].append(duration)
            if modeTimingSamples[reason, default: []].count > 1200 {
                modeTimingSamples[reason]?.removeFirst()
            }
        }
    }

    func sessionSnapshot() -> DiagnosticSessionExport {
        // Explicit allowlist excludes glossary, protected names, source fixes, user text and paths.
        let keys = ["mode", "speed", "stability", "frameRot", "area", "adaptiveOCR", "remember", "privateSession", "diagnosticsEnabled", "detailedCollection",
                    "skipUnchanged", "idleBackoff", "adaptiveConfirmation", "subtitleTracking",
                    "source", "target", "customY0", "customY1", "minTextH", "dropNoise",
                    "boost", "ocrCorrection", "adaptive", "displayPolicy", "minDisplay",
                    "clearHold", "autoClear", "keepWarm", "langLock",
                    "selectiveSpeculation", "speculationConfidence", "confirmationDeadline",
                    "translateAhead", "coolMode", "steadyCaptions", "ocrConfidence", "freshTranslationTest",
                    "adaptiveSpeculation", "protectConfirmedPresentation", "predictiveWarmup",
                    "lowLatencyTranslation", "incrementalBatchRecovery", "directPiPBuffer", "hybridSwitchGuard", "pixelConfirmation", "eventDrivenOCR", "fastOCR", "legacySharedSession",
                    "subtitleAwareChangeDetection", "preserveRelatedMovieGroups",
                    "deduplicateCopies", "contextualLanguage", "languageRecovery",
                    "continuousRotation", "smartCool", "testRunSaving",
                    "diagSamples", "heartbeatInterval", "keepAwake", "suppressOwnInterface", "temporaryMemoryTest",
                    "rapidTextTracking", "joinAdjacentText", "activeTextFocus"]
        var settings: [String: String] = [:]
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) ?? TranslatorEngine.defaults[key] {
                settings[key] = String(describing: value)
            }
        }
        settings["translationTestMode"] = translationTestMode.rawValue
        settings["freshTranslationTest"] = translationTestMode == .freshRequests ? "true" : "false"
        settings["temporaryMemoryTest"] = translationTestMode == .temporaryMemory ? "true" : "false"
        settings["startingRAMEntries"] = String(startingRAMEntries)
        let inherited = PresetRecognitionPolicy.legacyDefaults(
            for: UserDefaults.standard.string(forKey: "mode") ?? "movie")
        for key in [PresetRecognitionPolicy.rapidTextTracking,
                    PresetRecognitionPolicy.joinAdjacentText,
                    PresetRecognitionPolicy.activeTextFocus] {
            let effective = (UserDefaults.standard.object(forKey: key) as? Bool)
                ?? inherited[key] ?? false
            settings["effective" + key.prefix(1).uppercased() + String(key.dropFirst())] = String(effective)
        }
        let thermalState = ProcessInfo.processInfo.thermalState
        switch thermalState {
        case .nominal: settings["thermalState"] = "nominal"
        case .fair: settings["thermalState"] = "fair"
        case .serious: settings["thermalState"] = "serious"
        case .critical: settings["thermalState"] = "critical"
        @unknown default: settings["thermalState"] = "unknown"
        }
        settings["performanceTier"] = ThermalPerformancePolicy.tier(for: thermalState).rawValue
        settings["hotPathAB"] = TranslationHotPathAB.label
        settings["hybridSchedulerAB"] = HybridSchedulingPolicy.buildVariant.rawValue
        settings["reductionReasons"] = captureReductionReasons.joined(separator: "_")
        settings["appRequestedCaptureIntervalMs"] = String(requestedCaptureIntervalMs)
        settings["appRequestedCaptureEdgePx"] = String(requestedCaptureEdgePx)
        settings.merge(legacyValidationPair) { _, new in new }
        var counters = cumulativeCounters()
        counters.merge(legacyValidationSnapshot) { _, new in new }
        counters.merge(Dictionary(uniqueKeysWithValues: memoryOutcomes.map { ($0.key.rawValue, $0.value) })) { _, new in new }
        counters["sessionCacheHits"] = s.cacheHits
        counters["savedMemoryHits"] = s.savedHits
        counters["speculativeHits"] = s.specHits
        counters["uncachedUnits"] = s.cacheMisses
        counters["speculativeModelRequests"] = s.specModelRequests
        counters["supersededSpeculativePipelines"] = s.specDiscarded
        counters["confirmedCandidatePackets"] = s.confirmedCandidatePackets
        counters["deferredEarlyCandidates"] = s.deferredEarlyCandidates
        counters["supersededUnpresentedConfirmed"] = s.supersededUnpresentedConfirmed
        counters["enqueuedCandidateFrames"] = s.enqueuedCandidateFrames
        counters["unchangedSkippedFrames"] = s.unchangedSkipped
        counters["cadenceSkippedFrames"] = s.cadenceSkipped
        counters["pausedSkippedFrames"] = s.pausedSkipped
        counters["emptyReads"] = s.emptyReads
        counters["contrastRetries"] = s.retryCount
        counters["captureFrames"] = s.frames
        counters["capturePasses"] = s.passes
        counters["movieSelections"] = s.movieSelections
        counters["movieTemporalOverrides"] = s.movieTemporalOverrides
        counters["movieRejectedSmall"] = s.movieRejectedSmall
        counters["queueReplacements"] = s.queueReplacements
        counters["visualChanges"] = s.visualChanges
        counters["earlyVisualWakes"] = s.earlyVisualWakes
        counters["largePackets"] = s.largePackets
        counters["packetSendErrors"] = s.packetSendErrors
        counters["pixelConfirmations"] = s.pixelConfirmations
        counters["pixelRejections"] = s.pixelRejections
        counters["watchSkippedOCR"] = s.watchSkippedOCR
        counters["watchTriggeredOCR"] = s.watchTriggeredOCR
        counters["legacyAdaptiveLowYieldSkips"] = s.legacyAdaptiveLowYieldSkips
        counters["legacyAdaptiveSavedSkips"] = s.legacyAdaptiveSavedSkips
        counters["legacyLowConfidenceSkips"] = s.legacyLowConfidenceSkips
        counters["legacyBusySpeculationSkips"] = s.legacyBusySpeculationSkips
        counters["legacyDuplicateSpeculationSkips"] = s.legacyDuplicateSpeculationSkips
        counters["emptyOCRPasses"] = s.emptyOCRPasses
        counters["runCheckpointCaptureMicros"] = checkpointCaptureMicros
        var currentHealth = memoryHealth
        currentHealth.ramEntries = ramEntryCount?() ?? memoryHealth.ramEntries
        return DiagnosticSessionExport(translationModes: TranslationModeReport(warmups: initialWarmupTrace, active: modeActiveSystem,
            pending: modePendingSystem, referenceSHA: TranslationSystem.referenceSHA,
            migration: modeMigration, events: exportModeEventWindow(),
            distributions: modeTimingSamples.mapValues(DiagnosticDistribution.init),
            counters: modeEventCounts), id: diagnosticSessionID, startedAt: started, endedAt: Date(),
            appVersion: AppVersion.full, systemVersion: UIDevice.current.systemVersion,
            hardwareModel: Self.hardwareModelCode, settings: settings, health: currentHealth, counters: counters,
            distributions: ["memoryLookupMs": DiagnosticDistribution(lookupSamples), "memoryWriteMs": DiagnosticDistribution(writeSamples),
                "ocrMs": DiagnosticDistribution(ocr.map { $0.v }), "translationMs": DiagnosticDistribution(translate.map { $0.v }),
                "enqueueLatencyMs": DiagnosticDistribution(latency.map { $0.v }),
                "finalOCRMs": DiagnosticDistribution(pipeline.map { $0.stages.recognition }),
                "transportMs": DiagnosticDistribution(transport.map { $0.v }),
                "confirmationMs": DiagnosticDistribution(pipeline.map { $0.stages.confirmation }),
                "deliveryFilteringMs": DiagnosticDistribution(pipeline.map { $0.stages.delivery }),
                "queueMs": DiagnosticDistribution(pipeline.map { $0.stages.queue }),
                "speculativeStopReleaseMs": DiagnosticDistribution(modelTimingSamples["speculative_stop_released", default: []]),
                "queueBehindSpeculationMs": DiagnosticDistribution(queueWaitSamples[.speculative, default: []]),
                "queueBehindConfirmedMs": DiagnosticDistribution(queueWaitSamples[.confirmed, default: []]),
                "queueSchedulingMs": DiagnosticDistribution(queueWaitSamples[.scheduling, default: []]),
                "processingMs": DiagnosticDistribution(pipeline.map { $0.stages.translation }),
                "displayHoldMs": DiagnosticDistribution(pipeline.map { $0.stages.displayHold }),
                "renderingMs": DiagnosticDistribution(pipeline.map { $0.stages.rendering }),
                "speculativeModelMs": DiagnosticDistribution(modelTimingSamples["speculative_model_completed", default: []]),
                "confirmedModelMs": DiagnosticDistribution(modelTimingSamples["confirmed_model_completed", default: []]),
                "modelBatchMs": DiagnosticDistribution(modelTimingSamples["model_batch_completed", default: []]),
                "legacyConfirmedAfterSessionSwitchMs": DiagnosticDistribution(modelTimingSamples["legacy_confirmed_after_switch", default: []]),
                "legacyConfirmedNoSwitchMs": DiagnosticDistribution(modelTimingSamples["legacy_confirmed_no_switch", default: []]),
                "modeAvailabilityCheckMs": DiagnosticDistribution(modeTimingSamples["backend_availability_ms", default: []]),
                "modeTaskDispatchMs": DiagnosticDistribution(modeTimingSamples["backend_task_dispatch_ms", default: []]),
                "modeSpeculativeQueueMs": DiagnosticDistribution(modeTimingSamples["speculative_queue_ms", default: []]),
                "modeRecoveryQueueMs": DiagnosticDistribution(modeTimingSamples["recovery_queue_ms", default: []]),
                "modeBackendLaneWaitMs": DiagnosticDistribution(modeTimingSamples["backend_lane_wait_ms", default: []]),
                "modeSessionAgeMs": DiagnosticDistribution(modeTimingSamples["backend_session_age_ms", default: []]),
                "modeSessionCompletedCalls": DiagnosticDistribution(modeTimingSamples["backend_session_reuse_count", default: []]),
                "hybridDefaultWarmupMs": DiagnosticDistribution(modeTimingSamples["initial_warmup_appleDefault_model_completed_ms", default: []]),
                "hybridLowLatencyWarmupMs": DiagnosticDistribution(modeTimingSamples["initial_warmup_lowLatency_model_completed_ms", default: []]),
                "hybridOverlappedRecoveryMs": DiagnosticDistribution(modeTimingSamples["hybrid_overlapped_recovery_ms", default: []]),
                "hybridMeasuredOverlapMs": DiagnosticDistribution(modeTimingSamples["hybrid_simultaneous_model_overlap_ms", default: []]),
                "modeCancellationReleaseMs": DiagnosticDistribution(modeTimingSamples["cancelled_call_returned", default: []]),
                "modePlanBuiltMs": DiagnosticDistribution(modeTimingSamples["mode_plan_built_ms", default: []]),
                "modePlanReusedMs": DiagnosticDistribution(modeTimingSamples["mode_plan_reused_ms", default: []]),
                "modeCommitToPiPMs": DiagnosticDistribution(modeTimingSamples["mode_commit_to_pip_ms", default: []]),
                "modeConfirmationToPiPMs": DiagnosticDistribution(modeTimingSamples["mode_confirmation_to_pip_ms", default: []]),
                "modeReadyToPiPMs": DiagnosticDistribution(modeTimingSamples["mode_ready_to_pip_ms", default: []]),
                "hybridMatchingWaitMs": DiagnosticDistribution(modeTimingSamples["hybrid_matching_wait_ms", default: []]),
                "hybridUnsubmittedHedgeMs": DiagnosticDistribution(modeTimingSamples["hybrid_unsubmitted_hedge_ms", default: []]),
                "hybridPreviousDefaultExitGapMs": DiagnosticDistribution(modeTimingSamples["hybrid_previous_default_exit_gap_ms", default: []]),
                "hybridPostDefaultRecoveryServiceMs": DiagnosticDistribution(modeTimingSamples["hybrid_recovery_post_default_service_ms", default: []]),
                "hybridNoOverlapRecoveryServiceMs": DiagnosticDistribution(modeTimingSamples["hybrid_recovery_no_recent_overlap_service_ms", default: []]),
                "hybridUnexplainedSlowRecoveryMs": DiagnosticDistribution(modeTimingSamples["hybrid_unexplained_slow_recovery_ms", default: []])],
            events: exportEventWindow(),
            intervals: diagnosticIntervals(at: Date()),
            oneSecondIntervals: detailedCollection ? recentIntervals(at: Date(), period: 1) : nil,
            fiveSecondIntervals: diagnosticIntervals(at: Date(), period: 5),
            measurementBoundary: "First OCR sighting to PiP sample-buffer enqueue; physical display unmeasured. translationMs measures Legacy pipeline processing or completed Hybrid/Low Latency backend model inference, not memory-only selection. Latest bounded samples; stages can overlap.",
            textCapture: false)
    }

    private func exportModeEventWindow() -> [TranslationModeTrace] {
        let recent = Array(modeTrace.suffix(2240))
        var identities = Set<String>()
        let merged = openingModeTrace + recent
        return merged.filter { event in
            let identity = event.session.uuidString + event.caption +
                String(event.revision) + event.reason + String(event.monotonicTime)
            return identities.insert(identity).inserted
        }.sorted { $0.monotonicTime < $1.monotonicTime }
    }

    private func exportEventWindow() -> [StructuredDiagnosticEvent] {
        let recent = Array(structuredEvents.suffix(2272))
        let existing = Set(recent.map(\.id))
        let early = openingEvents.filter { !existing.contains($0.id) }
        return Array((early + recent).suffix(2400)).sorted { $0.timestamp < $1.timestamp }
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

    // MARK: Test Runs (v2.0.0 build 84, spec §11)

    /// "automatic" (default) | "manual" | "off". Replaces persistDiagnosticSessions.
    var runSavingMode: String {
        let value = UserDefaults.standard.string(forKey: "testRunSaving") ?? "automatic"
        return ["automatic", "manual", "off"].contains(value) ? value : "automatic"
    }
    private var privateSessionOn: Bool { UserDefaults.standard.bool(forKey: "privateSession") }

    var currentTestID: UUID {
        if let text = UserDefaults.standard.string(forKey: "testRunCurrentID"), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: "testRunCurrentID")
        return id
    }
    var currentTestName: String {
        if let name = UserDefaults.standard.string(forKey: "testRunCurrentName"), !name.isEmpty { return name }
        return nextTestName()
    }
    private func nextTestName() -> String {
        let existing = Set(testRuns.filter { $0.appVersion.contains(AppVersion.version) }.map(\.testID)).count
        return "\(AppVersion.version) test \(existing + 1)"
    }
    func startNewTest(named name: String? = nil) {
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: "testRunCurrentID")
        let clean = TestRunMeta.cleanLabel(name ?? "")
        UserDefaults.standard.set(clean.isEmpty ? nextTestName() : clean, forKey: "testRunCurrentName")
        objectWillChange.send()
    }
    func renameCurrentTest(_ name: String) {
        let clean = TestRunMeta.cleanLabel(name)
        guard !clean.isEmpty else { return }
        UserDefaults.standard.set(clean, forKey: "testRunCurrentName")
        let id = currentTestID
        Task { await runStore.renameTest(testID: id, name: clean); await refreshRuns() }
    }

    /// Capture connected: a run starts. Keeps the opening warm-up trace already collected for this broadcast.
    func beginRun() {
        if activeRun != nil { endRun(reason: "newRunStarted") }
        started = Date()
        startingRAMEntries = ramEntryCount?() ?? 0
        startRunState()
    }
    private func startRunState() {
        activeRun = ActiveRun(id: diagnosticSessionID, startedAt: started, mode: modeActiveSystem,
                              startingRAMEntries: startingRAMEntries, lastCheckpointAt: Date())
    }

    /// Why a run would not be saved right now, or nil. Fixed reason codes plus a human detail.
    private func skipReason(for meta: TestRunMeta) -> (TestRunSkipReason, String)? {
        TestRunPolicy.skipReason(meta: meta, privateSession: privateSessionOn, savingMode: runSavingMode,
                                 diagnosticsEnabled: enabled)
    }

    /// The run is over (stop packet, heartbeat timeout, new session, mode change, reset, new run).
    /// The snapshot is taken here, synchronously; encoding and writing happen on the store actor.
    func endRun(reason: String) {
        guard let run = activeRun else { return }
        activeRun = nil
        unsavedEndedRun = nil
        let snapshot = sessionSnapshot()
        var changes = run.modeChanges
        if modeActiveSystem != run.mode { changes.append(modeActiveSystem) }
        let meta = TestRunMeta.make(snapshot: snapshot, testID: currentTestID, testName: currentTestName,
            endReason: reason, startingRAMEntries: startingRAMEntries, modeChanges: changes, completeness: "complete")
        clearCollection()
        let store = runStore
        if let (code, detail) = skipReason(for: meta) {
            lastRunBanner = RunBanner(result: .skipped(code, detail: detail), mode: meta.mode, seconds: meta.durationSeconds)
            Task { await store.discardCheckpoint(id: meta.id) }
            return
        }
        if runSavingMode == "manual" {
            unsavedEndedRun = (meta, snapshot)
            lastRunBanner = RunBanner(result: .skipped(.savingOff, detail: "Manual mode – tap Save run to keep it"),
                                      mode: meta.mode, seconds: meta.durationSeconds)
            return
        }
        Task {
            let result = await store.save(meta: meta, snapshot: snapshot)
            lastRunBanner = RunBanner(result: result, mode: meta.mode, seconds: meta.durationSeconds)
            await refreshRuns()
        }
    }

    /// Save run: the current run (as a checkpoint, the run continues) or the last ended run that was not saved.
    @discardableResult
    func saveRunNow() async -> TestRunSaveResult {
        let result: TestRunSaveResult
        let mode: String, seconds: Double
        if let run = activeRun {
            let snapshot = sessionSnapshot()
            var changes = run.modeChanges
            if modeActiveSystem != run.mode { changes.append(modeActiveSystem) }
            let meta = TestRunMeta.make(snapshot: snapshot, testID: currentTestID, testName: currentTestName,
                endReason: "savedWhileRecording", startingRAMEntries: startingRAMEntries, modeChanges: changes, completeness: "complete")
            mode = meta.mode; seconds = meta.durationSeconds
            if let (code, detail) = skipReason(for: meta) { result = .skipped(code, detail: detail) }
            else { result = await runStore.save(meta: meta, snapshot: snapshot) }
        } else if let pending = unsavedEndedRun {
            mode = pending.meta.mode; seconds = pending.meta.durationSeconds
            if privateSessionOn { result = .skipped(.privateSession, detail: "Private session – runs are not saved") }
            else if runSavingMode == "off" { result = .skipped(.savingOff, detail: "Saving test runs is off") }
            else {
                result = await runStore.save(meta: pending.meta, snapshot: pending.snapshot)
                if case .saved = result { unsavedEndedRun = nil }
            }
        } else {
            mode = modeActiveSystem; seconds = 0
            result = .skipped(.noData, detail: "No run to save")
        }
        lastRunBanner = RunBanner(result: result, mode: mode, seconds: seconds)
        await refreshRuns()
        return result
    }

    /// Crash-safety checkpoint. Only the snapshot copy runs on the main actor (its cost is recorded);
    /// redaction, encoding, compression and the write run on the store actor.
    func checkpointRun() {
        guard let run = activeRun, !checkpointInFlight, runSavingMode != "off", !privateSessionOn, enabled else { return }
        let begin = ProcessInfo.processInfo.systemUptime
        let snapshot = sessionSnapshot()
        let spent = ProcessInfo.processInfo.systemUptime - begin
        lastCheckpointCaptureMs = spent * 1000
        checkpointCaptureMicros = Int(spent * 1_000_000)
        var changes = run.modeChanges
        if modeActiveSystem != run.mode { changes.append(modeActiveSystem) }
        let meta = TestRunMeta.make(snapshot: snapshot, testID: currentTestID, testName: currentTestName,
            endReason: "recovered", startingRAMEntries: startingRAMEntries, modeChanges: changes, completeness: "recovered")
        activeRun?.lastCheckpointAt = Date()
        checkpointInFlight = true
        let store = runStore
        Task { _ = await store.checkpoint(meta: meta, snapshot: snapshot); checkpointInFlight = false }
    }

    func refreshRuns() async {
        let index = await runStore.index()
        testRuns = index.runs.sorted { $0.endedAt > $1.endedAt }
        runPruneNote = index.pruneNote
    }

    /// Launch: leftover checkpoints become runs marked "Recovered (incomplete)".
    func recoverRuns() async {
        let recovered = await runStore.recover()
        await refreshRuns()
        if let last = recovered.last {
            lastRunBanner = RunBanner(result: .saved(last), mode: last.mode, seconds: last.durationSeconds)
        }
    }

    /// Build 84, once: rows of the old diagnostic_sessions table become runs marked
    /// "Imported (mode may be mixed)". The table and its rows are left in place and never written again.
    func migrateOldSessions() async {
        guard let store = memoryStore else { return }
        if await runStore.migrationDone { return }
        do {
            let payloads = try await store.loadDiagnosticSessions()
            let imported = await runStore.migrate(payloads: payloads)
            if imported > 0 { archiveStatus = "Imported \(imported) earlier diagnostic session(s) as test runs" }
            await refreshRuns()
        } catch { /* marker stays unset; retried at the next launch */ }
    }

    func deleteRuns(_ ids: [UUID]) async { await runStore.delete(ids: ids); await refreshRuns() }
    func deleteAllUnpinnedRuns() async { _ = await runStore.deleteAllUnpinned(); await refreshRuns() }
    func setRunPinned(_ id: UUID, _ pinned: Bool) async { await runStore.setPinned(id: id, pinned); await refreshRuns() }
    func renameRun(_ id: UUID, label: String) async { await runStore.rename(id: id, label: label); await refreshRuns() }
    func moveRun(_ id: UUID, toTest testID: UUID, name: String) async { await runStore.move(id: id, toTest: testID, name: name); await refreshRuns() }
    func clearRunPruneNote() async { await runStore.clearPruneNote(); await refreshRuns() }

    /// The newest saved run of each translation system in the current test, newest first.
    /// Falls back to all saved runs when the current test has none.
    var defaultReportSelection: [UUID] {
        let current = testRuns.filter { $0.testID == currentTestID }
        let pool = current.isEmpty ? testRuns : current
        var seen = Set<String>(), ids: [UUID] = []
        for run in pool.sorted(by: { $0.endedAt > $1.endedAt }) where seen.insert(run.mode).inserted { ids.append(run.id) }
        return ids
    }

    /// One Markdown file for up to six saved runs.
    func exportTestReport(ids: [UUID]) async {
        guard !exportInProgress else { return }
        let ordered = Array(ids.prefix(CombinedDiagnosticReport.maximumSessions))
        let snapshots = await runStore.loadSnapshots(ids: ordered)
        guard !snapshots.isEmpty else { archiveStatus = "Select at least one saved run"; return }
        exportInProgress = true
        defer { exportInProgress = false }
        do {
            let url = try await exportWriter.exportCombinedReport(snapshots,
                version: AppVersion.version, build: AppVersion.build,
                runs: testRuns.filter { ordered.contains($0.id) }.map(\.reportInfo))
            Sharer.present([url])
            archiveStatus = "Test report ready"
        } catch {
            archiveStatus = "Test report export failed; no file was shared"
        }
    }

    @Published var sourceUsage = SourceLanguageUsage()
    @Published private(set) var executionPhase = "starting"
    private var lastPacketAt: Date?
    private var lastDeviceSampleAt: Date?
    @Published private var speakerSession = SpeakerSession()
    var names: [String] {
        guard enabled, !UserDefaults.standard.bool(forKey: "privateSession"),
              (UserDefaults.standard.object(forKey: "showSessionSpeakers") as? Bool) ?? true else { return [] }
        return speakerSession.names
    }
    var enabled: Bool { (UserDefaults.standard.object(forKey: "diagnosticsEnabled") as? Bool) ?? true }
    var detailedCollection: Bool {
        guard ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return false }
        return RuntimePolicy(coolMode: false, diagnosticsEnabled: enabled,
                      detailedRequested: UserDefaults.standard.bool(forKey: "detailedCollection")).detailedDiagnostics
    }

    func collectionChanged() {
        // A new collection interval must never be mistaken for continuous history.
        let costs = recorderCosts
        reset()
        recorderCosts = costs
        UIDevice.current.isBatteryMonitoringEnabled = detailedCollection
    }

    func clearSpeakers() { speakerSession = SpeakerSession() }
    @Published private(set) var started = Date()
    private var lastFrames = 0
    private var lastFrameTime = Date()
    private var tickN = 0
    private var lastState: EngineState?

    init() { UIDevice.current.isBatteryMonitoringEnabled = detailedCollection }

    private func add(_ kp: ReferenceWritableKeyPath<Diagnostics, [Sample]>, _ v: Double, cap: Int = 600) {
        guard detailedCollection else { return }
        self[keyPath: kp].append(Sample(t: Date(), v: v))
        let limit = max(300, min(1200, (UserDefaults.standard.object(forKey: "diagSamples") as? Int) ?? 600))
        let extra = self[keyPath: kp].count - limit
        if extra > 0 { self[keyPath: kp].removeFirst(extra) }
    }

    // MARK: Events
    func event(_ kind: EventKind, _ text: String, detail: String? = nil) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard detailedCollection else { return }
        events.append(TimelineEvent(time: Date(), kind: kind, text: text, detail: detail))
        let limit = max(300, min(1200, (UserDefaults.standard.object(forKey: "diagSamples") as? Int) ?? 600))
        if events.count > limit { events.removeFirst(events.count - limit) }
    }

    /// Plain log line; the category is worked out from the wording.
    func log(_ t: String) {
        guard enabled else { return }
        let k = EventKind.classify(t)
        if k == .rotation && t.lowercased().contains("trying") { s.rotationTries += 1 }
        event(k, t)
    }

    func learn(_ name: String) {
        var next = speakerSession
        next.record(name, enabled: enabled && ((UserDefaults.standard.object(forKey: "showSessionSpeakers") as? Bool) ?? true),
                    privateSession: UserDefaults.standard.bool(forKey: "privateSession"))
        if next.names != speakerSession.names { speakerSession = next }
    }

    func recordSourceLanguage(_ code: String, origin: SourceLanguageOrigin) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard enabled else { return }
        sourceUsage.record(code, origin: origin)
        s.sourceUsed = code
        s.sourceOrigin = origin.title
        if origin != .selected { s.detected = code } else { s.languageConfidence = 0; s.languageContextUsed = false }
    }

    func noteExecutionPhase(_ phase: String, pipActive: Bool) {
        guard enabled, executionPhase != phase else { return }
        executionPhase = phase
        event(.state, "App entered \(phase) (PiP \(pipActive ? "active" : "inactive"))")
    }

    func recordTranslate(ms: Double, sentences: Int, from: String, to: String, preview: String) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard detailedCollection else { return }
        add(\.translate, ms)
        event(.translation, "Translated \(sentences) sentence\(sentences == 1 ? "" : "s") \(from) → \(to) in \(Int(ms)) ms",
              detail: UserDefaults.standard.bool(forKey: "diagIncludeText") && !UserDefaults.standard.bool(forKey: "privateSession") ? String(preview.prefix(90)) : nil)
    }

    /// Completed inference, not the elapsed time for a memory-only caption.
    /// This feeds the same live timing series as the Legacy pipeline.
    func recordModeModel(ms: Double, system: TranslationSystem) {
        guard enabled, ms.isFinite, ms >= 0 else { return }
        add(\.translate, ms)
        event(.translation, "Model completed in \(Int(ms)) ms · \(system.title)")
    }

    /// An actual selected caption can be entirely memory-served; never create
    /// a fictitious model-duration sample for those translations.
    func recordModeSelection(sentences: Int, source: String, target: String) {
        guard enabled else { return }
        event(.translation, "Translated \(sentences) sentence\(sentences == 1 ? "" : "s") \(source) → \(target)")
    }

    func recordLatency(ms: Double) { add(\.latency, ms) }

    func recordPipeline(_ stages: LatencyBreakdown) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard detailedCollection else { return }
        pipeline.append(PipelineMeasurement(date: Date(), stages: stages))
        let limit = max(300, min(1200, (UserDefaults.standard.object(forKey: "diagSamples") as? Int) ?? 600))
        if pipeline.count > limit { pipeline.removeFirst(pipeline.count - limit) }
    }

    /// A reset during a run ends that run (reason diagnosticsReset) and starts a new one.
    func reset() {
        let wasRecording = activeRun != nil
        if wasRecording { endRun(reason: "diagnosticsReset") } else { clearCollection() }
        if wasRecording { startRunState() }
    }

    private func clearCollection() {
        modeTrace.removeAll(); openingModeTrace.removeAll()
        modeTimingSamples.removeAll(); modeEventCounts.removeAll()
        initialWarmupTrace.removeAll(); legacyModeContexts.removeAll(); lastLegacySpeculation = nil
        diagnosticSessionID = UUID(); candidateIDs = [:]; frameIDs = [:]; unitIDs = [:]; structuredEvents = []
        legacyValidationSnapshot = [:]; legacyValidationPair = [:]
        eventTotals = [:]; intervalHistory = []; intervalStart = Date()
        oneSecondHistory = []; oneSecondStart = Date()
        fiveSecondHistory = []; fiveSecondStart = Date()
        openingEvents = []; earlyEventsSeen = 0
        intervalBaseline = [:]; oneSecondBaseline = [:]; fiveSecondBaseline = [:]
        lastCaptureConnected = false
        lastRecordedThermalState = nil
        memoryOutcomes = [:]; lookupSamples = []; writeSamples = []
        modelTimingSamples = [:]; completedWorkRecoveredUnits = 0
        sharedModelUnits = 0; sharedConfirmedModelUnits = 0; memoryAwareSpeculationSkipped = 0; ramCaptionBypasses = 0; exactCaptionHits = 0; exactUnitsCoalesced = 0
        speculativeUnitCounts = [:]; queueWaitSamples = [:]
        temporaryMemoryHits = 0; startingRAMEntries = ramEntryCount?() ?? 0
        started = Date()
        subtitleTraces = []; recorderCosts = RecorderCosts()
        lastFrames = 0; lastFrameTime = Date(); tickN = 0
        lastPacketAt = nil; lastDeviceSampleAt = nil
        s = Stats()
        pipeline = []
        ocr = []; translate = []; latency = []; transport = []; fps = []; lineCounts = []
        extMem = []; appMem = []; thermal = []; battery = []; cacheRate = []
        events = []; spans = []; sourceUsage = SourceLanguageUsage(); clearSpeakers()
        lastState = nil
    }

    // MARK: Packets from the extension
    func onPacket(_ p: Packet, transport t: Double?) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard enabled else { return }
        lastPacketAt = Date()
        s.recognitionReason = p.recognitionReason ?? "legacy"
        s.confirmationReason = p.confirmationReason ?? "legacy"
        if !p.lines.isEmpty { s.ocrConfidence = p.lines.map { $0.confidence ?? 0 }.min() ?? 0 }
        s.unchangedSkipped = p.unchangedSkipped ?? s.unchangedSkipped
        s.cadenceSkipped = p.cadenceSkipped ?? s.cadenceSkipped
        s.pausedSkipped = p.pausedSkipped ?? s.pausedSkipped
        s.emptyReads = p.emptyReads ?? s.emptyReads
        s.retryCount = p.retryCount ?? s.retryCount
        s.visualChanges = p.visualChanges ?? s.visualChanges
        s.earlyVisualWakes = p.earlyVisualWakes ?? s.earlyVisualWakes
        s.largePackets = p.largePackets ?? s.largePackets
        s.packetSendErrors = p.sendErrors ?? s.packetSendErrors
        s.pixelConfirmations = p.pixelConfirmations ?? s.pixelConfirmations
        s.pixelRejections = p.pixelRejections ?? s.pixelRejections
        s.watchSkippedOCR = p.watchSkippedOCR ?? s.watchSkippedOCR
        s.watchTriggeredOCR = p.watchTriggeredOCR ?? s.watchTriggeredOCR
        s.emptyOCRPasses = p.totalEmptyOCRPasses ?? s.emptyOCRPasses
        s.effectiveOCRIntervalMs = p.effectiveOCRIntervalMs ?? s.effectiveOCRIntervalMs
        if let first = p.firstSeenAt, let visual = p.lastVisualChangeAt,
           visual > 0, first >= visual, first - visual < 6 {
            s.firstSightVisualChangeLagMs = (first - visual) * 1000
        }
        s.packets += 1
        if p.kind == "ocr" {
            s.ocrPackets += 1
            add(\.lineCounts, Double(p.lines.count))
            // These are extension-reported OCR packet timings, not inferred
            // physical screen-display latency or unobserved pre-OCR stages.
            if detailedCollection, let ocrDuration = p.ocrMs, ocrDuration >= 0 {
                appendStructured(candidate: stableCandidateID(p.candidateID),
                    frameIndex: p.frames, stage: "ocr_execution",
                    outcome: "completed", reason: "completed", durationMs: ocrDuration)
            }
            if detailedCollection, p.orient != nil {
                appendStructured(candidate: stableCandidateID(p.candidateID),
                    frameIndex: p.frames, stage: "rotation",
                    outcome: "accepted", reason: "accepted", durationMs: nil)
            }
        } else if p.kind == "clear" {
            s.clearPackets += 1
        }
        let now = Date()
        let dt = now.timeIntervalSince(lastFrameTime)
        if p.frames < lastFrames {
            lastFrames = p.frames; lastFrameTime = now
        } else if dt >= 1 {
            s.fps = Double(p.frames - lastFrames) / dt
            add(\.fps, s.fps)
            lastFrames = p.frames; lastFrameTime = now
        }
        s.frames = p.frames
        if let m = p.memFreeMB { s.extFreeMB = m; if m > 0 { s.minExtFreeMB = Swift.min(s.minExtFreeMB, m) } }
        if let o = p.ocrMs, o > 0, p.kind != "ping" { add(\.ocr, o) }
        if let v = p.passes { s.passes = v }
        if let v = p.skipped { s.skippedFrames = v }
        if let w = p.bufW, let h = p.bufH { s.bufferSize = "\(w)×\(h)" }
        if let w = p.cropW, let h = p.cropH { s.cropSize = "\(w)×\(h)" }
        if let o = p.orient { s.orientation = Diagnostics.orientationName(o) }
        if let t, p.kind != "ping" { add(\.transport, t) }
    }

    // MARK: Once a second
    func tick(alive: Bool, paused: Bool, frozen: Bool) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard enabled else { return }
        tickN += 1
        if let run = activeRun, Date().timeIntervalSince(run.lastCheckpointAt) >= 60 { checkpointRun() }
        let st: EngineState = !alive ? .idle : (paused ? .paused : (frozen ? .frozen : .live))
        if st != lastState {
            if let i = spans.indices.last { spans[i].end = Date() }
            if detailedCollection { spans.append(StateSpan(start: Date(), end: nil, state: st)) }
            if spans.count > 300 { spans.removeFirst() }
            if let prev = lastState, prev != .idle, st == .idle { s.captureDrops += 1 }
            event(.state, "Now \(st.title)")
            switch st {
            case .idle: noteRuntimeState("capture_idle")
            case .live: noteRuntimeState("capture_live")
            case .paused: noteRuntimeState("capture_paused")
            case .frozen: noteRuntimeState("capture_frozen")
            }
            lastState = st
        }
        lastCaptureConnected = alive
        let now = Date()
        // Fine-grained data is bounded: latest 5 minutes at 1s, latest
        // 15 minutes at 5s; 15s buckets remain for long sessions/old readers.
        if detailedCollection && now.timeIntervalSince(oneSecondStart) >= 1 {
            if let completed = makeInterval(at: now, start: oneSecondStart, baseline: oneSecondBaseline) {
                oneSecondHistory.append(completed)
                if oneSecondHistory.count > 300 {
                    oneSecondHistory.removeFirst(oneSecondHistory.count - 300)
                }
            }
            oneSecondStart = now
            oneSecondBaseline = cumulativeCounters()
        } else if !detailedCollection {
            oneSecondHistory = []
            oneSecondStart = now
            oneSecondBaseline = cumulativeCounters()
        }
        if now.timeIntervalSince(fiveSecondStart) >= 5 {
            if let completed = makeInterval(at: now, start: fiveSecondStart, baseline: fiveSecondBaseline) {
                fiveSecondHistory.append(completed)
                if fiveSecondHistory.count > 180 {
                    fiveSecondHistory.removeFirst(fiveSecondHistory.count - 180)
                }
            }
            fiveSecondStart = now
            fiveSecondBaseline = cumulativeCounters()
        }
        if now.timeIntervalSince(intervalStart) >= 15 {
            if let completed = makeInterval(at: now, start: intervalStart, baseline: intervalBaseline) {
                intervalHistory.append(completed)
                if intervalHistory.count > 960 { intervalHistory.removeFirst(intervalHistory.count - 960) }
            }
            intervalStart = now
            intervalBaseline = cumulativeCounters()
        }
        if detailedCollection && tickN % 2 == 0 { sampleDevice(alive: alive) }
    }

    private func cumulativeCounters() -> [String: Int] {
        [
            "captureFrames": s.frames, "capturePasses": s.passes,
            "capturePackets": s.packets, "ocrPackets": s.ocrPackets,
            "candidateConfirmed": s.confirmedCandidatePackets,
            "candidateEnqueued": s.enqueuedCandidateFrames,
            "candidateSuperseded": eventTotals["superseded", default: 0],
            "candidateCancelled": eventTotals["cancelled", default: 0],
            "candidateFirstSeen": eventTotals["firstSeen", default: 0],
            "speculativeRequests": s.specModelRequests,
            "specPreemptionRequested": s.specPreemptionRequested,
            "specMatchingConfirmation": s.specMatchingConfirmation,
            "specRetainedUnits": s.specRetainedUnits,
            "completedConfirmedUnitsRetained": completedWorkRecoveredUnits,
            "temporaryMemoryHits": temporaryMemoryHits,
            "exactCaptionHits": exactCaptionHits,
            "ramCaptionBypasses": ramCaptionBypasses,
            "memoryAwareSpeculationSkipped": memoryAwareSpeculationSkipped,
            "sharedInFlightUnits": sharedModelUnits,
            "sharedConfirmedInFlightUnits": sharedConfirmedModelUnits,
            "exactUnitsCoalesced": exactUnitsCoalesced,
            "speculativeUnitsRetained": speculativeUnitCounts["retained", default: 0],
            "speculativeUnitsReused": speculativeUnitCounts["reused", default: 0],
            "speculativeUnitsEvictedUnused": speculativeUnitCounts["evictedUnused", default: 0],
            "uncachedUnits": s.cacheMisses,
            "bypassedLookups": memoryOutcomes[.bypassed, default: 0],
            "temporaryMemoryMisses": memoryOutcomes[.temporaryMiss, default: 0],
            "speculativeDiscarded": s.specDiscarded,
            "legacyVerified": memoryHealth.legacyValidated,
            "legacySuperseded": memoryHealth.legacySuperseded,
            "legacyOCRSuggestions": memoryHealth.suggestedOCRMatches,
            "legacyFragmentSuggestions": memoryHealth.suggestedFragmentMatches,
            "legacyIdleStarted": eventTotals["legacy_idle_started", default: 0],
            "legacyIdleCompleted": eventTotals["legacy_idle_completed", default: 0],
            "ramHits": memoryOutcomes[.ramHit, default: 0],
            "persistentHits": memoryOutcomes[.persistentHit, default: 0],
            "speculativeHits": memoryOutcomes[.speculativeHit, default: 0],
            "lookupMisses": memoryOutcomes[.miss, default: 0],
            "unchangedSkips": s.unchangedSkipped, "cadenceSkips": s.cadenceSkipped,
            "pausedSkips": s.pausedSkipped, "emptyOCRPasses": s.emptyOCRPasses,
            "contrastRetries": s.retryCount, "movieSelections": s.movieSelections,
            "movieTemporalOverrides": s.movieTemporalOverrides,
            "movieRejectedSmall": s.movieRejectedSmall,
            "queueReplacements": s.queueReplacements,
            "earlyDeferred": s.deferredEarlyCandidates,
            "handoffDeferred": s.confirmedHandoffDeferred,
            "adaptiveSpeculationSkipped": s.adaptiveSpeculationSkipped,
            "legacyAdaptiveLowYieldSkips": s.legacyAdaptiveLowYieldSkips,
            "legacyAdaptiveSavedSkips": s.legacyAdaptiveSavedSkips,
            "legacyLowConfidenceSkips": s.legacyLowConfidenceSkips,
            "legacyBusySpeculationSkips": s.legacyBusySpeculationSkips,
            "legacyDuplicateSpeculationSkips": s.legacyDuplicateSpeculationSkips,
            "slowTailEnqueues": s.slowTailEnqueues,
            "legacyBatchEntries": s.legacyBatchEntries,
            "legacyBatchVerified": s.legacyBatchVerified,
            "legacyBatchSkipped": s.legacyBatchSkipped,
            "unpresentedConfirmed": s.supersededUnpresentedConfirmed,
            "modelBatches": s.batches, "modelFailures": s.failures,
            "warmupAttempts": eventTotals["warmup_started", default: 0],
            "warmupSucceeded": eventTotals["warmup_succeeded", default: 0],
            "warmupPredicted": eventTotals["warmup_predicted_source", default: 0],
            // Legacy alias counts first-30s completions, not proven cold loads.
            "coldModelBatches": eventTotals["model_batch_first_30s", default: 0],
            "first30sModelBatches": eventTotals["model_batch_first_30s", default: 0],
            "confirmedModelBatches": eventTotals["confirmed_model_submitted", default: 0],
            "speculativeModelBatches": eventTotals["speculative_model_submitted", default: 0],
            "warmupModelBatches": eventTotals["warmup_model_submitted", default: 0],
            "actualModelBatches": eventTotals["confirmed_model_submitted", default: 0] +
                eventTotals["speculative_model_submitted", default: 0] + eventTotals["warmup_model_submitted", default: 0],
            "cancelledModelBatches": eventTotals["model_batch_cancelled", default: 0],
            "speculativeStopRequests": eventTotals["speculative_stop_requested", default: 0],
            "speculativeSessionsCreated": eventTotals["speculative_session_created", default: 0],
            "legacySharedSessionCalls": eventTotals["legacy_shared_session_used", default: 0],
            "handoffReplayed": eventTotals["handoff_replayed", default: 0],
            "handoffExpired": eventTotals["handoff_expired", default: 0],
            "enqueueFailed": eventTotals["enqueue_failed", default: 0],
            "runtimeTransitions": eventTotals["runtimeTransition", default: 0],
            "visualChanges": s.visualChanges
        ]
    }

    private func makeInterval(at now: Date, start: Date,
                              baseline: [String: Int]) -> DiagnosticIntervalBucket? {
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 0 else { return nil }
        let current = cumulativeCounters()
        var delta = current.reduce(into: [String: Int]()) { result, entry in
            result[entry.key] = max(0, entry.value - baseline[entry.key, default: 0])
        }
        let ocrTimes = ocr.filter { $0.t >= start && $0.t <= now }.map(\.v)
        let translationTimes = translate.filter { $0.t >= start && $0.t <= now }.map(\.v)
        let enqueueTimes = latency.filter { $0.t >= start && $0.t <= now }.map(\.v)
        let modelTimes = structuredEvents.filter {
            $0.timestamp >= start && $0.timestamp <= now &&
            $0.stage == "model_state" && $0.reasonCode == "model_batch_completed"
        }.compactMap(\.durationMs)
        delta["ocrMeasurementCount"] = ocrTimes.count
        delta["translationMeasurementCount"] = translationTimes.count
        delta["enqueueMeasurementCount"] = enqueueTimes.count
        let ocrTiming = DiagnosticDistribution(ocrTimes)
        let translationTiming = DiagnosticDistribution(translationTimes)
        let enqueueTiming = DiagnosticDistribution(enqueueTimes)
        let modelTiming = DiagnosticDistribution(modelTimes)
        let thermal: Int
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = 0
        case .fair: thermal = 1
        case .serious: thermal = 2
        case .critical: thermal = 3
        @unknown default: thermal = 0
        }
        return DiagnosticIntervalBucket(startedAt: start,
            elapsedSeconds: min(1800, elapsed), counters: delta,
            thermalLevel: thermal,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            captureConnected: lastCaptureConnected,
            effectiveOCRIntervalMs: s.effectiveOCRIntervalMs > 0 ? s.effectiveOCRIntervalMs : nil,
            visualChangeProxyMs: s.firstSightVisualChangeLagMs > 0 ?
                s.firstSightVisualChangeLagMs : nil,
            ocrMedianMs: ocrTiming.p50, ocrP95Ms: ocrTiming.p95,
            translationMedianMs: translationTiming.p50,
            translationP95Ms: translationTiming.p95,
            enqueueMedianMs: enqueueTiming.p50, enqueueP95Ms: enqueueTiming.p95,
            modelBatchMedianMs: modelTiming.p50)
    }

    private func diagnosticIntervals(at now: Date) -> [DiagnosticIntervalBucket] {
        var all = intervalHistory
        if let current = makeInterval(at: now, start: intervalStart, baseline: intervalBaseline) {
            all.append(current)
        }
        return Array(all.suffix(960))
    }

    /// Read-only completed buckets for the live diagnostic UI. Does not
    /// recalculate statistics or store unbounded samples during rendering.
    func completedIntervals(seconds: Int) -> [DiagnosticIntervalBucket] {
        switch seconds {
        case 1: return oneSecondHistory
        case 5: return fiveSecondHistory
        default: return intervalHistory
        }
    }

    private func recentIntervals(at now: Date, period: Int) -> [DiagnosticIntervalBucket] {
        let isOneSecond = period == 1
        let start = isOneSecond ? oneSecondStart : fiveSecondStart
        let baseline = isOneSecond ? oneSecondBaseline : fiveSecondBaseline
        var all = isOneSecond ? oneSecondHistory : fiveSecondHistory
        if let current = makeInterval(at: now, start: start, baseline: baseline) {
            all.append(current)
        }
        return Array(all.suffix(isOneSecond ? 300 : 180))
    }

    private func diagnosticIntervals(at now: Date, period: Int) -> [DiagnosticIntervalBucket] {
        recentIntervals(at: now, period: period)
    }

    private func sampleDevice(alive: Bool) {
        lastDeviceSampleAt = Date()
        let level: Double
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: level = 0
        case .fair: level = 1
        case .serious: level = 2
        case .critical: level = 3
        @unknown default: level = 0
        }
        add(\.thermal, level, cap: 900)
        add(\.appMem, Double(os_proc_available_memory()) / 1_048_576, cap: 900)
        let b = Double(UIDevice.current.batteryLevel)
        if b >= 0 { add(\.battery, b * 100, cap: 900) }
        if alive, s.extFreeMB > 0 { add(\.extMem, s.extFreeMB, cap: 900) }
        let total = s.cacheHits + s.savedHits + s.specHits + s.cacheMisses
        if total > 0 { add(\.cacheRate, Double(s.cacheHits + s.savedHits + s.specHits) / Double(total) * 100, cap: 900) }
    }

    // MARK: Maths
    nonisolated static func summarize(_ a: [Sample]) -> Summary {
        guard !a.isEmpty else { return Summary() }
        let v = a.map { $0.v }.sorted()
        func pct(_ p: Double) -> Double { v[Swift.min(v.count - 1, Int(Double(v.count - 1) * p))] }
        return Summary(n: v.count, min: v.first ?? 0, avg: v.reduce(0, +) / Double(v.count),
                       p50: pct(0.5), p95: pct(0.95), max: v.last ?? 0, last: a.last?.v ?? 0)
    }

    nonisolated static func orientationName(_ v: Int) -> String {
        let n = ["up", "up mirrored", "down", "down mirrored", "left mirrored", "right", "right mirrored", "left"]
        return (1...8).contains(v) ? "\(n[v - 1]) (\(v))" : "\(v)"
    }

    // MARK: Health + advice
    func assessment(alive: Bool, paused: Bool) -> Assessment {
        var issues: [Issue] = []
        var score = 100
        func flag(_ sev: Int, _ title: String, _ detail: String, _ fix: Fix? = nil) {
            issues.append(Issue(severity: sev, title: title, detail: detail, fix: fix))
        }
        let ocrS = Diagnostics.summarize(Array(ocr.suffix(30)))
        let latS = Diagnostics.summarize(Array(latency.suffix(30)))
        let trS = Diagnostics.summarize(Array(translate.suffix(30)))

        if !alive {
            flag(2, "Capture isn't running", "Open Translate, tap the round Start button and choose ScreenLingo Capture.", .startCapture)
            score -= 45
        } else {
            if paused { flag(0, "Translating is paused", "Tap Resume on Translate to continue."); score -= 5 }
            if ocrS.n >= 3 {
                if ocrS.avg > 500 {
                    flag(2, "Reading the screen is slow (\(Int(ocrS.avg)) ms)", "A smaller area or the Fast speed makes it quicker.", .fastSpeed); score -= 20
                } else if ocrS.avg > 300 {
                    flag(1, "Reading is a little slow (\(Int(ocrS.avg)) ms)", "Try the Fast speed or a smaller OCR area.", .fastSpeed); score -= 10
                }
            }
            if latS.n >= 3 {
                if latS.avg > 2000 {
                    flag(2, "Translations show up late (\(Int(latS.avg)) ms)", "Check measured queue and readability hold time. Immediate display keeps confirmation enabled.", .immediateDisplay); score -= 20
                } else if latS.avg > 1200 {
                    flag(1, "Slightly delayed translations (\(Int(latS.avg)) ms)", "Immediate display removes optional readability holds without changing translation quality.", .immediateDisplay); score -= 10
                }
            }
            if s.fps > 0 && s.fps < 15 {
                flag(1, "Low frame rate (\(Int(s.fps)) fps)", "The phone may be busy or warm."); score -= 8
            }
        }
        if s.minExtFreeMB < 12 {
            flag(2, "The capture extension nearly ran out of memory (\(Int(s.minExtFreeMB)) MB left)", "iOS may close it. Use the Fast speed or a smaller OCR area.", .fastSpeed); score -= 20
        } else if s.minExtFreeMB < 20 {
            flag(1, "Memory is getting tight (\(Int(s.minExtFreeMB)) MB left)", "The Fast speed uses less memory.", .fastSpeed); score -= 8
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            flag(2, "The phone is hot", "Reading slows down automatically. Let it cool down, or lower the brightness."); score -= 15
        default: break
        }
        if alive, trS.n >= 3, trS.avg > 400,
           (UserDefaults.standard.object(forKey: "translateAhead") as? Bool) == false {
            flag(1, "Translating is a big part of the delay (\(Int(trS.avg)) ms)",
                 "Translate-ahead starts translating before the text is confirmed, so the waits overlap.", .translateAhead)
            score -= 8
        }
        if s.sessionKind.contains("Hosted") {
            flag(0, "Translations use the slower engine",
                 "The faster direct engine needs iOS 26 and both language packs downloaded.", .openLanguages)
        }
        if s.translations + s.failures > 0, Double(s.failures) / Double(s.translations + s.failures) > 0.05 {
            flag(1, "Some sentences failed to translate", "Make sure the language packs are downloaded.", .openLanguages); score -= 10
        }
        if s.rotationTries >= 3 {
            flag(1, "Sentence order keeps being re-detected", "Pick a fixed frame rotation in Settings > Area and recognition.", .fixedRotation); score -= 8
        }
        if s.captureDrops >= 2 {
            flag(1, "Capture stopped \(s.captureDrops) times", "iOS closed the extension. The Fast speed is easier on memory.", .fastSpeed); score -= 8
        }
        score = Swift.max(0, Swift.min(100, score))
        let headline = !alive ? "Not running" : (score >= 85 ? "Running smoothly" : (score >= 60 ? "Working, could be better" : "Needs attention"))
        issues.sort { $0.severity > $1.severity }
        return Assessment(score: score, headline: headline, issues: issues)
    }

    // MARK: Export
    func csv() -> String {
        var rows = ["series,time,value"]
        func dump(_ name: String, _ a: [Sample]) {
            for x in a { rows.append("\(name),\(x.t.timeIntervalSince1970),\(x.v)") }
        }
        dump("read_ms", ocr); dump("translate_ms", translate); dump("delay_ms", latency); dump("transfer_ms", transport)
        dump("fps", fps); dump("lines_per_packet", lineCounts); dump("extension_free_mb", extMem)
        dump("app_free_mb", appMem); dump("thermal_level", thermal); dump("battery_percent", battery)
        dump("cache_hit_percent", cacheRate)
        rows.append("")
        rows.append("time,kind,text")
        for e in events {
            let clean = e.text.replacingOccurrences(of: "\"", with: "'")
            rows.append("\(e.time.timeIntervalSince1970),\(e.kind.rawValue),\"\(clean)\"")
        }
        rows.append("")
        rows.append("pipeline_time,confirmation_ms,ocr_ms,delivery_filtering_ms,queue_ms,processing_ms,readability_hold_ms,frame_ms,total_ms")
        for sample in pipeline {
            let v = sample.stages
            rows.append("\(sample.date.timeIntervalSince1970),\(v.confirmation),\(v.recognition),\(v.delivery),\(v.queue),\(v.translation),\(v.displayHold),\(v.rendering),\(v.total)")
        }
        rows.append("")
        rows.append("source_language,confirmed_blocks")
        for (code, count) in sourceUsage.counts.sorted(by: { $0.key < $1.key }) { rows.append("\(code),\(count)") }
        rows.append("")
        rows.append("source_choice_mode,confirmed_blocks")
        for mode in SourceLanguageOrigin.allCases { rows.append("\(mode.rawValue),\(sourceUsage.origins[mode, default: 0])") }
        rows.append("")
        rows.append("candidate,stage,time,detail")
        for item in subtitleTraces {
            rows.append(ExportFormat.csv([[item.candidate, item.stage, item.time.ISO8601Format(), item.detail]]))
        }
        rows.append("")
        rows.append("metric,value")
        for (name, value) in [("session_cache_hits", Double(s.cacheHits)), ("saved_memory_hits", Double(s.savedHits)),
            ("speculative_hits", Double(s.specHits)), ("fresh_requests", Double(s.cacheMisses)),
            ("speculative_attempts", Double(s.specStarted)), ("speculative_completed", Double(s.specCompleted)),
            ("speculative_discarded", Double(s.specDiscarded)), ("speculative_skipped", Double(s.specSkipped)),
            ("discarded_speculative_ms", s.specDiscardedMs), ("language_confidence", s.languageConfidence),
            ("recorder_simple_ms", recorderCosts.simpleMs), ("recorder_detailed_ms", recorderCosts.detailedMs)] {
            rows.append("\(name),\(value)")
        }
        return rows.joined(separator: "\n")
    }

    /// v2.0.0 L1/L3/L2 one-line view of where confirmed sentences came from,
    /// how often new speculative sessions were created, and confirmed model
    /// time split by a nearby call on another session. Diagnostics only.
    var servedByLine: String {
        let total = s.specHits + s.cacheHits + s.savedHits + s.cacheMisses
        func share(_ n: Int) -> String { total == 0 ? "–" : "\(Int((Double(n) / Double(total) * 100).rounded()))%" }
        let minutes = max(1.0 / 60, Date().timeIntervalSince(started) / 60)
        let created = eventTotals["speculative_session_created", default: 0]
        func median(_ key: String) -> String {
            let values = (modelTimingSamples[key] ?? []).sorted()
            guard !values.isEmpty else { return "– (0)" }
            return "\(Int(values[values.count / 2])) ms (\(values.count))"
        }
        return "Served by (sentences): speculation \(share(s.specHits)), session RAM \(share(s.cacheHits)), saved memory \(share(s.savedHits)), model \(share(s.cacheMisses)) of \(total). Speculative sessions created \(created) (\(String(format: "%.1f", Double(created) / minutes))/min). Legacy confirmed model median: other session nearby \(median("legacy_confirmed_after_switch")), no switch \(median("legacy_confirmed_no_switch"))."
    }

    func report(engine: TranslatorEngine) -> String {
        let a = assessment(alive: engine.captureAlive, paused: engine.paused)
        let o = Diagnostics.summarize(ocr), t = Diagnostics.summarize(translate)
        let d = Diagnostics.summarize(latency), x = Diagnostics.summarize(transport)
        func line(_ n: String, _ s: Summary) -> String {
            "\(n): avg \(Int(s.avg)) ms, p50 \(Int(s.p50)), p95 \(Int(s.p95)), max \(Int(s.max)) (\(s.n) samples)"
        }
        var l: [String] = []
        l.append("ScreenLingo \(AppVersion.full) – diagnostics")
        l.append("Collection: \(enabled ? (detailedCollection ? "detailed" : "simple (graphs and events off)") : "off"); Cool mode: \(UserDefaults.standard.bool(forKey: "coolMode") ? "on" : "off").")
        l.append("Health \(a.score)/100 – \(a.headline)")
        for i in a.issues { l.append("  • \(i.title)") }
        l.append("Capture: \(engine.captureAlive ? "connected" : "not connected"), extension v\(engine.extensionVersion), drops \(s.captureDrops)")
        l.append("Frames \(s.frames) (\(Int(s.fps)) fps), OCR passes \(s.passes), skipped \(s.skippedFrames)")
        l.append("Frame \(s.bufferSize), read area \(s.cropSize), orientation \(s.orientation), rotation \(s.rotation * 90)°")
        l.append(line("Reading", o)); l.append(line("Translating", t)); l.append(line("Total delay", d)); l.append(line("Transfer", x))
        l.append("Extension memory free \(Int(s.extFreeMB)) MB (lowest \(s.minExtFreeMB > 9000 ? 0 : Int(s.minExtFreeMB)) MB)")
        l.append("Lines \(s.linesIn): area \(s.dropArea), small \(s.dropSmall), ignore \(s.dropIgnore), own window \(s.dropSelf), target language \(s.dropTarget); blocks \(s.blocksIn) → \(s.blocksKept), noise \(s.dropNoise), other language \(s.dropLanguage)")
        l.append("Order confidence \(String(format: "%.1f", s.orderVote)), calibrated \(s.calibrated), rotation tries \(s.rotationTries)")
        l.append("Translations \(s.translations), sentences \(s.sentences), cache \(s.cacheHits + s.savedHits)/\(s.cacheHits + s.savedHits + s.specHits + s.cacheMisses) (pre-translated \(s.specHits)), failures \(s.failures), engine \(s.sessionKind)")
        l.append("Configured source \(engine.sourceCode), last source used \(s.sourceUsed) (\(s.sourceOrigin)), automatic detector \(engine.sourceCode == "auto" ? "enabled" : "off – source selected"), locked \(s.lockedLang).")
        l.append("Cache origins: session \(s.cacheHits), saved memory \(s.savedHits), speculative \(s.specHits), fresh requests \(s.cacheMisses).")
        l.append(servedByLine)
        l.append("Speculative model requests \(s.specModelRequests); pipeline attempts \(s.specStarted), completed \(s.specCompleted), superseded/cancelled \(s.specDiscarded), declined \(s.specSkipped), unconsumed results \(engine.unconsumedSpeculation); processing \(Int(s.specProcessingMs)) ms, discarded work \(Int(s.specDiscardedMs)) ms. Attempts count pipeline jobs; cache hits count sentences.")
        l.append("Idle validation: selected \(s.legacyBatchEntries), verified \(s.legacyBatchVerified), skipped \(s.legacyBatchSkipped); peak workers \(s.legacyBatchPeakWorkers); model + commit wall time \(Int(s.legacyBatchElapsedMs)) ms.")
        l.append("v1.4.5: deferred confirmed handoffs \(s.confirmedHandoffDeferred); adaptive speculative skips \(s.adaptiveSpeculationSkipped); slow (>1200 ms) PiP enqueues \(s.slowTailEnqueues).")
        l.append("OCR confidence \(Int(s.ocrConfidence*100))%, source evidence \(s.sourceOrigin == "Selected" ? "manual selection" : "\(Int(s.languageConfidence*100))%"); recognition: \(s.recognitionReason); confirmation: \(s.confirmationReason).")
        l.append("Frame skips: unchanged \(s.unchangedSkipped), cadence \(s.cadenceSkipped), paused \(s.pausedSkipped); consecutive empty reads \(s.emptyReads), contrast retries \(s.retryCount).")
        l.append("Instrumented recorder elapsed self-time, app lifetime: simple \(String(format: "%.2f", recorderCosts.simpleMs)) ms / \(recorderCosts.simpleCalls) calls; detailed \(String(format: "%.2f", recorderCosts.detailedMs)) ms / \(recorderCosts.detailedCalls) calls. Excludes async chart drawing, translation and OCR; workloads may differ.")
        l.append("Source language inputs: " + sourceUsage.counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        l.append("Source choice modes: " + SourceLanguageOrigin.allCases.map { "\($0.title)=\(sourceUsage.origins[$0, default: 0])" }.joined(separator: ", "))
        l.append("Execution phase \(executionPhase), PiP \(engine.pipActive ? "active" : "inactive"); last packet \(lastPacketAt?.ISO8601Format() ?? "none"), last device sample \(lastDeviceSampleAt?.ISO8601Format() ?? "none").")
        l.append("Settings: mode=\(UserDefaults.standard.string(forKey: "mode") ?? "movie"), area=\(UserDefaults.standard.string(forKey: "area") ?? "smart"), speed=\(UserDefaults.standard.string(forKey: "speed") ?? "balanced"), configured rotation=\(UserDefaults.standard.string(forKey: "frameRot") ?? "auto"), confirmation reads=\((UserDefaults.standard.object(forKey: "stability") as? Int) ?? 2)")
        l.append("v1.5.0 experiments: low-latency model \(UserDefaults.standard.bool(forKey: "lowLatencyTranslation")), incremental recovery \(UserDefaults.standard.bool(forKey: "incrementalBatchRecovery")), subtitle-area sampling \(UserDefaults.standard.bool(forKey: "subtitleAwareChangeDetection")), additional lyric groups \(UserDefaults.standard.bool(forKey: "preserveRelatedMovieGroups")), direct PiP drawing \(UserDefaults.standard.bool(forKey: "directPiPBuffer")).")
        l.append("Continuity: confirmed candidates \(s.confirmedCandidatePackets), successful PiP enqueues \(s.enqueuedCandidateFrames), superseded before enqueue \(s.supersededUnpresentedConfirmed), deferred handoffs \(s.confirmedHandoffDeferred); these are not unique-subtitle or physical-presentation counts.")
        l.append("Speculation: discarded pipelines \(s.specDiscarded), completed superseded units retained \(s.specRetainedUnits), adaptive skips \(s.adaptiveSpeculationSkipped).")
        if UserDefaults.standard.bool(forKey: "diagIncludeText"), !UserDefaults.standard.bool(forKey: "privateSession") {
            l.append("Speakers: \(names.joined(separator: ", "))")
        }
        l.append("")
        if let latest = pipeline.last?.stages {
            l.append("Latest paired timing (ms): confirmation \(Int(latest.confirmation)), OCR \(Int(latest.recognition)), delivery/filtering \(Int(latest.delivery)), queue \(Int(latest.queue)), processing \(Int(latest.translation)), readability hold \(Int(latest.displayHold)), frame preparation \(Int(latest.rendering)), total \(Int(latest.total))")
            l.append("Total measures first OCR sighting to frame enqueue; it does not measure physical screen presentation. Confirmation and translation-ahead can overlap.")
        }
        l.append("Memory schema \(memoryHealth.schemaVersion), entries \(memoryHealth.totalEntries), ready \(memoryHealth.readyEntries), needs validation \(memoryHealth.needsValidation), conflicts \(memoryHealth.conflicts).")
        l.append("Memory migration: \(memoryHealth.migrationStatus); integrity: \(memoryHealth.integrity); pending writes \(memoryHealth.pendingWrites), failed writes \(memoryHealth.failedWrites).")
        l.append("Recent events:")
        for e in events.suffix(60).reversed() {
            l.append("\(e.time.formatted(date: .omitted, time: .standard)) [\(e.kind.title)] \(e.text)")
        }
        return l.joined(separator: "\n")
    }
}
