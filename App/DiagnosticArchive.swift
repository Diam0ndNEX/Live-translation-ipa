import Foundation

/// Metadata only: no source text, translations, cache keys, filenames or model errors.
struct MemoryDiagnosticHealth: Codable {
    var schemaVersion = 1
    var totalEntries = 0
    var readyEntries = 0
    var needsValidation = 0
    var conflicts = 0
    var databaseBytes: Int64 = 0
    var migrationStatus = "not started"
    var integrity = "not verified"
    var pendingWrites = 0
    var failedWrites = 0
    var ramEntries = 0
    var categoryCounts: [String: Int] = [:]

    // Old saved sessions lack categoryCounts. Keep them readable after upgrades.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, totalEntries, readyEntries, needsValidation, conflicts
        case databaseBytes, migrationStatus, integrity, pendingWrites, failedWrites
        case ramEntries, categoryCounts
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        totalEntries = try c.decodeIfPresent(Int.self, forKey: .totalEntries) ?? 0
        readyEntries = try c.decodeIfPresent(Int.self, forKey: .readyEntries) ?? 0
        needsValidation = try c.decodeIfPresent(Int.self, forKey: .needsValidation) ?? 0
        conflicts = try c.decodeIfPresent(Int.self, forKey: .conflicts) ?? 0
        databaseBytes = try c.decodeIfPresent(Int64.self, forKey: .databaseBytes) ?? 0
        migrationStatus = try c.decodeIfPresent(String.self, forKey: .migrationStatus) ?? "not started"
        integrity = try c.decodeIfPresent(String.self, forKey: .integrity) ?? "not verified"
        pendingWrites = try c.decodeIfPresent(Int.self, forKey: .pendingWrites) ?? 0
        failedWrites = try c.decodeIfPresent(Int.self, forKey: .failedWrites) ?? 0
        ramEntries = try c.decodeIfPresent(Int.self, forKey: .ramEntries) ?? 0
        categoryCounts = try c.decodeIfPresent([String: Int].self, forKey: .categoryCounts) ?? [:]
    }
}

enum MemoryDiagnosticOutcome: String, Codable, CaseIterable {
    case ramHit, persistentHit, legacyHit, speculativeHit, miss, timeout
    case compatibilityRejected, normalizedHit, databaseUnavailable, persisted, writeFailed, ramEviction, cancelled
}

struct StructuredDiagnosticEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let sessionID: UUID
    let candidateID: UUID?
    // Null means this boundary was not instrumented, rather than inferred.
    var frameID: UUID? = nil
    var unitID: UUID? = nil
    let stage: String
    let outcome: String
    let reasonCode: String
    let durationMs: Double?
    let privacy: String
}

struct DiagnosticDistribution: Codable {
    let count: Int
    let mean: Double
    let p50: Double?
    let p90: Double?
    let p95: Double?
    let p99: Double?
    let maximum: Double?
    init(_ values: [Double]) {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        count = sorted.count
        mean = sorted.isEmpty ? 0 : sorted.reduce(0,+) / Double(sorted.count)
        func percentile(_ p: Double) -> Double? {
            guard !sorted.isEmpty else { return nil }
            return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1))]
        }
        p50 = percentile(0.5)
        p90 = sorted.count >= 10 ? percentile(0.9) : nil
        p95 = sorted.count >= 20 ? percentile(0.95) : nil
        p99 = sorted.count >= 100 ? percentile(0.99) : nil
        maximum = sorted.last
    }
}

struct DiagnosticSessionExport: Codable, Identifiable {
    var eventSchemaVersion = 1
    var exportFormatVersion = 1
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let appVersion: String
    let systemVersion: String
    let settings: [String: String]
    let health: MemoryDiagnosticHealth
    let counters: [String: Int]
    let distributions: [String: DiagnosticDistribution]
    let events: [StructuredDiagnosticEvent]
    let measurementBoundary: String
    let textCapture: Bool
}

/// Encoding, disk I/O and decode validation run away from the UI actor.
actor DiagnosticExportWriter {
    func encode(_ snapshot: DiagnosticSessionExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticSessionExport.self, from: data)
        guard decoded.id == snapshot.id, decoded.events.count == snapshot.events.count else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
    func export(_ snapshot: DiagnosticSessionExport) throws -> URL {
        let data = try encode(snapshot)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screenlingo-diagnostics-\(UUID().uuidString).json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        return url
    }
    /// Export only metadata-only events with a bounded indexed retention window.
    /// This runs on the archive actor, outside the live OCR and PiP pipeline.
    func encodeIndexedEvents(_ input: [StructuredDiagnosticEvent])
        throws -> [(timestamp: Double, payload: Data)] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var output: [(timestamp: Double, payload: Data)] = []
        var byteCount = 0
        for event in input.suffix(128) where event.privacy == "metadataOnly" {
            let encoded = try encoder.encode(event)
            // Selected events must fit a strict, predictable SQLite budget.
            guard encoded.count <= 4096 else { continue }
            if byteCount + encoded.count > 512 * 1024 { break }
            byteCount += encoded.count
            output.append((timestamp: event.timestamp.timeIntervalSince1970,
                           payload: encoded))
        }
        return output
    }

    func decode(_ data: Data) throws -> DiagnosticSessionExport {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticSessionExport.self, from: data)
    }
}


/// Controlled comparison is permitted only for matching diagnostic boundaries,
/// device OS, settings and adequate sample counts. It is not a causal claim.
struct DiagnosticPerformanceComparison {
    let comparable: Bool
    let reason: String
    let p95Changes: [String: Double]

    init(baseline: DiagnosticSessionExport, current: DiagnosticSessionExport) {
        guard baseline.systemVersion == current.systemVersion,
              baseline.measurementBoundary == current.measurementBoundary,
              baseline.settings == current.settings
        else {
            comparable = false
            reason = "Different device settings or measurement boundaries; comparison withheld"
            p95Changes = [:]
            return
        }
        var differences: [String: Double] = [:]
        for name in baseline.distributions.keys.sorted() {
            guard let before = baseline.distributions[name],
                  let after = current.distributions[name],
                  before.count >= 20, after.count >= 20,
                  let baselineP95 = before.p95, baselineP95 > 0,
                  let currentP95 = after.p95, currentP95.isFinite else { continue }
            differences[name] = 100 * (currentP95 - baselineP95) / baselineP95
        }
        p95Changes = differences
        comparable = !differences.isEmpty
        reason = comparable ? "Comparable settings; different subtitles may affect results"
            : "At least 20 samples per session are required to compare p95"
    }
}

 
/// Evidence-based findings derived exclusively from bounded, redacted session metadata.
/// "Observed" means a recorded fact, not proof that a translation was wrong.
/// "Suspected" is a rate-based warning whose threshold can produce false positives.
struct DiagnosticIssueFinding: Codable, Identifiable {
    let code: String
    let classification: String
    let occurrences: Int
    let explanation: String
    var id: String { code }
}

enum DiagnosticIssueDetector {
    static func assess(_ session: DiagnosticSessionExport) -> [DiagnosticIssueFinding] {
        var findings: [DiagnosticIssueFinding] = []
        func add(_ code: String, _ classification: String, _ occurrences: Int, _ explanation: String) {
            findings.append(DiagnosticIssueFinding(code: code, classification: classification,
                occurrences: occurrences, explanation: explanation))
        }
        let failures = max(session.health.failedWrites, session.counters["writeFailed", default: 0])
        if failures > 0 {
            add("memory_write_failure", "observed", failures,
                "SQLite write failures were reported. Confirm whether pending translations were persisted.")
        }
        if session.health.conflicts > 0 {
            add("memory_conflict", "observed", session.health.conflicts,
                "Multiple translations share a memory identity; ambiguous alternatives are not reused.")
        }
        let migration = session.health.migrationStatus
        if migration == "partial_recovery" || migration == "failed_recoverably" {
            add("migration_recovery", "observed", 1,
                "Legacy migration did not fully complete. Protected originals may require inspection.")
        }
        let lookups = ["ramHit", "persistentHit", "legacyHit", "normalizedHit", "speculativeHit",
                       "miss", "timeout", "compatibilityRejected", "databaseUnavailable"]
            .reduce(0) { $0 + max(0, session.counters[$1, default: 0]) }
        let timeouts = max(0, session.counters["timeout", default: 0])
        if lookups >= 20 && timeouts >= 3 && Double(timeouts) / Double(lookups) >= 0.05 {
            add("memory_lookup_timeouts", "suspected", timeouts,
                "At least 5% of observed lookups timed out. Test the lookup deadline and database pressure.")
        }
        let cancelled = max(0, session.counters["cancelled", default: 0])
        if cancelled >= 10 && lookups >= 20 && Double(cancelled) / Double(lookups) > 0.25 {
            add("high_cancellation_rate", "suspected", cancelled,
                "Many units were cancelled. Screen motion and changing subtitles may explain the pattern.")
        }
        return findings
    }
}
