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
            endedAt: Date(), appVersion: "1.4.0", systemVersion: "test",
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

        let matching = DiagnosticPerformanceComparison(baseline: snapshot, current: snapshot)
        precondition(matching.comparable &&
                     abs(matching.p95Changes["memoryLookupMs", default: 100]) < 0.00001)
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
        let exportedZIP = try await writer.exportZIP(snapshot)
        defer { try? FileManager.default.removeItem(at: exportedZIP) }
        precondition(FileManager.default.fileExists(atPath: exportedZIP.path))
        print("Diagnostic percentile, privacy, correlation, compatibility and comparison passed")
    }
}
