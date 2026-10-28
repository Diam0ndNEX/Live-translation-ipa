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
        print("Diagnostic percentile, privacy, correlation, compatibility and comparison passed")
    }
}
