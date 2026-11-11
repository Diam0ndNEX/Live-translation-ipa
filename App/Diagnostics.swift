import CryptoKit
// ScreenLingo – App
import SwiftUI
import Charts
import os
import Darwin

// MARK: - Models


// MARK: - Recorder
@MainActor
final class Diagnostics: ObservableObject {
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
    @Published var subtitleTraces: [SubtitleTrace] = []
    @Published var memoryHealth = MemoryDiagnosticHealth()
    /// 2.4.0: not @Published. An append to a published array reads, copies and writes back the whole array (up to
    /// 6000 events) and notifies every observer, for each event of each caption. The Diagnostics screens redraw on
    /// the other published values, which change at least as often.
    var structuredEvents: [StructuredDiagnosticEvent] = []
    /// 2.4.0: the two rings are cut back to 6000 in blocks of this size, not by one element on every event.
    static let ringTrimBlock = 256
    /// 2.4.0: capture facts the extension reports with each confirmed caption (numbers only).
    var confirmationReadSamples: [Double] = []
    var confirmationFrameWaitSamples: [Double] = []
    var rediscoveryLeadSamples: [Double] = []
    private var captionDigestCache: [String: String] = [:]
    @Published var archiveStatus = "Not saved"
    // v2.0.0 build 84 Test Runs (spec §11): runs are stored by TestRunStore, not in the memory database.
    /// 2.3.2: stopping and restarting capture in the same mode no longer ends the run or clears anything.
    /// The run is saved when capture stops, and carries on when capture connects again.
    var pausedAt: Date?
    var pausedTotal: TimeInterval = 0
    var pauseReason = ""
    private var captureRestartCount = 0
    /// Why capture stopped, per reason: the extension's own stop packet, a silent heartbeat timeout (the extension
    /// stopped sending), or a new capture session replacing the old one. Plus what was known at the last stop.
    private var captureStopCounts: [String: Int] = [:]
    private var extFreeMBAtLastStop = 0
    /// What the extension looked like across a stop: frames it had seen, and whether the same broadcast came back.
    /// Same broadcast back after a silent timeout means the extension never stopped (the app only stopped hearing it).
    private var framesAtLastStop = 0
    private var resumedSameBroadcast = 0
    private var resumedNewBroadcast = 0
    private var framesDuringLastGap = 0
    private var longestStopGapSeconds = 0
    private var secondsIntoRunAtLastStop = 0
    @Published var activeRun: ActiveRun?
    @Published var testRuns: [TestRunMeta] = []
    @Published var runPruneNote: String?
    @Published var lastRunBanner: RunBanner?
    @Published var lastCheckpointCaptureMs: Double?
    let runStore = TestRunStore(directory: TestRunStore.defaultDirectory())
    var unsavedEndedRun: (meta: TestRunMeta, snapshot: DiagnosticSessionExport)?
    var checkpointInFlight = false
    var checkpointCaptureMicros = 0
    @Published var exportInProgress = false
    var memoryStore: TranslationMemoryStore?
    let exportWriter = DiagnosticExportWriter()
    var diagnosticSessionID = UUID()
    // A 15-second full-session summary survives recent-event ring eviction.
    // No user text, OCR boxes, cache keys or untrusted labels enter these buckets.
    var intervalStart = Date()
    var intervalBaseline: [String: Int] = [:]
    var intervalHistory: [DiagnosticIntervalBucket] = []
    // Independent 1s and 5s buckets preserve timing distributions from the
    // actual samples. Never average medians from smaller buckets.
    var oneSecondStart = Date()
    var oneSecondBaseline: [String: Int] = [:]
    var oneSecondHistory: [DiagnosticIntervalBucket] = []
    var fiveSecondStart = Date()
    var fiveSecondBaseline: [String: Int] = [:]
    var fiveSecondHistory: [DiagnosticIntervalBucket] = []
    var openingEvents: [StructuredDiagnosticEvent] = []
    var earlyEventsSeen = 0
    var eventTotals: [String: Int] = [:]
    var lastCaptureConnected = false
    var lastRecordedThermalState: String?
    /// 2.2.1 (D1): Detailed collection was requested but switched itself off at Serious/Critical thermal state.
    var detailSuspendedByThermal = false
    /// Thermal level when the current collection started and the warmest level seen since (2.2.1, D4).
    var thermalStartLevel: Int?
    /// 2.2.1 (D6): what the bounded buffers threw away. Exported as counters and printed in the report's Truncation section.
    var structuredEventsDropped = 0, idMapResets = 0, legacyContextResets = 0, subtitleTracesDropped = 0
    var thermalMaxLevel = 0
    var captureReductionReasons = ["none"]
    var requestedCaptureIntervalMs = 0
    var requestedCaptureEdgePx = 0

    var candidateIDs: [String: UUID] = [:]
    var frameIDs: [Int: UUID] = [:]
    var unitIDs: [String: UUID] = [:]
    var memoryOutcomes: [MemoryDiagnosticOutcome: Int] = [:]
    var modelTimingSamples: [String: [Double]] = [:]
    var translationTestMode = TranslationTestMode.normal
    var startingRAMEntries = 0
    var ramEntryCount: (() -> Int)?
    var sharedModelUnits = 0
    var sharedConfirmedModelUnits = 0
    var memoryAwareSpeculationSkipped = 0
    var ramCaptionBypasses = 0
    var exactCaptionHits = 0
    var exactUnitsCoalesced = 0
    var speculativeUnitCounts: [String: Int] = [:]
    var queueWaitSamples: [ModelQueueOwner: [Double]] = [:]
    var temporaryMemoryHits = 0
    var completedWorkRecoveredUnits = 0
    var lookupSamples: [Double] = []
    var writeSamples: [Double] = []
    /// 2.2.1 (D10): measurement only. Queue wait before a memory lookup starts, and the cost of a health query.
    var lookupWaitSamples: [Double] = []
    var memoryHealthSamples: [Double] = []
    /// 2.2.1 (E15): time to encode and write the Library once, in milliseconds.
    var historySaveSamples: [Double] = []
    var recorderCosts = RecorderCosts()
    var recorderDepth = 0
    var legacyValidationSnapshot: [String: Int] = [:]
    var legacyValidationPair: [String: String] = [:]
    var legacyModeContexts: [String: LegacyModeContext] = [:]
    /// 2.3.0: insertion order of `legacyModeContexts`, so the oldest entries can be dropped first.
    var legacyModeContextOrder: [String] = []
    let legacyModeContextLimit = 128
    let legacyModeContextDropCount = 32

    func legacyModeEvent(_ caption: String, reason: String, duration: Double? = nil) {
        guard let context = legacyModeContexts[caption], modeActiveSystem == "legacy" else { return }
        noteModeEvent(session: context.session, caption: caption, revision: 0, source: context.source,
            target: context.target, fingerprint: context.fingerprint, reason: reason,
            firstOCR: context.firstOCR, duration: duration)
    }

    var modeActiveSystem = "legacy"
    var modePendingSystem = "legacy"
    var modeMigration = "persisted"
    var modeTrace: [TranslationModeTrace] = []
    var openingModeTrace: [TranslationModeTrace] = []
    private var modeTimingSamples: [String: [Double]] = [:]
    var modeEventCounts: [String: Int] = [:]
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
        // 2.4.0: one caption sends tens of events; its digest is computed once, not for each of them.
        let safeCaption: String
        if let cached = captionDigestCache[caption] { safeCaption = cached } else {
            safeCaption = SHA256.hash(data: Data(caption.utf8)).map { String(format: "%02x", $0) }.joined()
            if captionDigestCache.count >= 64 { captionDigestCache.removeAll(keepingCapacity: true) }
            captionDigestCache[caption] = safeCaption
        }
        let entry = TranslationModeTrace(mode: mode ?? modeActiveSystem, testMode: translationTestMode.rawValue,
            session: session, caption: safeCaption, revision: revision,
            source: source, target: target, fingerprint: fingerprint, reason: reason,
            monotonicTime: ProcessInfo.processInfo.systemUptime, firstOCR: firstOCR,
            durationMs: duration, thermal: ProcessInfo.processInfo.thermalState.rawValue)
        modeTrace.append(entry)
        if modeTrace.count > 6000 + Self.ringTrimBlock {
            let discarded = modeTrace.count - 6000
            modeTrace.removeFirst(discarded)
            modeEventCounts["mode_trace_ring_overwritten", default: 0] += discarded
        }
        // Keep early and late execution boundaries in the same export for comparisons.
        if Date().timeIntervalSince(started) < 120, openingModeTrace.count < 160,
           (reason.hasPrefix("recovery_decision_") || reason.hasPrefix("pip_enqueue_") ||
            reason == "pip_held_unchanged" || reason == "confirmed" ||
            reason == "hybrid_cross_strategy_overlap" || reason == "hybrid_default_default_overlap" || reason == "hybrid_speculation_throttled" ||
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
                    // 2.2.1 (D4): settings that change render time or end a run
                    "idleMinutes", "sessionLimit", "autoOpenPiP", "winSize", "textSize", "pipFont", "theme", "showOriginal",
                    "highlightNames", "pipScale", "pipWeight", "pipAlignment", "pipPadding", "cjkSingleCharacters", "liveWarmupLegacy",
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
        if detailSuspendedByThermal { settings["detailSuspended"] = "true" }
        // 2.2.1 (D4, E12): thermal start/end/max (a run's end state alone hides a warm run) and the two
        // capture options the app derives per mode. They are not stored settings, so they are written here.
        let thermalNames = ["nominal", "fair", "serious", "critical"]
        let level = max(0, min(3, thermalState.rawValue))
        settings["thermalStart"] = thermalNames[max(0, min(3, thermalStartLevel ?? level))]
        settings["thermalEnd"] = thermalNames[level]
        settings["thermalMax"] = thermalNames[max(level, thermalMaxLevel)]
        let legacyActive = modeActiveSystem == "legacy"
        settings["strictCaptionIdentity"] = String(!legacyActive)
        settings["focusedCaptionOCR"] = String(!legacyActive && ((UserDefaults.standard.object(forKey: "subtitleTracking") as? Bool) ?? true))
        settings["hotPathAB"] = TranslationHotPathAB.label
        settings["hybridSchedulerAB"] = HybridSchedulingPolicy.buildVariant.rawValue
        // 2.2.3 (L5): written only when the pinned switch is ON. A missing value means off, so default runs stay
        // comparable with runs saved before 2.2.3 (a missing cohort value counts as "-").
        if TranslationHotPathAB.refreshAvailabilityInBackground { settings["availabilityRefreshAB"] = "on" }
        if TranslationHotPathAB.hybridRelaxedBackoff { settings["hybridBackoffAB"] = "on" }
        if TranslationHotPathAB.hybridShorterGuard { settings["hybridGuardAB"] = "on" }
        if TranslationHotPathAB.legacyConfirmedOwnLane { settings["legacyOwnLaneAB"] = "on" }
        if TranslationHotPathAB.independentHeartbeat { settings["heartbeatAB"] = "on" }
        // 2.4.0: both default ON. Written only when ON, like the others, so a run saved before 2.4.0 reads as off.
        if TranslationHotPathAB.hybridPinnedBackend { settings["hybridPinAB"] = "on" }
        if TranslationHotPathAB.deferArmedSpeculation { settings["armedDeferAB"] = "on" }
        settings["reductionReasons"] = captureReductionReasons.joined(separator: "_")
        settings["appRequestedCaptureIntervalMs"] = String(requestedCaptureIntervalMs)
        settings["appRequestedCaptureEdgePx"] = String(requestedCaptureEdgePx)
        settings.merge(legacyValidationPair) { _, new in new }
        var counters = cumulativeCounters()
        counters.merge(legacyValidationSnapshot) { _, new in new }
        counters.merge(Dictionary(uniqueKeysWithValues: memoryOutcomes.map { ($0.key.rawValue, $0.value) })) { _, new in new }
        counters["structured_events_dropped"] = structuredEventsDropped
        counters["id_map_resets"] = idMapResets
        counters["legacy_context_resets"] = legacyContextResets
        counters["subtitle_traces_dropped"] = subtitleTracesDropped
        counters["sessionCacheHits"] = s.cacheHits
        counters["savedMemoryHits"] = s.savedHits
        counters["speculativeHits"] = s.specHits
        counters["uncachedUnits"] = s.cacheMisses
        counters["speculativeModelRequests"] = s.specModelRequests
        counters["supersededSpeculativePipelines"] = s.specDiscarded
        counters["confirmedCandidatePackets"] = s.confirmedCandidatePackets
        counters["deferredEarlyCandidates"] = s.deferredEarlyCandidates
        counters["supersededUnpresentedConfirmed"] = s.supersededUnpresentedConfirmed
        counters["supersededConfirmedInFlight"] = s.supersededConfirmedInFlight
        counters["supersededConfirmedNotStarted"] = s.supersededConfirmedNotStarted
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
        counters["earlyVisualWakesSuppressed"] = s.earlyVisualWakesSuppressed
        counters["largePackets"] = s.largePackets
        counters["packetSendErrors"] = s.packetSendErrors
        counters["pixelConfirmations"] = s.pixelConfirmations
        counters["pixelRejections"] = s.pixelRejections
        counters["watchSkippedOCR"] = s.watchSkippedOCR
        counters["watchTriggeredOCR"] = s.watchTriggeredOCR
        counters["focusRediscoveries"] = s.focusRediscoveries
        counters["confirmedWithPixelRejection"] = s.confirmedWithPixelRejection
        counters["legacyAdaptiveLowYieldSkips"] = s.legacyAdaptiveLowYieldSkips
        counters["legacyAdaptiveSavedSkips"] = s.legacyAdaptiveSavedSkips
        counters["legacyLowConfidenceSkips"] = s.legacyLowConfidenceSkips
        counters["legacyBusySpeculationSkips"] = s.legacyBusySpeculationSkips
        counters["legacyDuplicateSpeculationSkips"] = s.legacyDuplicateSpeculationSkips
        counters["emptyOCRPasses"] = s.emptyOCRPasses
        counters["runCheckpointCaptureMicros"] = checkpointCaptureMicros
        counters["captureRestarts"] = captureRestartCount
        counters["captureStopsByPacket"] = captureStopCounts["captureStopped", default: 0]
        counters["captureStopsByTimeout"] = captureStopCounts["heartbeatTimeout", default: 0]
        counters["captureStopsByNewSession"] = captureStopCounts["newCaptureSession", default: 0]
        counters["extensionFreeMBAtLastStop"] = extFreeMBAtLastStop
        counters["secondsIntoRunAtLastStop"] = secondsIntoRunAtLastStop
        counters["resumedSameBroadcast"] = resumedSameBroadcast
        counters["resumedNewBroadcast"] = resumedNewBroadcast
        counters["extensionFramesDuringLastGap"] = framesDuringLastGap
        counters["longestStopGapSeconds"] = longestStopGapSeconds
        counters["runPausedSeconds"] = Int(pausedSeconds.rounded())
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
                "historySaveMs": DiagnosticDistribution(historySaveSamples),
                "memoryLookupWaitMs": DiagnosticDistribution(lookupWaitSamples),
                "memoryHealthMs": DiagnosticDistribution(memoryHealthSamples),
                "ocrMs": DiagnosticDistribution(ocr.map { $0.v }), "translationMs": DiagnosticDistribution(translate.map { $0.v }),
                "enqueueLatencyMs": DiagnosticDistribution(latency.map { $0.v }),
                "finalOCRMs": DiagnosticDistribution(pipeline.map { $0.stages.recognition }),
                "transportMs": DiagnosticDistribution(transport.map { $0.v }),
                "confirmationMs": DiagnosticDistribution(pipeline.map { $0.stages.confirmation }),
                "deliveryFilteringMs": DiagnosticDistribution(pipeline.map { $0.stages.delivery }),
                "queueMs": DiagnosticDistribution(pipeline.map { $0.stages.queue }),
                "speculativeStopReleaseMs": DiagnosticDistribution(modelTimingSamples["speculative_stop_released", default: []]),
                "legacyDetachedSpeculationReleaseMs": DiagnosticDistribution(modelTimingSamples["legacy_detached_speculation_released", default: []]),
                "queueBehindSpeculationMs": DiagnosticDistribution(queueWaitSamples[.speculative, default: []]),
                "confirmedSupersededAgeMs": DiagnosticDistribution(modelTimingSamples["confirmed_superseded_age_ms", default: []]),
                "legacyConfirmedOverlapMs": DiagnosticDistribution(modelTimingSamples["legacy_confirmed_overlap_ms", default: []]),
                "confirmationOCRReads": DiagnosticDistribution(confirmationReadSamples),
                "confirmationFrameWaitMs": DiagnosticDistribution(confirmationFrameWaitSamples),
                "rediscoveryLeadMs": DiagnosticDistribution(rediscoveryLeadSamples),
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

    /// Capture connected: a run starts. Keeps the opening warm-up trace already collected for this broadcast.
    /// Capture connected. Same mode as the paused run: the run continues and nothing is cleared (2.3.2).
    /// Otherwise a new run begins, as before.
    func beginRun(sameBroadcast: Bool, frames: Int) {
        if let run = activeRun, run.mode == modeActiveSystem { resumeRun(sameBroadcast: sameBroadcast, frames: frames); return }
        beginRun()
    }
    func beginRun() {
        if activeRun != nil { endRun(reason: "newRunStarted") }
        // 2.2.1 (E8): numbers gathered before capture connected (compose, tests) must not count in the run.
        // The warm-up trace is kept; only the totals and the latency series start from zero.
        s = Stats()
        pipeline = []
        translate = []; latency = []; transport = []
        structuredEventsDropped = 0; idMapResets = 0; legacyContextResets = 0; subtitleTracesDropped = 0
        thermalStartLevel = ProcessInfo.processInfo.thermalState.rawValue
        thermalMaxLevel = thermalStartLevel ?? 0
        started = Date()
        startingRAMEntries = ramEntryCount?() ?? 0
        startRunState()
    }
    /// Capture stopped, timed out or began a new capture session. The run and all live data stay; the run is saved
    /// (same id, so a later save replaces it) so nothing is lost if the app is closed before capture restarts.
    func pauseRun(reason: String, frames: Int = 0) {
        guard activeRun != nil, pausedAt == nil else { return }
        pausedAt = Date()
        framesAtLastStop = frames
        pauseReason = reason
        captureStopCounts[reason, default: 0] += 1
        extFreeMBAtLastStop = Int((extMem.last?.v ?? 0).rounded())
        secondsIntoRunAtLastStop = Int((Date().timeIntervalSince(started) - pausedTotal).rounded())
        event(.state, "Capture stopped (\(reason)) after \(secondsIntoRunAtLastStop) s of this run; extension free memory \(extFreeMBAtLastStop) MB; the run is kept")
        guard enabled, runSavingMode == "automatic" else { return }
        let snapshot = sessionSnapshot()
        let previous = testRuns.first { $0.id == snapshot.id }
        let meta = TestRunMeta.make(snapshot: snapshot, testID: currentTestID, testName: currentTestName,
            endReason: reason, startingRAMEntries: startingRAMEntries, modeChanges: activeRun?.modeChanges ?? [],
            completeness: "complete", label: previous?.label ?? "", pinned: previous?.pinned ?? false,
            pausedSeconds: pausedSeconds)
        if let (code, detail) = skipReason(for: meta) {
            lastRunBanner = RunBanner(result: .skipped(code, detail: detail), mode: meta.mode, seconds: meta.durationSeconds)
            return
        }
        activeRun?.lastCheckpointAt = Date()
        let store = runStore
        Task {
            let result = await store.save(meta: meta, snapshot: snapshot)
            lastRunBanner = RunBanner(result: result, mode: meta.mode, seconds: meta.durationSeconds)
            await refreshRuns()
        }
    }

    /// Capture connected again in the same mode: nothing is cleared. Only the gap is remembered.
    private func resumeRun(sameBroadcast: Bool, frames: Int) {
        if let paused = pausedAt {
            let gap = Date().timeIntervalSince(paused)
            pausedTotal += gap
            longestStopGapSeconds = max(longestStopGapSeconds, Int(gap.rounded()))
            if sameBroadcast { resumedSameBroadcast += 1 } else { resumedNewBroadcast += 1 }
            framesDuringLastGap = max(0, frames - framesAtLastStop)
            pausedAt = nil
            captureRestartCount += 1
            // Per-caption tags belong to the capture that stopped; a caption seen again after restart starts clean.
            legacyModeContexts.removeAll(); legacyModeContextOrder.removeAll()
            event(.state, "Capture heard again after \(Int(gap.rounded())) s (\(sameBroadcast ? "same broadcast, so the extension had not stopped" : "new broadcast")); extension frames during the gap: \(framesDuringLastGap); the same run continues (restart \(captureRestartCount))")
        }
    }

    private func startRunState() {
        activeRun = ActiveRun(id: diagnosticSessionID, startedAt: started, mode: modeActiveSystem,
                              startingRAMEntries: startingRAMEntries, lastCheckpointAt: Date())
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
            endReason: reason, startingRAMEntries: startingRAMEntries, modeChanges: changes, completeness: "complete", pausedSeconds: pausedSeconds)
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

    /// The newest saved run of each translation system in the current test, newest first.
    /// Falls back to all saved runs when the current test has none.
    var defaultReportSelection: [UUID] {
        let current = testRuns.filter { $0.testID == currentTestID }
        let pool = current.isEmpty ? testRuns : current
        var seen = Set<String>(), ids: [UUID] = []
        // 2.2.1 (D1): runs without timing are not comparable and are left out.
        for run in pool.sorted(by: { $0.endedAt > $1.endedAt }) where !run.noTiming && seen.insert(run.mode).inserted { ids.append(run.id) }
        return ids
    }

    @Published var sourceUsage = SourceLanguageUsage()
    @Published var executionPhase = "starting"
    var lastPacketAt: Date?
    var lastDeviceSampleAt: Date?
    @Published var speakerSession = SpeakerSession()
    @Published var started = Date()
    private var lastFrames = 0
    private var lastFrameTime = Date()
    var tickN = 0
    var lastState: EngineState?

    init() { UIDevice.current.isBatteryMonitoringEnabled = detailedCollection }

    /// Completed inference, not the elapsed time for a memory-only caption.
    /// This feeds the same live timing series as the Legacy pipeline.
    func recordModeModel(ms: Double, system: TranslationSystem) {
        guard enabled, ms.isFinite, ms >= 0 else { return }
        add(\.translate, ms)
        event(.translation, "Model completed in \(Int(ms)) ms · \(system.title)")
    }

    /// A reset during a run ends that run (reason diagnosticsReset) and starts a new one.
    func reset() {
        let wasRecording = activeRun != nil
        let wasPaused = pausedAt != nil
        if wasRecording { endRun(reason: "diagnosticsReset") } else { clearCollection() }
        if wasRecording { startRunState() }
        if wasPaused { pausedAt = Date(); pauseReason = "captureStopped" } // capture is still off
    }

    private func clearCollection() {
        modeTrace.removeAll(); openingModeTrace.removeAll()
        modeTimingSamples.removeAll(); modeEventCounts.removeAll()
        initialWarmupTrace.removeAll(); legacyModeContexts.removeAll(); legacyModeContextOrder.removeAll()
        diagnosticSessionID = UUID(); candidateIDs = [:]; frameIDs = [:]; unitIDs = [:]; structuredEvents = []
        legacyValidationSnapshot = [:]; legacyValidationPair = [:]
        eventTotals = [:]; intervalHistory = []; intervalStart = Date()
        oneSecondHistory = []; oneSecondStart = Date()
        fiveSecondHistory = []; fiveSecondStart = Date()
        openingEvents = []; earlyEventsSeen = 0
        intervalBaseline = [:]; oneSecondBaseline = [:]; fiveSecondBaseline = [:]
        lastCaptureConnected = false
        lastRecordedThermalState = nil
        detailSuspendedByThermal = false
        structuredEventsDropped = 0; idMapResets = 0; legacyContextResets = 0; subtitleTracesDropped = 0
        thermalStartLevel = ProcessInfo.processInfo.thermalState.rawValue
        thermalMaxLevel = ProcessInfo.processInfo.thermalState.rawValue
        memoryOutcomes = [:]; lookupSamples = []; writeSamples = []; historySaveSamples = []; lookupWaitSamples = []; memoryHealthSamples = []
        modelTimingSamples = [:]; completedWorkRecoveredUnits = 0
        confirmationReadSamples = []; confirmationFrameWaitSamples = []; rediscoveryLeadSamples = []
        captionDigestCache.removeAll(keepingCapacity: true)
        sharedModelUnits = 0; sharedConfirmedModelUnits = 0; memoryAwareSpeculationSkipped = 0; ramCaptionBypasses = 0; exactCaptionHits = 0; exactUnitsCoalesced = 0
        speculativeUnitCounts = [:]; queueWaitSamples = [:]
        pausedAt = nil; pausedTotal = 0; pauseReason = ""; captureRestartCount = 0
        captureStopCounts = [:]; extFreeMBAtLastStop = 0; secondsIntoRunAtLastStop = 0
        framesAtLastStop = 0; resumedSameBroadcast = 0; resumedNewBroadcast = 0; framesDuringLastGap = 0; longestStopGapSeconds = 0
        temporaryMemoryHits = 0; startingRAMEntries = ramEntryCount?() ?? 0
        // 2.3.2: the previous run's checkpoint cost must not appear in the next run's report.
        lastCheckpointCaptureMs = nil; checkpointCaptureMicros = 0
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
        s.earlyVisualWakesSuppressed = p.earlyVisualWakesSuppressed ?? s.earlyVisualWakesSuppressed
        s.largePackets = p.largePackets ?? s.largePackets
        s.packetSendErrors = p.sendErrors ?? s.packetSendErrors
        s.pixelConfirmations = p.pixelConfirmations ?? s.pixelConfirmations
        s.pixelRejections = p.pixelRejections ?? s.pixelRejections
        s.watchSkippedOCR = p.watchSkippedOCR ?? s.watchSkippedOCR
        s.watchTriggeredOCR = p.watchTriggeredOCR ?? s.watchTriggeredOCR
        s.focusRediscoveries = p.focusRediscoveries ?? s.focusRediscoveries
        // 2.4.0: what a confirmation needed, reported by the extension with the confirmed packet. Numbers only.
        if p.kind == "ocr", p.stable != false, let reads = p.confirmReads, reads > 0 {
            func keep(_ samples: inout [Double], _ value: Double) {
                guard value.isFinite, value >= 0 else { return }
                samples.append(value)
                if samples.count > 1200 { samples.removeFirst(samples.count - 1200) }
            }
            keep(&confirmationReadSamples, Double(reads))
            if let wait = p.confirmFrameWaitMs { keep(&confirmationFrameWaitSamples, wait) }
            if let lead = p.rediscoveryLeadMs { keep(&rediscoveryLeadSamples, lead) }
            if (p.confirmPixelRejections ?? 0) > 0 { s.confirmedWithPixelRejection += 1 }
        }
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

}
