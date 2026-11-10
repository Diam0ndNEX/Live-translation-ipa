import Foundation

struct MemoryStoreHealth: Codable, Sendable {
    var schemaVersion = 2
    var totalEntries = 0
    var readyEntries = 0
    var needsValidation = 0
    /// Historical rows are preserved, but never reused until a current v4 key is confirmed.
    var legacyValidated = 0
    var legacySuperseded = 0
    var legacyUnverified = 0
    var suggestedOCRMatches = 0
    var suggestedFragmentMatches = 0
    var conflicts = 0
    var databaseBytes: Int64 = 0
    var migrationStatus = "not_started"
    var integrity = "not_checked"
    var failedWrites = 0
    var importedEntries = 0
    var duplicateEntries = 0
    var categoryCounts: [String: Int] = [:]
    var lastVerifiedBackup: String? = nil
    /// 2.2.1 (D10): how long the last health() took on the store actor. Measurement only.
    var lastHealthMs: Double? = nil
}

struct MemoryLookupResult: Sendable {
    let value: String?
    let origin: String
    let outcome: String
    let durationMs: Double
    /// 2.2.1 (D10): time the lookup waited behind other work on the store actor before its query started.
    var waitMs: Double? = nil
}

struct MemoryStoredEntry: Codable, Identifiable, Sendable {
    let id: Int64
    let key: String
    let sourceText: String
    let translatedText: String
    let sourceLanguage: String
    let targetLanguage: String
    let unitType: String
    let validationState: String
    let confirmationState: String
    let createdAt: Double
    let updatedAt: Double
    let reuseCount: Int
}

/// Error descriptions are reason codes only. sqlite3_errmsg can contain source text,
/// SQL, or filenames and must never be copied into standard diagnostic reports.
enum MemoryStoreError: String, Error, LocalizedError {
    case unavailable, databaseOpen, databaseOperation, unsupportedSchema, integrityFailure
    case invalidImport, unsupportedImport, sourceUnreadable, backupFailed, tooLarge, staleRevision, memoryNotEmpty, storageFull
    var errorDescription: String? { "Translation memory: \(rawValue)" }
}
