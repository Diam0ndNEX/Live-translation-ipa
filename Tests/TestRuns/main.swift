import Foundation

// Test Runs storage tests (v2.0.0 build 84, spec §11.8). Compiled standalone with
// DiagnosticArchive.swift and TestRunStore.swift; run from the repository root.

@main struct TestRunTests {
    static let hash = String(repeating: "a", count: 64)

    static func modeEvent(_ session: UUID, _ index: Int, mode: String = "legacy", reason: String = "confirmed",
                          caption: String? = nil) -> TranslationModeTrace {
        TranslationModeTrace(mode: mode, testMode: "normal", session: session, caption: caption ?? hash,
            revision: index % 5, source: "pt", target: "en", fingerprint: hash, reason: reason,
            monotonicTime: Double(index) * 0.1, firstOCR: 1, durationMs: Double(index % 700), thermal: 0)
    }

    static func structuredEvents(_ session: UUID, count: Int) -> [StructuredDiagnosticEvent] {
        (0..<count).map { index in
            StructuredDiagnosticEvent(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 0.1),
                sessionID: session, candidateID: UUID(), frameID: UUID(), unitID: UUID(),
                stage: "memory", outcome: "persistentHit", reasonCode: "persistentHit",
                durationMs: Double(index % 400) / 7, privacy: "metadataOnly")
        }
    }

    static func buckets(_ count: Int, seconds: Double, thermal: (Int) -> Int = { _ in 0 }) -> [DiagnosticIntervalBucket] {
        (0..<count).map { index in
            DiagnosticIntervalBucket(startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * seconds),
                elapsedSeconds: seconds, counters: ["ocrPackets": index % 9, "candidateEnqueued": index % 3],
                thermalLevel: thermal(index), lowPower: false, captureConnected: true)
        }
    }

    /// A synthetic run at the full caps from the spec: 2,400 + 2,400 events, 300 + 180 + 20 buckets.
    static func fullRun(mode: String = "legacy", seconds: Double = 300, id: UUID = UUID(), events: Int = 2400,
                        modeCounters: [String: Int] = [:], modeDistributions: [String: DiagnosticDistribution] = [:],
                        counters: [String: Int]? = nil, withLatency: Bool = true,
                        thermal: @escaping (Int) -> Int = { _ in 0 }) -> DiagnosticSessionExport {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let report = TranslationModeReport(active: mode, pending: mode, referenceSHA: String(repeating: "b", count: 40),
            migration: "persisted", events: (0..<events).map { modeEvent(id, $0, mode: mode) },
            distributions: modeDistributions, counters: modeCounters)
        let samples = (1...400).map { Double($0) }
        return DiagnosticSessionExport(translationModes: report, id: id, startedAt: start,
            endedAt: start.addingTimeInterval(seconds), appVersion: "v2.0.0 (build 84)", systemVersion: "26.0",
            hardwareModel: "iPhoneTest1,1", settings: ["thermalState": "nominal", "speed": "balanced", "startingRAMEntries": "0"],
            health: MemoryDiagnosticHealth(),
            counters: counters ?? ["enqueuedCandidateFrames": 54, "captureFrames": 3000],
            distributions: withLatency ? ["enqueueLatencyMs": DiagnosticDistribution(samples), "ocrMs": DiagnosticDistribution(samples)]
                                       : ["ocrMs": DiagnosticDistribution(samples)],
            events: structuredEvents(id, count: events), intervals: buckets(20, seconds: 15, thermal: thermal),
            oneSecondIntervals: buckets(300, seconds: 1), fiveSecondIntervals: buckets(180, seconds: 5),
            measurementBoundary: "First OCR sighting to PiP sample-buffer enqueue", textCapture: false)
    }

    static func meta(_ snapshot: DiagnosticSessionExport, test: UUID = UUID(), pinned: Bool = false,
                     changes: [String] = []) -> TestRunMeta {
        TestRunMeta.make(snapshot: snapshot, testID: test, testName: "2.0.0 test 1", endReason: "captureStopped",
                         startingRAMEntries: 0, modeChanges: changes, completeness: "complete", pinned: pinned)
    }

    static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("screenlingo-testruns-\(UUID().uuidString)")
    }

    static func saved(_ result: TestRunSaveResult) -> TestRunMeta {
        guard case .saved(let meta) = result else { preconditionFailure("expected saved, got \(result)") }
        return meta
    }

    static func main() async throws {
        let writer = DiagnosticExportWriter()

        // 1. Full-cap round trip: saves, prints the compressed size, stays under 8 MB without trimming.
        do {
            let store = TestRunStore(directory: tempDirectory())
            let snapshot = fullRun()
            let result = await store.save(meta: meta(snapshot), snapshot: snapshot)
            let stored = saved(result)
            print("full-cap run: compressed \(stored.bytes) bytes")
            precondition(stored.bytes < 8 * 1024 * 1024, "full-cap run must fit without trimming")
            precondition(stored.trimmed.isEmpty && stored.completeness == "complete")
            let loaded = try await store.load(id: snapshot.id)
            precondition(loaded.1.events.count == 2400 && loaded.1.translationModes?.events.count == 2400)
            precondition(loaded.1.oneSecondIntervals?.count == 300 && loaded.1.fiveSecondIntervals?.count == 180)
            precondition(loaded.0.mode == "legacy" && loaded.0.captions >= 54, "captions = max(enqueued counter, enqueue samples)")
            let index = await store.index()
            precondition(index.runs.count == 1 && index.runs[0].id == snapshot.id)
        }

        // 2. Oversize runs are trimmed in the documented order, marked trimmed, and never rejected.
        do {
            let snapshot = fullRun()
            let (noBuckets, first) = TestRunStore.trim(snapshot, step: 0)!
            precondition(first == "oneSecondBuckets" && noBuckets.oneSecondIntervals == nil)
            let (fewerEvents, second) = TestRunStore.trim(snapshot, step: 1)!
            precondition(second == "oldestStructuredEvents" && fewerEvents.events.count == 1200)
            precondition(fewerEvents.events.first!.timestamp == snapshot.events[1200].timestamp, "oldest events go first")
            let (fewerTrace, third) = TestRunStore.trim(snapshot, step: 2)!
            precondition(third == "oldestModeTrace" && fewerTrace.translationModes!.events.count == 1200)
            let store = TestRunStore(directory: tempDirectory(), maximumRunBytes: 120 * 1024)
            let stored = saved(await store.save(meta: meta(snapshot), snapshot: snapshot))
            precondition(stored.completeness == "trimmed", "trimmed runs say so")
            precondition(stored.trimmed.first == "oneSecondBuckets" && !stored.trimmed.isEmpty)
            let impossible = TestRunStore(directory: tempDirectory(), maximumRunBytes: 1)
            let other = fullRun()
            _ = saved(await impossible.save(meta: meta(other), snapshot: other)) // never fails for size
            let loaded = try await impossible.load(id: other.id)
            precondition(loaded.0.trimmed.count == 3, "all three trims were applied and recorded")
        }

        // 3. Retention: pinned runs survive; unpinned are pruned by count and by size.
        do {
            let store = TestRunStore(directory: tempDirectory(), maximumUnpinnedRuns: TestRunStore.keepUnpinned)
            let test = UUID()
            var ids: [UUID] = []
            for index in 0..<45 {
                var snapshot = fullRun(seconds: 60, id: UUID(), events: 20)
                snapshot = DiagnosticSessionExport(translationModes: snapshot.translationModes, id: snapshot.id,
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 100),
                    endedAt: Date(timeIntervalSince1970: 1_700_000_060 + Double(index) * 100),
                    appVersion: snapshot.appVersion, systemVersion: snapshot.systemVersion,
                    hardwareModel: snapshot.hardwareModel, settings: snapshot.settings, health: snapshot.health,
                    counters: snapshot.counters, distributions: snapshot.distributions, events: snapshot.events,
                    measurementBoundary: snapshot.measurementBoundary, textCapture: false)
                let pinned = index < 2 // the two oldest runs
                _ = saved(await store.save(meta: meta(snapshot, test: test, pinned: pinned), snapshot: snapshot))
                ids.append(snapshot.id)
            }
            let index = await store.index()
            precondition(index.runs.filter { !$0.pinned }.count == TestRunStore.keepUnpinned, "newest 40 unpinned kept")
            precondition(index.runs.filter { $0.pinned }.count == 2, "pinned runs are never pruned")
            precondition(index.runs.contains { $0.id == ids[0] } && index.runs.contains { $0.id == ids[1] })
            precondition(!index.runs.contains { $0.id == ids[2] } && index.pruneNote != nil)
            let files = try FileManager.default.contentsOfDirectory(atPath: await store.directoryPath())
                .filter { $0.hasSuffix(".json.lzfse") }
            precondition(files.count == 42, "pruned files are deleted from disk")
            let removed = await store.deleteAllUnpinned()
            let afterDelete = await store.index().runs.count
            precondition(removed == 40 && afterDelete == 2)

            let sized = TestRunStore(directory: tempDirectory(), maximumTotalBytes: 1)
            let first = fullRun(), second = fullRun(), pinnedRun = fullRun()
            _ = saved(await sized.save(meta: meta(pinnedRun, pinned: true), snapshot: pinnedRun))
            _ = saved(await sized.save(meta: meta(first), snapshot: first))
            _ = saved(await sized.save(meta: meta(second), snapshot: second))
            let kept = await sized.index().runs
            precondition(kept.count == 1 && kept[0].id == pinnedRun.id, "size pruning removes unpinned runs only")
        }

        // 4. Checkpoint -> simulated relaunch -> recovered run.
        do {
            let directory = tempDirectory()
            let first = TestRunStore(directory: directory)
            let snapshot = fullRun(seconds: 90)
            let wrote = await first.checkpoint(meta: meta(snapshot), snapshot: snapshot)
            let beforeRecover = await first.index().runs.count
            precondition(wrote && beforeRecover == 0, "a checkpoint is not a saved run")
            let relaunched = TestRunStore(directory: directory)
            let recovered = await relaunched.recover()
            precondition(recovered.count == 1 && recovered[0].completeness == "recovered" && recovered[0].endReason == "recovered")
            let loaded = try await relaunched.load(id: snapshot.id)
            precondition(loaded.1.events.count == 2400)
            let secondRecover = await relaunched.recover()
            precondition(secondRecover.isEmpty, "the checkpoint is consumed")
            // A normally saved run removes its checkpoint.
            let again = fullRun()
            let wroteAgain = await relaunched.checkpoint(meta: meta(again), snapshot: again)
            precondition(wroteAgain)
            _ = saved(await relaunched.save(meta: meta(again), snapshot: again))
            let leftover = await TestRunStore(directory: directory).recover()
            precondition(leftover.isEmpty)
        }

        // 5. Migration from diagnostic_sessions rows (old pretty-printed payloads) -> imported runs, once.
        do {
            let store = TestRunStore(directory: tempDirectory())
            let old = fullRun(mode: "lowLatency", seconds: 120)
            let payload = try await writer.encode(old)
            let imported = await store.migrate(payloads: [payload, Data("not json".utf8)])
            precondition(imported == 1)
            let runs = await store.index().runs
            precondition(runs.count == 1 && runs[0].completeness == "imported" && runs[0].mixedMode)
            precondition(runs[0].mode == "lowLatency")
            let again = await store.migrate(payloads: [payload])
            precondition(again == 0, "migration runs once")
        }

        // 6. Save results: the policy returns fixed skip reasons; disk errors return failed, not silence.
        do {
            let long = fullRun(seconds: 300)
            let short = fullRun(seconds: 12)
            let empty = fullRun(seconds: 300, counters: ["captureFrames": 5])
            let emptyNoLatency = DiagnosticSessionExport(translationModes: empty.translationModes, id: empty.id,
                startedAt: empty.startedAt, endedAt: empty.endedAt, appVersion: empty.appVersion,
                systemVersion: empty.systemVersion, settings: empty.settings, health: empty.health,
                counters: empty.counters, distributions: [:], events: [],
                measurementBoundary: empty.measurementBoundary, textCapture: false)
            func reason(_ snapshot: DiagnosticSessionExport, priv: Bool = false, mode: String = "automatic",
                        enabled: Bool = true) -> TestRunSkipReason? {
                TestRunPolicy.skipReason(meta: meta(snapshot), privateSession: priv, savingMode: mode,
                                         diagnosticsEnabled: enabled)?.0
            }
            precondition(reason(long) == nil)
            precondition(reason(long, priv: true) == .privateSession)
            precondition(reason(long, mode: "off") == .savingOff)
            precondition(reason(short) == .tooShort)
            precondition(TestRunPolicy.skipReason(meta: meta(short), privateSession: false, savingMode: "automatic",
                                                  diagnosticsEnabled: true)!.1 == "Run too short to save – 12 s")
            precondition(reason(emptyNoLatency) == .noData)
            precondition(reason(long, enabled: false) == .noData)
            precondition(reason(long, priv: true, mode: "off") == .privateSession, "private wins over off")
            let full = TestRunStore(directory: tempDirectory())
            await full.setSimulatedDiskFull(true)
            let failed = await full.save(meta: meta(long), snapshot: long)
            precondition(failed == .failed(.diskFull))
            let entries = await full.index().runs.count
            precondition(entries == 0, "a failed save leaves no index entry")
        }

        // 7. session_* mode counters and distributions survive save -> load -> report; every
        //    sessionSnapshot metric key survives redaction.
        do {
            let useful = DiagnosticDistribution([10, 20, 30])
            let raw = fullRun(mode: "lowLatency", seconds: 300, events: 50,
                modeCounters: ["speculation_deferred_armed": 5, "mode_trace_ring_overwritten": 37, "secret OCR text": 999],
                modeDistributions: ["backend_lane_wait_ms": useful, "unsafe_user_content": useful])
            let store = TestRunStore(directory: tempDirectory())
            _ = saved(await store.save(meta: meta(raw), snapshot: raw))
            let loaded = try await store.load(id: raw.id).1
            precondition(loaded.translationModes?.counters["session_speculation_deferred_armed"] == 5,
                         "session_* counters must survive the single sanitize")
            precondition(loaded.translationModes?.counters["session_mode_trace_ring_overwritten"] == 37)
            precondition(loaded.translationModes?.distributions["session_backend_lane_wait_ms"]?.count == 3)
            precondition(loaded.translationModes?.counters["secret OCR text"] == nil)
            let url = try await writer.exportCombinedReport([loaded], version: "2.5.0", build: 118,
                runs: [meta(raw, changes: []).reportInfo])
            let report = try String(contentsOf: url, encoding: .utf8)
            precondition(report.contains("## 1. Sessions") && report.contains("captureStopped"),
                         "the report names the end reason of each run")

            let source = try String(contentsOfFile: "App/Diagnostics.swift", encoding: .utf8)
            let regex = try NSRegularExpression(pattern: "\"([A-Za-z]+)\": DiagnosticDistribution\\(")
            let keys = Set(regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
                Range($0.range(at: 1), in: source).map { String(source[$0]) }
            })
            precondition(keys.count >= 40, "found the sessionSnapshot metric keys (\(keys.count))")
            let samples = DiagnosticDistribution((1...50).map(Double.init))
            let probe = DiagnosticSessionExport(id: UUID(), startedAt: Date(), endedAt: Date(), appVersion: "t",
                systemVersion: "t", settings: [:], health: MemoryDiagnosticHealth(), counters: [:],
                distributions: Dictionary(uniqueKeysWithValues: keys.map { ($0, samples) }), events: [],
                measurementBoundary: "t", textCapture: false)
            let redacted = await writer.redactedForStorage(probe)
            let lost = keys.subtracting(redacted.distributions.keys)
            precondition(lost.isEmpty, "metric keys removed by redaction: \(lost.sorted())")
        }

        // 8. A run never contains two modes: a mode change is recorded and flagged, never hidden.
        do {
            let clean = meta(fullRun())
            precondition(!clean.mixedMode && clean.modeChanges.isEmpty)
            let mixed = meta(fullRun(), changes: ["lowLatency"])
            precondition(mixed.mixedMode && mixed.reportInfo.mixedMode)
        }

        // 9. No text fields leak into stored files (same privacy rule as Tests/DiagnosticArchive).
        do {
            let directory = tempDirectory()
            let store = TestRunStore(directory: directory)
            let id = UUID()
            var dirty = fullRun(mode: "lowLatency", events: 30, modeCounters: ["secret OCR text": 9])
            dirty.translationModes?.events.append(modeEvent(id, 99, caption: "secret OCR text"))
            dirty = DiagnosticSessionExport(translationModes: dirty.translationModes, id: id, startedAt: dirty.startedAt,
                endedAt: dirty.endedAt, appVersion: dirty.appVersion, systemVersion: dirty.systemVersion,
                hardwareModel: dirty.hardwareModel, settings: dirty.settings.merging(["secret OCR text": "hello world"]) { $1 },
                health: dirty.health, counters: dirty.counters.merging(["secret OCR text": 5]) { $1 },
                distributions: dirty.distributions, events: dirty.events,
                measurementBoundary: dirty.measurementBoundary, textCapture: false)
            var named = meta(dirty)
            named.label = TestRunMeta.cleanLabel("Video A\u{0}\u{7}" + String(repeating: "x", count: 80))
            precondition(named.label.count <= 40 && !named.label.contains("\u{0}"))
            _ = saved(await store.save(meta: named, snapshot: dirty))
            let file = directory.appendingPathComponent("run-\(id.uuidString).json.lzfse")
            let json = try (Data(contentsOf: file) as NSData).decompressed(using: .lzfse) as Data
            let text = String(decoding: json, as: UTF8.self)
            precondition(!text.contains("secret OCR text") && !text.contains("hello world"),
                         "free text must not reach a stored run")
            precondition(!text.contains("\n  "), "stored runs are compact JSON, not pretty-printed")
        }

        // 10. Edits change only metadata and never the snapshot; deleting a run touches nothing else.
        do {
            let store = TestRunStore(directory: tempDirectory())
            let a = fullRun(), b = fullRun(mode: "lowLatency")
            let test = UUID()
            _ = saved(await store.save(meta: meta(a, test: test), snapshot: a))
            _ = saved(await store.save(meta: meta(b, test: test), snapshot: b))
            await store.rename(id: a.id, label: "Video A")
            await store.setPinned(id: a.id, true)
            await store.renameTest(testID: test, name: "Renamed test")
            let loaded = try await store.load(id: a.id)
            precondition(loaded.0.label == "Video A" && loaded.0.pinned && loaded.0.testName == "Renamed test")
            precondition(loaded.1.events.count == 2400)
            await store.delete(ids: [b.id])
            let remaining = await store.index().runs.map(\.id)
            precondition(remaining == [a.id])
        }

        // 2.2.1 D1: captions shown but no latency collected (Detailed off) -> "No timing", left out of default reports.
        do {
            let untimed = meta(fullRun(withLatency: false))
            precondition(untimed.captions == 54 && untimed.enqueueP50Ms == nil && untimed.noTiming, "D1: untimed run is flagged")
            let timed = meta(fullRun())
            precondition(!timed.noTiming && timed.enqueueP50Ms != nil, "D1: a run with latency is not flagged")
            precondition(TestRunPolicy.skipReason(meta: untimed, privateSession: false, savingMode: "automatic",
                                                  diagnosticsEnabled: true) == nil, "D1: an untimed run is still saved")
        }

        // 2.2.1 D5: thermal range and time above fair/serious from the 15 s buckets; old files still decode.
        do {
            let warm = meta(fullRun(thermal: { $0 < 10 ? 0 : ($0 < 16 ? 1 : 2) }))
            precondition(warm.thermalMin == 0 && warm.thermalMax == 2, "D5: range")
            precondition(warm.secondsAtFairOrAbove == 150 && warm.secondsAtSeriousOrAbove == 60, "D5: seconds at fair/serious")
            precondition(warm.thermalRangeLabel == "Warm: nominal -> serious", "D5: label \(warm.thermalRangeLabel ?? "nil")")
            precondition(meta(fullRun()).thermalRangeLabel == nil, "D5: an all-nominal run has no badge")
            // An older run file has none of the four fields.
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var json = try JSONSerialization.jsonObject(with: encoder.encode(warm)) as! [String: Any]
            for key in ["thermalMin", "thermalMax", "secondsAtFairOrAbove", "secondsAtSeriousOrAbove"] { json[key] = nil }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let old = try decoder.decode(TestRunMeta.self, from: JSONSerialization.data(withJSONObject: json))
            precondition(old.thermalMin == nil && old.thermalRangeLabel == nil && old.id == warm.id, "D5: old run decodes")
        }
        print("TestRuns: all checks passed")
    }
}
