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
}

enum MemoryDiagnosticOutcome: String, Codable, CaseIterable {
    case ramHit, persistentHit, legacyHit, speculativeHit, miss, timeout
    case compatibilityRejected, persisted, writeFailed, ramEviction, cancelled
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
    func decode(_ data: Data) throws -> DiagnosticSessionExport {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticSessionExport.self, from: data)
    }
}
