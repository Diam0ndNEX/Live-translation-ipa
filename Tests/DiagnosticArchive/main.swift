import Foundation

@main struct DiagnosticArchiveTests {
    static func main() async throws {
        let numbers = (1...100).map(Double.init)
        let dist = DiagnosticDistribution(numbers)
        precondition(dist.count == 100 && dist.p50 == 50 && dist.p90 == 90 &&
                     dist.p95 == 95 && dist.p99 == 99 && dist.maximum == 100)
        let tiny = DiagnosticDistribution([0.3])
        precondition(tiny.count == 1 && tiny.p90 == nil && tiny.p99 == nil)
        let session = UUID()
        let safeFrame = UUID()
        let safeUnit = UUID()
        let event = StructuredDiagnosticEvent(id: UUID(), timestamp: Date(),
            sessionID: session, candidateID: UUID(), frameID: safeFrame, unitID: safeUnit,
            stage: "memory", outcome: "persistentHit", reasonCode: "persistentHit",
            durationMs: 0.25, privacy: "metadataOnly")
        let snapshot = DiagnosticSessionExport(id: session, startedAt: Date(),
            endedAt: Date(), appVersion: "1.4.0", systemVersion: "test", hardwareModel: "iPhoneTest1,1",
            settings: ["speed": "balanced"], health: MemoryDiagnosticHealth(),
            counters: ["persistentHit": 1], distributions: ["memoryLookupMs": dist],
            events: [event], measurementBoundary: "OCR through PiP enqueue",
            textCapture: false)
        let writer = DiagnosticExportWriter()
        let indexed = try await writer.encodeIndexedEvents([event])
        precondition(indexed.count == 1 && indexed[0].payload.count <= 4096)
        let eventDecoder = JSONDecoder()
        eventDecoder.dateDecodingStrategy = .iso8601
        let decodedEvent = try eventDecoder.decode(
            StructuredDiagnosticEvent.self,
            from: indexed[0].payload)
        precondition(decodedEvent.sessionID == session &&
                     decodedEvent.unitID == safeUnit &&
                     decodedEvent.privacy == "metadataOnly")
        let privateEvent = StructuredDiagnosticEvent(id: UUID(), timestamp: Date(),
            sessionID: session, candidateID: nil, frameID: nil, unitID: nil,
            stage: "memory", outcome: "untrusted", reasonCode: "untrusted",
            durationMs: nil, privacy: "text")
        let sanitized = try await writer.encodeIndexedEvents([event, privateEvent])
        precondition(sanitized.count == 1,
                     "Indexed events must discard non-metadata privacy classifications")
        // The v1.4.0 exporter incorrectly labelled safe OCR timings as 'other'.
        let ocrEvent = StructuredDiagnosticEvent(id: UUID(), timestamp: Date(),
            sessionID: session, candidateID: UUID(), frameID: safeFrame, unitID: nil,
            stage: "ocr_execution", outcome: "completed", reasonCode: "completed",
            durationMs: 141, privacy: "metadataOnly")
        let ocrSnapshot = DiagnosticSessionExport(id: session, startedAt: Date(),
            endedAt: Date(), appVersion: "1.4.1", systemVersion: "test",
            settings: ["speed": "balanced"], health: MemoryDiagnosticHealth(),
            counters: [:], distributions: [:], events: [ocrEvent],
            measurementBoundary: "OCR through PiP enqueue", textCapture: false)
        let ocrBytes = try await writer.encode(ocrSnapshot)
        let ocrDecoded = try await writer.decode(ocrBytes)
        precondition(ocrDecoded.events[0].stage == "ocr_execution" &&
                     ocrDecoded.events[0].outcome == "completed" &&
                     ocrDecoded.events[0].durationMs == 141,
                     "Safe OCR labels and their timing must survive metadata-only export")
        // v1.4.4 performance events must retain only metadata and millisecond
        // durations. Source sentences / names never cross the archive boundary.
        let performanceEvents = [
            StructuredDiagnosticEvent(id: UUID(), timestamp: Date(),
                sessionID: session, candidateID: nil, frameID: nil, unitID: nil,
                stage: "model_state", outcome: "model_batch_first_30s",
                reasonCode: "model_batch_first_30s", durationMs: 998,
                privacy: "metadataOnly"),
            StructuredDiagnosticEvent(id: UUID(), timestamp: Date(),
                sessionID: session, candidateID: UUID(), frameID: safeFrame, unitID: nil,
                stage: "pip_enqueue", outcome: "slow_tail", reasonCode: "slow_tail",
                durationMs: 1400, privacy: "metadataOnly"),
            StructuredDiagnosticEvent(id: UUID(), timestamp: Date(),
                sessionID: session, candidateID: nil, frameID: nil, unitID: nil,
                stage: "model_state", outcome: "legacy_batch_committed",
                reasonCode: "legacy_batch_committed", durationMs: 1400,
                privacy: "metadataOnly")
        ]
        let performanceSnapshot = DiagnosticSessionExport(id: session,
            startedAt: Date(), endedAt: Date(), appVersion: "1.4.4",
            systemVersion: "test", settings: ["predictiveWarmup": "true"],
            health: MemoryDiagnosticHealth(),
            counters: ["slowTailEnqueues": 1, "handoffDeferred": 1,
                       "legacyInventoryPending": 103, "legacySkipSegmentation": 12, "specPreemptionRequested": 9,
                       "specRetainedUnits": 3,
                       "legacyBatchVerified": 24, "actualModelBatches": 7, "confirmedModelBatches": 2,
                       "speculativeModelBatches": 4, "warmupModelBatches": 1, "first30sModelBatches": 5,
                       "handoffReplayed": 1, "enqueueFailed": 1, "source text": 100],
            distributions: [:], events: performanceEvents,
            measurementBoundary: "OCR through PiP enqueue", textCapture: false)
        let performanceBytes = try await writer.encode(performanceSnapshot)
        let performanceRestored = try await writer.decode(performanceBytes)
        precondition(performanceRestored.counters["legacyBatchVerified"] == 24 &&
                     performanceRestored.counters["slowTailEnqueues"] == 1 &&
                     performanceRestored.counters["actualModelBatches"] == 7 &&
                     performanceRestored.counters["legacyInventoryPending"] == 103 &&
                     performanceRestored.counters["legacySkipSegmentation"] == 12 &&
                     performanceRestored.counters["specPreemptionRequested"] == 9 &&
                     performanceRestored.counters["specRetainedUnits"] == 3 &&
                     performanceRestored.counters["first30sModelBatches"] == 5 &&
                     performanceRestored.counters["handoffReplayed"] == 1 &&
                     performanceRestored.counters["enqueueFailed"] == 1 &&
                     performanceRestored.counters["source text"] == nil &&
                     performanceRestored.events.count == 3 &&
                     performanceRestored.events.allSatisfy { $0.privacy == "metadataOnly" },
                     "New duration/throughput counters must survive sanitization without private text")
        let traceLimit = 2400
        let longEvents = (0..<(traceLimit + 5)).map { index in
            StructuredDiagnosticEvent(id: UUID(), timestamp: Date().addingTimeInterval(Double(index)),
                sessionID: session, candidateID: UUID(), frameID: nil, unitID: nil,
                stage: "ocr_execution", outcome: "completed", reasonCode: "completed",
                durationMs: 10, privacy: "metadataOnly")
        }
        let longSnapshot = DiagnosticSessionExport(id: session, startedAt: Date(),
            endedAt: Date(), appVersion: "1.4.1", systemVersion: "test",
            settings: ["speed": "balanced"], health: MemoryDiagnosticHealth(),
            counters: [:], distributions: [:], events: longEvents,
            measurementBoundary: "OCR through PiP enqueue", textCapture: false)
        let boundedSnapshot = try await writer.decode(try await writer.encode(longSnapshot))
        precondition(boundedSnapshot.events.count == traceLimit &&
                     abs((boundedSnapshot.events.first?.timestamp.timeIntervalSince1970 ?? 0) -
                         longEvents[5].timestamp.timeIntervalSince1970) < 1.0,
                     "Long diagnostics retain the most recent 2400 structured events")
        let bytes = try await writer.encode(snapshot)
        let recovered = try await writer.decode(bytes)
        precondition(recovered.id == session && recovered.events.count == 1)
        precondition(recovered.events[0].frameID == safeFrame &&
                     recovered.events[0].unitID == safeUnit)
        precondition(recovered.events[0].privacy == "metadataOnly" &&
                     recovered.textCapture == false)
        let exported = String(decoding: bytes, as: UTF8.self)
        precondition(!exported.contains("v4|secret subtitle") &&
                     !exported.contains("private source text"))

        // v1.4.1 whole-session evidence is strictly metadata-only and
        // supports older ZIPs without the new optional interval field.
        var withIntervals = snapshot
        withIntervals.intervals = [
            DiagnosticIntervalBucket(startedAt: Date(), elapsedSeconds: 15,
                counters: ["ocrPackets": 3, "candidateEnqueued": 1,
                           "private OCR text": 100, "captureFrames": -1],
                thermalLevel: 2, lowPower: false, captureConnected: true)
        ]
        withIntervals.oneSecondIntervals = [
            DiagnosticIntervalBucket(startedAt: Date(), elapsedSeconds: 1,
                counters: ["candidateConfirmed": 1, "enqueueFailed": 1],
                thermalLevel: 0, lowPower: false, captureConnected: true)
        ]
        withIntervals.fiveSecondIntervals = [
            DiagnosticIntervalBucket(startedAt: Date(), elapsedSeconds: 5,
                counters: ["candidateConfirmed": 4, "enqueueFailed": 1],
                thermalLevel: 0, lowPower: false, captureConnected: true)
        ]
        let intervalBytes = try await writer.encode(withIntervals)
        let checkedInterval = try await writer.decode(intervalBytes)
        precondition(checkedInterval.intervals?.count == 1)
        precondition(checkedInterval.oneSecondIntervals?.first?.elapsedSeconds == 1 &&
                     checkedInterval.fiveSecondIntervals?.first?.elapsedSeconds == 5,
                     "Both high-resolution interval types must survive diagnostic encoding")
        precondition(checkedInterval.intervals?.first?.counters == [
            "ocrPackets": 3, "candidateEnqueued": 1
        ], "Unknown or negative metrics must never cross the ZIP privacy boundary")
        precondition(!String(decoding: intervalBytes, as: UTF8.self).contains("private OCR text"))
        var oldWithoutIntervals = try JSONSerialization.jsonObject(with: intervalBytes) as! [String: Any]
        oldWithoutIntervals.removeValue(forKey: "intervals")
        oldWithoutIntervals.removeValue(forKey: "oneSecondIntervals")
        oldWithoutIntervals.removeValue(forKey: "fiveSecondIntervals")
        let previousBundle = try JSONSerialization.data(withJSONObject: oldWithoutIntervals)
        let decodedPreviousBundle = try await writer.decode(previousBundle)
        precondition(decodedPreviousBundle.oneSecondIntervals == nil &&
                     decodedPreviousBundle.fiveSecondIntervals == nil,
                     "Pre-1.5.0 archives without high-resolution buckets must decode")
        precondition(decodedPreviousBundle.intervals == nil,
                     "Existing 1.4.0 diagnostic archives must remain decodable")

        let matching = DiagnosticPerformanceComparison(baseline: snapshot, current: snapshot)
        precondition(matching.comparable &&
                     abs(matching.p95Changes["memoryLookupMs", default: 100]) < 0.00001)
        let mixedTiming = DiagnosticSessionExport(id: UUID(), startedAt: Date(), endedAt: Date(),
            appVersion: "1.5.0", systemVersion: snapshot.systemVersion, hardwareModel: snapshot.hardwareModel,
            settings: snapshot.settings, health: snapshot.health, counters: [:],
            distributions: ["memoryLookupMs": DiagnosticDistribution(
                Array(repeating: 60.0, count: 90) + Array(repeating: 90.0, count: 10))],
            events: [], measurementBoundary: snapshot.measurementBoundary, textCapture: false)
        let mixedComparison = DiagnosticPerformanceComparison(baseline: snapshot, current: mixedTiming)
        precondition(mixedComparison.comparable &&
                     mixedComparison.medianChanges["memoryLookupMs", default: 0] > 0 &&
                     mixedComparison.p95Changes["memoryLookupMs", default: 0] < 0,
                     "A better tail must never conceal a slower typical result")
        // A matching OS and settings do not establish a comparable baseline if
        // the device hardware changed or the older archive lacked a model code.
        var differentHardware = snapshot
        differentHardware.hardwareModel = "iPhoneOther2,1"
        precondition(!DiagnosticPerformanceComparison(
            baseline: snapshot, current: differentHardware).comparable)
        var legacyHardware = snapshot
        legacyHardware.hardwareModel = nil
        precondition(!DiagnosticPerformanceComparison(
            baseline: snapshot, current: legacyHardware).comparable)

        let mismatch = DiagnosticSessionExport(id: UUID(), startedAt: Date(), endedAt: Date(),
            appVersion: "1.4.0", systemVersion: "test",
            settings: ["speed": "sharp"], health: MemoryDiagnosticHealth(),
            counters: [:], distributions: ["memoryLookupMs": dist], events: [],
            measurementBoundary: "OCR through PiP enqueue", textCapture: false)
        precondition(!DiagnosticPerformanceComparison(
            baseline: snapshot, current: mismatch).comparable,
            "Different settings cannot be reported as controlled performance evidence")

        // New health metadata must not make previously persisted sessions unreadable.
        var oldJSON = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var previousHealth = oldJSON["health"] as! [String: Any]
        previousHealth.removeValue(forKey: "categoryCounts")
        oldJSON["health"] = previousHealth
        let oldArchive = try JSONSerialization.data(withJSONObject: oldJSON)
        let oldSession = try await writer.decode(oldArchive)
        precondition(oldSession.health.categoryCounts.isEmpty,
                     "Legacy diagnostic sessions must remain readable")

        var healthWithConflict = MemoryDiagnosticHealth()
        healthWithConflict.conflicts = 2
        healthWithConflict.failedWrites = 1
        healthWithConflict.migrationStatus = "partial_recovery"
        let evidence = DiagnosticSessionExport(id: UUID(), startedAt: Date(),
            endedAt: Date(), appVersion: "1.4.0", systemVersion: "test",
            settings: ["speed": "balanced"], health: healthWithConflict,
            counters: ["timeout": 4, "persistentHit": 16, "writeFailed": 1],
            distributions: [:], events: [], measurementBoundary: "test", textCapture: false)
        let findings = DiagnosticIssueDetector.assess(evidence)
        precondition(Set(findings.map(\.code)) == Set([
            "memory_write_failure", "memory_conflict", "migration_recovery", "memory_lookup_timeouts"
        ]), "Only evidence-backed diagnostic signals should be emitted")
        precondition(findings.first(where: { $0.code == "memory_lookup_timeouts" })?.classification == "suspected")
        let insufficient = DiagnosticSessionExport(id: UUID(), startedAt: Date(), endedAt: Date(),
            appVersion: "1.4.0", systemVersion: "test", settings: [:], health: MemoryDiagnosticHealth(),
            counters: ["timeout": 1, "persistentHit": 1], distributions: [:], events: [],
            measurementBoundary: "test", textCapture: false)
        precondition(DiagnosticIssueDetector.assess(insufficient).isEmpty,
                     "Low sample counts cannot justify a latency regression finding")
        var continuityEvidence = insufficient
        continuityEvidence = DiagnosticSessionExport(
            id: UUID(), startedAt: Date(), endedAt: Date(),
            appVersion: "1.5.0", systemVersion: "test",
            settings: ["lowLatencyTranslation": "true", "directPiPBuffer": "false"],
            health: MemoryDiagnosticHealth(),
            counters: [
                "confirmedCandidatePackets": 100, "supersededUnpresentedConfirmed": 11,
                "enqueueFailed": 2
            ],
            distributions: [
                "enqueueLatencyMs": DiagnosticDistribution(
                    Array(repeating: 1500.0, count: 94) + Array(repeating: 4400.0, count: 6))
            ],
            events: [], measurementBoundary: "OCR through PiP enqueue", textCapture: false)
        let continuityFindings = DiagnosticIssueDetector.assess(continuityEvidence)
        precondition(Set(continuityFindings.map(\.code)).isSuperset(of: [
            "confirmed_continuity_loss", "pip_enqueue_failure",
            "enqueue_slow_tail", "enqueue_typical_latency"
        ]), "Diagnostic findings must identify normal latency, slow tail and continuity separately")
        let safeContinuity = try await writer.decode(try await writer.encode(continuityEvidence))
        precondition(safeContinuity.settings["lowLatencyTranslation"] == "true" &&
                     safeContinuity.settings["directPiPBuffer"] == "false",
                     "Current model and PiP experiment flags must survive redacted exports")
        let newModeSnapshot = DiagnosticSessionExport(
            id: session, startedAt: Date(), endedAt: Date(), appVersion: "1.7.1", systemVersion: "test",
            settings: ["temporaryMemoryTest": "true", "translationTestMode": "temporaryMemory",
                       "startingRAMEntries": "12", "suppressOwnInterface": "true", "glossary": "private"],
            health: MemoryDiagnosticHealth(), counters: ["completedConfirmedUnitsRetained": 3,
                       "temporaryMemoryHits": 12, "bypassedLookups": 0, "lookupMisses": 0,
                       "sharedConfirmedInFlightUnits": 2, "speculativeStopRequests": 3, "speculativeSessionsCreated": 4, "memoryAwareSpeculationSkipped": 11, "ramCaptionBypasses": 7, "savedUnitsPrefetched": 13, "savedCaptionBypasses": 6, "speculationBudgetSkipped": 8, "warmSessionTransfers": 10, "uncachedUnits": 5, "sharedInFlightUnits": 2, "speculativeUnitsReused": 4],
            distributions: ["speculativeStopReleaseMs": DiagnosticDistribution([2, 3]),
                            "queueBehindSpeculationMs": DiagnosticDistribution([30, 40])],
            events: [StructuredDiagnosticEvent(id: UUID(), timestamp: Date(), sessionID: session,
                candidateID: nil, stage: "runtime_state", outcome: "external_capture_period",
                reasonCode: "external_capture_period", durationMs: nil, privacy: "metadataOnly"),
                StructuredDiagnosticEvent(id: UUID(), timestamp: Date(), sessionID: session,
                    candidateID: nil, stage: "runtime_state", outcome: "capture_stopped",
                    reasonCode: "capture_stopped", durationMs: nil, privacy: "metadataOnly")],
            measurementBoundary: "OCR through PiP enqueue", textCapture: false)
        let newModeRoundtrip = try await writer.decode(try await writer.encode(newModeSnapshot))
        precondition(newModeRoundtrip.settings["translationTestMode"] == "temporaryMemory" &&
                     newModeRoundtrip.settings["startingRAMEntries"] == "12" &&
                     newModeRoundtrip.settings["suppressOwnInterface"] == "true" &&
                     newModeRoundtrip.settings["glossary"] == nil,
                     "Fixed test metadata must survive export while user wording stays excluded")
        precondition(newModeRoundtrip.counters["completedConfirmedUnitsRetained"] == 3 &&
                     newModeRoundtrip.counters["temporaryMemoryHits"] == 12 &&
                     newModeRoundtrip.counters["sharedInFlightUnits"] == 2 &&
                     newModeRoundtrip.counters["ramCaptionBypasses"] == 7 &&
                     newModeRoundtrip.counters["savedUnitsPrefetched"] == 13 &&
                     newModeRoundtrip.counters["savedCaptionBypasses"] == 6 &&
                     newModeRoundtrip.counters["speculationBudgetSkipped"] == 8 &&
                     newModeRoundtrip.counters["warmSessionTransfers"] == 10 &&
                     newModeRoundtrip.counters["memoryAwareSpeculationSkipped"] == 11 &&
                     newModeRoundtrip.counters["speculativeStopRequests"] == 3 &&
                     newModeRoundtrip.counters["sharedConfirmedInFlightUnits"] == 2 &&
                     newModeRoundtrip.counters["speculativeSessionsCreated"] == 4 &&
                     newModeRoundtrip.distributions["speculativeStopReleaseMs"]?.count == 2 &&
                     newModeRoundtrip.distributions["queueBehindSpeculationMs"]?.count == 2,
                     "New timing and reuse fields must not disappear in archive filtering")
        precondition(newModeRoundtrip.events.contains { $0.reasonCode == "capture_stopped" },
                     "Explicit capture stop must remain readable through archive privacy filtering")
        precondition(newModeRoundtrip.events[0].reasonCode == "external_capture_period",
                     "Fixed app-visibility codes must remain readable, not redacted")

        let unsafeDistribution = DiagnosticSessionExport(
            id: UUID(), startedAt: Date(), endedAt: Date(),
            appVersion: "1.5.0", systemVersion: "test",
            settings: ["lowLatencyTranslation": "true"], health: MemoryDiagnosticHealth(),
            counters: [:],
            distributions: [
                "enqueueLatencyMs": DiagnosticDistribution([12.0]),
                "private subtitle text": DiagnosticDistribution([1.0])
            ],
            events: [], measurementBoundary: "OCR through PiP enqueue", textCapture: false)
        let safeDistribution = try await writer.decode(try await writer.encode(unsafeDistribution))
        precondition(safeDistribution.distributions["private subtitle text"] == nil,
                     "Dynamic metric labels must not bypass the privacy allowlist")
        let tooSmall = DiagnosticSessionExport(
            id: UUID(), startedAt: Date(), endedAt: Date(),
            appVersion: "1.5.0", systemVersion: "test",
            settings: [:], health: MemoryDiagnosticHealth(),
            counters: ["confirmedCandidatePackets": 6, "supersededUnpresentedConfirmed": 1],
            distributions: ["enqueueLatencyMs": DiagnosticDistribution([4000])],
            events: [], measurementBoundary: "test", textCapture: false)
        precondition(DiagnosticIssueDetector.assess(tooSmall).isEmpty,
                     "A short run must not be treated as a statistical regression")

        let zipBytes = try DiagnosticStoredZIP.make(entries: [
            (name: "session.json", contents: bytes),
            (name: "README.txt", contents: Data("Offline diagnostics only".utf8))
        ])
        precondition(Array(zipBytes.prefix(4)) == [0x50, 0x4b, 0x03, 0x04],
                     "ZIP must begin with a standard local-file header")
        precondition(zipBytes.range(of: Data("session.json".utf8)) != nil,
                     "ZIP must include the metadata-only session export")
        let zipFooter = Array(zipBytes.suffix(22).prefix(4))
        precondition(zipFooter == [0x50, 0x4b, 0x05, 0x06],
                     "ZIP must have a valid end-of-central-directory signature")
        let exportedZIP = try await writer.exportZIP(withIntervals)
        defer { try? FileManager.default.removeItem(at: exportedZIP) }
        precondition(FileManager.default.fileExists(atPath: exportedZIP.path))
        let exportedZipData = try Data(contentsOf: exportedZIP)
        precondition(exportedZipData.range(of: Data("intervals.csv".utf8)) != nil,
                     "New ZIP bundles must contain the full-session interval CSV")
        for filename in ["manifest.json", "summary.md", "session.json",
                         "intervals.csv", "seconds_1.csv", "seconds_5.csv",
                         "metrics.csv", "events.csv",
                         "findings.json", "README.txt"] {
            precondition(exportedZipData.range(of: Data(filename.utf8)) != nil,
                         "Version 3 evidence ZIP must include \(filename)")
        }
        precondition(exportedZipData.range(of: Data("private OCR text".utf8)) == nil,
                     "Diagnostic ZIP must never include raw text from unsafe fields")
        precondition(exportedZipData.range(of: Data("original subtitle".utf8)) == nil,
                     "Structured evidence must remain content-free")

        #if os(macOS)
        // Check interoperability with the system ZIP reader, not only our own
        // header checks, before considering bundles trustworthy for export.
        let archiveCheck = Process()
        archiveCheck.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        archiveCheck.arguments = ["-t", exportedZIP.path]
        archiveCheck.standardOutput = Pipe()
        archiveCheck.standardError = Pipe()
        try archiveCheck.run()
        archiveCheck.waitUntilExit()
        precondition(archiveCheck.terminationStatus == 0, "ZIP bundle must pass unzip -t")

        func entry(_ name: String) throws -> Data {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            task.arguments = ["-p", exportedZIP.path, name]
            let pipe = Pipe()
            task.standardOutput = pipe
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            precondition(task.terminationStatus == 0, "ZIP entry must be readable: \(name)")
            return data
        }
        let manifestData = try entry("manifest.json")
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
        precondition(manifest["bundleSchemaVersion"] as? Int == 3 &&
                     manifest["privacy"] as? String == "metadataOnly" &&
                     manifest["textIncluded"] as? Bool == false,
                     "Manifest must declare v3 structure and no content capture")
        let summary = String(decoding: try entry("summary.md"), as: UTF8.self)
        precondition(summary.contains("Confirmed but superseded before enqueue") &&
                     summary.contains("physical display") &&
                     summary.contains("## Normal performance") &&
                     summary.contains("unavailable (0 samples)"),
                     "Readable summary must distinguish continuity, timing boundaries and missing measurements")
        let fastCSV = String(decoding: try entry("seconds_1.csv"), as: UTF8.self)
        let shortCSV = String(decoding: try entry("seconds_5.csv"), as: UTF8.self)
        precondition(fastCSV.contains("elapsed_seconds") &&
                     fastCSV.contains("candidateConfirmed") &&
                     shortCSV.contains("enqueueFailed"),
                     "High-resolution buckets must preserve the time and events needed to inspect stalls")
        let metrics = String(decoding: try entry("metrics.csv"), as: UTF8.self)
        precondition(metrics.hasPrefix("metric,samples,mean_ms,p50_ms,p90_ms,p95_ms,p99_ms,max_ms"),
                     "Timing CSV must carry sample counts, typical and tail percentiles")
        let eventsCSV = String(decoding: try entry("events.csv"), as: UTF8.self)
        precondition(eventsCSV.contains("candidate_id") &&
                     !eventsCSV.contains("private OCR text"),
                     "Event CSV must retain anonymized correlations without source text")
        #endif
        let unsafeEvent = StructuredDiagnosticEvent(id: UUID(), timestamp: Date(),
            sessionID: session, candidateID: UUID(), frameID: nil, unitID: nil,
            stage: "private source text", outcome: "private source text",
            reasonCode: "private source text", durationMs: 0.2, privacy: "metadataOnly")
        let unsafeSnapshot = DiagnosticSessionExport(id: session, startedAt: Date(),
            endedAt: Date(), appVersion: "1.4.0", systemVersion: "test",
            settings: ["speed": "balanced", "glossary": "private source text"],
            health: MemoryDiagnosticHealth(), counters: [:], distributions: [:],
            events: [unsafeEvent], measurementBoundary: "private source text",
            textCapture: false)
        let redacted = try await writer.encode(unsafeSnapshot)
        precondition(!String(decoding: redacted, as: UTF8.self).contains("private source text"),
                     "Standard reports must not leak text via event reason or settings")
        let protectedEvents = try await writer.encodeIndexedEvents([unsafeEvent])
        precondition(protectedEvents.count == 1)
        precondition(!String(decoding: protectedEvents[0].payload, as: UTF8.self).contains("private source text"),
                     "Indexed events must share the same privacy boundary")
        // Review events through stable candidate and frame UUIDs without
        // leaking untrusted stage/reason strings to the UI.
        let candidateA = UUID(), candidateB = UUID(), base = Date()
        func traceEvent(_ candidate: UUID, _ offset: Double, _ stage: String,
                        _ reason: String, _ privacy: String = "metadataOnly") -> StructuredDiagnosticEvent {
            StructuredDiagnosticEvent(id: UUID(), timestamp: base.addingTimeInterval(offset),
                sessionID: session, candidateID: candidate, frameID: safeFrame, unitID: safeUnit,
                stage: stage, outcome: reason, reasonCode: reason,
                durationMs: 1.25, privacy: privacy)
        }
        let reviewed = DiagnosticTraceReview.review([
            traceEvent(candidateA, 0, "first OCR", "observed"),
            traceEvent(candidateA, 0.1, "segmentation", "computed"),
            traceEvent(candidateA, 0.2, "enqueued", "enqueued"),
            traceEvent(candidateB, 0.3, "cancelled", "cancelled"),
            traceEvent(candidateA, 0.4, "untrusted subtitle text", "secret lyric"),
            traceEvent(candidateB, 0.5, "memory", "private words", "text")
        ], limit: 10)
        precondition(reviewed.count == 2)
        guard let firstCandidate = reviewed.first(where: { $0.id == candidateA }),
              let secondCandidate = reviewed.first(where: { $0.id == candidateB })
        else { preconditionFailure("Correlation lost a candidate") }
        precondition(firstCandidate.frameCount == 1 && firstCandidate.stages.count == 4)
        precondition(firstCandidate.status.contains("PiP buffer enqueued"))
        precondition(firstCandidate.stages.last?.stage == "other" &&
                     firstCandidate.stages.last?.reason == "unclassified",
                     "Potential source text must never appear as a displayed stage or reason")
        precondition(secondCandidate.stages.count == 1 &&
                     secondCandidate.status == "Superseded or cancelled",
                     "Privacy-incompatible events must be ignored")
        precondition(DiagnosticTraceReview.review([], limit: 5).isEmpty)
        let failedEnqueue = DiagnosticTraceReview.review([
            traceEvent(candidateA, 0, "model_state", "confirmed_model_completed"),
            traceEvent(candidateA, 0.1, "pip_enqueue", "enqueue_failed")
        ])
        precondition(failedEnqueue.first?.status == "PiP frame preparation or enqueue failed" &&
                     failedEnqueue.first?.stages.first?.stage == "model_state",
                     "A failed enqueue must never be labelled as successful presentation")
        let recoveredEnqueue = DiagnosticTraceReview.review([
            traceEvent(candidateA, 0, "pip_enqueue", "enqueue_failed"),
            traceEvent(candidateA, 0.1, "enqueued", "enqueued")
        ])
        precondition(recoveredEnqueue.first?.status.contains("PiP buffer enqueued") == true,
                     "An actual later successful enqueue must remain visible")
        print("Diagnostic percentile, privacy, correlation, compatibility and comparison passed")
    }
}

