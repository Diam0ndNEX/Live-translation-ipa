import Foundation

extension DiagnosticExportWriter {
    /// Defense in depth: diagnostic event labels are fixed reason codes, never
    /// raw OCR or translated text, even if a future producer calls us incorrectly.
    func redact(_ snapshot: DiagnosticSessionExport) -> DiagnosticSessionExport {
        let stageCodes: Set<String> = [
            "memory", "segmentation", "first OCR", "seen", "confirmed", "processing",
            "speculating", "cache", "ready", "enqueued", "superseded", "cancelled",
            "ocrCorrection", "language", "freshTranslation", "translationResult",
            "frame_arrival", "rotation", "ocr_execution", "duplicate_detection", "ocr_filtering",
            "stability", "text_grouping", "ocr_correction", "language_detection",
            "memory_lookup", "translation", "pip_preparation", "pip_enqueue", "runtime_state",
            "model_state", "cancellation", "queue_wait"
        ]
        let eventCodes: Set<String> = Set(MemoryDiagnosticOutcome.allCases.map { $0.rawValue })
            .union([
                "scheduling", "observed", "cache_hit", "computed", "accepted", "rejected_duplicate",
                "rejected_recent_fragment", "rejected_empty", "rejected_revision",
                "rejected_unstable", "rejected_low_confidence", "rejected_stale",
                "filtered", "confirmed", "speculative", "ready", "enqueued",
                "cancelled", "redacted", "completed", "deferred_early_candidate",
                "heartbeat_timeout", "capture_connected", "idle_auto_pause", "session_time_limit",
                "thermal_nominal", "thermal_fair", "thermal_serious", "thermal_critical", "detail_suspended_thermal", "pip_auto_open_skipped_not_active", "pip_start_unsupported", "pip_start_not_possible", "pip_start_not_hosted", "pip_start_failed", "pip_audio_session_failed",
                "changing_group_preferred", "dominant_group", "queue_replaced",
                "preserved_confirmed_work", "confirmed_handoff_deferred",
                "adaptive_speculation_backoff", "slow_tail", "handoff_expired", "handoff_replayed", "enqueue_failed",
                "warmup_started", "warmup_succeeded", "warmup_failed",
                "warmup_model_submitted", "speculative_model_submitted", "confirmed_model_submitted", "model_batch_cancelled",
                "warmup_model_completed", "speculative_model_completed", "confirmed_model_completed",
                "model_session_created", "model_batch_completed", "model_batch_failed",
                "speculative_session_created", "speculative_stop_requested", "speculative_stop_released",
                "warmup_source_unresolved", "warmup_predicted_source", "warmup_preempted",
                "model_batch_first_30s", "legacy_batch_committed", "legacy_idle_started", "legacy_idle_completed",
                "legacy_idle_deferred", "app_interface_visible", "external_capture_period", "app_started", "capture_config_changed",
                "capture_idle", "capture_live", "capture_paused", "capture_frozen",
                "legacy_queued_speculation_superseded", "legacy_speculation_low_confidence",
                "legacy_speculation_saved_memory_backoff", "legacy_speculation_low_yield_backoff",
                // found by guard C2 in 2.2.1: emitted by the engine, accepted by Diagnostics, dropped here
                "legacy_shared_session_used", "speculative_lease_conflict",
                "legacy_confirmed_own_lane", "legacy_detached_speculation_released", "legacy_confirmed_overlap_ms"
            ]).union(stageCodes)
        let safeEvents = snapshot.events.suffix(6000).map { event in
            StructuredDiagnosticEvent(id: event.id, timestamp: event.timestamp,
                sessionID: event.sessionID, candidateID: event.candidateID,
                frameID: event.frameID, unitID: event.unitID,
                stage: stageCodes.contains(event.stage) ? event.stage : "other",
                outcome: eventCodes.contains(event.outcome) ? event.outcome : "redacted",
                reasonCode: eventCodes.contains(event.reasonCode) ? event.reasonCode : "redacted",
                durationMs: event.durationMs.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                privacy: "metadataOnly")
        }
        let settingsKeys: Set<String> = [
            "legacyInventorySource", "legacyInventoryTarget",
            "mode", "speed", "stability", "frameRot", "area", "adaptiveOCR",
            "source", "target", "customY0", "customY1", "minTextH", "dropNoise",
            "boost", "ocrCorrection", "adaptive", "displayPolicy", "minDisplay",
            "clearHold", "autoClear", "keepWarm", "langLock",
            "selectiveSpeculation", "speculationConfidence", "confirmationDeadline",
            "remember", "privateSession", "diagnosticsEnabled", "detailedCollection",
            "skipUnchanged", "idleBackoff", "adaptiveConfirmation", "subtitleTracking",
            "translateAhead", "coolMode", "steadyCaptions", "ocrConfidence", "freshTranslationTest",
            "adaptiveSpeculation", "protectConfirmedPresentation", "predictiveWarmup",
            "lowLatencyTranslation", "incrementalBatchRecovery", "directPiPBuffer", "pixelConfirmation", "eventDrivenOCR", "fastOCR", "legacySharedSession",
            "subtitleAwareChangeDetection", "preserveRelatedMovieGroups",
            "deduplicateCopies", "contextualLanguage", "languageRecovery",
            "continuousRotation", "smartCool", "testRunSaving",
            "diagSamples", "heartbeatInterval", "keepAwake", "suppressOwnInterface",
            "temporaryMemoryTest", "translationTestMode", "startingRAMEntries",
            "rapidTextTracking", "joinAdjacentText", "activeTextFocus",
            "effectiveRapidTextTracking", "effectiveJoinAdjacentText", "effectiveActiveTextFocus",
            "thermalState", "performanceTier", "reductionReasons",
            "hotPathAB", "availabilityRefreshAB", "legacyOwnLaneAB", "heartbeatAB", "armedDeferAB", "detailSuspended",
            // 2.5.0
            "captureWarmAB", "storedTotalsAB", "readReasonsAB", "lengthBucketAB", "trustedBandAB", "headStartAB", "quietRewarmAB",
            // 2.2.1 (D4, E12)
            "idleMinutes", "sessionLimit", "autoOpenPiP", "winSize", "textSize", "pipFont", "theme", "showOriginal",
            "highlightNames", "pipScale", "pipWeight", "pipAlignment", "pipPadding",
            "focusedCaptionOCR", "strictCaptionIdentity", "thermalStart", "thermalEnd", "thermalMax", "cjkSingleCharacters", "liveWarmupLegacy",
            "appRequestedCaptureIntervalMs", "appRequestedCaptureEdgePx"
        ]
        let safeSettings = snapshot.settings.filter { pair in
            settingsKeys.contains(pair.key) && pair.value.utf8.count <= 48 &&
            pair.value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
            }
        }
        let reason = snapshot.measurementBoundary
        let safeBoundary = reason.utf8.count <= 512 &&
            (reason.hasPrefix("First OCR sighting") || reason == "OCR through PiP enqueue") ?
            reason : "OCR to PiP enqueue; detailed measurement boundary redacted"
        let safeHardware = snapshot.hardwareModel.flatMap { model -> String? in
            guard model.utf8.count <= 32,
                  model.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.contains($0) || $0 == "," ||
                      $0 == "-" || $0 == "_"
                  }) else { return nil }
            return model
        }
        // Defense in depth for all top-level counters too. The live producer
        // currently uses fixed keys, but the archive boundary must not rely
        // on future callers never accidentally supplying a source-text key.
        let extraCounters: Set<String> = [
            "structured_events_dropped", "id_map_resets", "legacy_context_resets", "subtitle_traces_dropped",
            "runCheckpointCaptureMicros", "captureRestarts", "runPausedSeconds", "captureStopsByPacket", "captureStopsByTimeout", "captureStopsByNewSession", "extensionFreeMBAtLastStop", "secondsIntoRunAtLastStop", "resumedSameBroadcast", "resumedNewBroadcast", "extensionFramesDuringLastGap", "longestStopGapSeconds", "legacyInventoryPending", "legacyInventoryOtherTarget", "legacyInventoryOtherSource",
            "legacyInventoryOutsideLength", "legacyInventoryCandidates", "legacySkipKeyContext",
            "legacySkipCleanup", "legacySkipSegmentation", "legacySkipModel",
            "sessionCacheHits", "savedMemoryHits", "speculativeModelRequests",
            "supersededSpeculativePipelines", "confirmedCandidatePackets",
            "deferredEarlyCandidates", "supersededUnpresentedConfirmed", "supersededConfirmedInFlight", "supersededConfirmedNotStarted",
            "enqueuedCandidateFrames", "unchangedSkippedFrames",
            "cadenceSkippedFrames", "earlyVisualWakes", "earlyVisualWakesSuppressed", "largePackets", "packetSendErrors",
            "pixelConfirmations", "pixelRejections", "watchSkippedOCR", "watchTriggeredOCR", "pausedSkippedFrames", "emptyReads",
            "contrastRetries", "emptyOCRPasses",
            "focusRediscoveries", "confirmedWithPixelRejection"
        ]
        let allowedCounters = DiagnosticIntervalBucket.allowedCounters
            .union(MemoryDiagnosticOutcome.allCases.map { $0.rawValue })
            .union(extraCounters)
            .union(V250Names.counters)
        let safeCounters = snapshot.counters.filter {
            allowedCounters.contains($0.key) && $0.value >= 0
        }
        // The archive must not silently accept arbitrary distribution keys or
        // nonfinite caller-supplied measurements. Reconstruct from bounded,
        // known timing statistics instead of copying potentially private labels.
        let allowedMetrics: Set<String> = [
            "memoryLookupMs", "memoryWriteMs", "historySaveMs", "memoryLookupWaitMs", "memoryHealthMs", "ocrMs", "translationMs",
            "enqueueLatencyMs", "finalOCRMs", "transportMs", "confirmationMs",
            "deliveryFilteringMs", "queueMs", "processingMs", "displayHoldMs",
            "renderingMs", "speculativeModelMs", "confirmedModelMs", "modelBatchMs",
            "modeAvailabilityCheckMs", "modeTaskDispatchMs", "modeSpeculativeQueueMs", "modeRecoveryQueueMs",
            "modeBackendLaneWaitMs", "modeSessionAgeMs", "modeSessionCompletedCalls",
            "modeCancellationReleaseMs",
            "modePlanBuiltMs", "modePlanReusedMs", "modeCommitToPiPMs",
            "modeConfirmationToPiPMs", "modeReadyToPiPMs",
            "speculativeStopReleaseMs", "legacyDetachedSpeculationReleaseMs", "queueBehindSpeculationMs", "queueBehindConfirmedMs", "queueSchedulingMs",
            "confirmedSupersededAgeMs",
            "legacyConfirmedOverlapMs", "confirmationOCRReads", "confirmationFrameWaitMs", "rediscoveryLeadMs",
            "legacyConfirmedAfterSessionSwitchMs", "legacyConfirmedNoSwitchMs",
        ]
        let safeMetrics = snapshot.distributions.filter { key, value in
            (allowedMetrics.contains(key) || V250Names.metrics.contains(key)) && value.count >= 0 &&
                value.mean.isFinite && value.mean >= 0 &&
                [value.p50, value.p90, value.p95, value.p99, value.maximum].allSatisfy {
                    $0 == nil || ($0!.isFinite && $0! >= 0)
                }
        }
        return DiagnosticSessionExport(translationModes: snapshot.translationModes?.sanitized(), id: snapshot.id, startedAt: snapshot.startedAt,
            endedAt: snapshot.endedAt, appVersion: snapshot.appVersion,
            systemVersion: snapshot.systemVersion, hardwareModel: safeHardware,
            settings: safeSettings,
            health: snapshot.health, counters: safeCounters,
            distributions: safeMetrics, events: safeEvents,
            intervals: snapshot.intervals.map { Array($0.suffix(960)).map { $0.sanitized() } },
            oneSecondIntervals: snapshot.oneSecondIntervals.map {
                Array($0.suffix(300)).map { $0.sanitized() }
            },
            fiveSecondIntervals: snapshot.fiveSecondIntervals.map {
                Array($0.suffix(180)).map { $0.sanitized() }
            },
            measurementBoundary: safeBoundary, textCapture: false)
    }

    /// Redacted copy for on-device storage (same allowlists as every export).
    func redactedForStorage(_ snapshot: DiagnosticSessionExport) -> DiagnosticSessionExport { redact(snapshot) }
}
