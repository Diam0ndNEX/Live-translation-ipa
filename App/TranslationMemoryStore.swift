import Foundation
import SQLite3
import CryptoKit

struct MemoryStoreHealth: Codable, Sendable {
    var schemaVersion = 1
    var totalEntries = 0
    var readyEntries = 0
    var needsValidation = 0
    var conflicts = 0
    var databaseBytes: Int64 = 0
    var migrationStatus = "not_started"
    var integrity = "not_checked"
    var failedWrites = 0
    var importedEntries = 0
    var duplicateEntries = 0
    var categoryCounts: [String: Int] = [:]
    var lastVerifiedBackup: String? = nil
}

struct MemoryLookupResult: Sendable {
    let value: String?
    let origin: String
    let outcome: String
    let durationMs: Double
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
    case invalidImport, unsupportedImport, sourceUnreadable, backupFailed, tooLarge, staleRevision
    var errorDescription: String? { "Translation memory: \(rawValue)" }
}

private final class MemoryLookupCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MemoryLookupResult, Never>?
    func install(_ value: CheckedContinuation<MemoryLookupResult, Never>) { lock.lock(); continuation = value; lock.unlock() }
    func finish(_ value: MemoryLookupResult) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(returning: value)
    }
}

/// Owns all SQLite access. None of these operations run on MainActor. The persistent
/// store is additive: evicting a RAM entry or saving a partial snapshot cannot erase it.
actor TranslationMemoryStore {
    static let schemaVersion = 1
    let directory: URL
    private var db: OpaquePointer?
    private var active = false
    private var latestRevision = -1
    private var status = MemoryStoreHealth()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL) { self.directory = directory }
    deinit { if let db { sqlite3_close_v2(db) } }

    private enum SQLValue {
        case text(String), integer(Int64), real(Double), blob(Data), null
    }
    private func statement(_ sql: String, _ values: [SQLValue] = []) throws -> OpaquePointer {
        guard let db else { throw MemoryStoreError.unavailable }
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw MemoryStoreError.databaseOperation }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let code: Int32
                switch value {
                case .text(let text): code = text.withCString { sqlite3_bind_text(result, index, $0, -1, transient) }
                case .integer(let integer): code = sqlite3_bind_int64(result, index, integer)
                case .real(let real): code = sqlite3_bind_double(result, index, real)
                case .blob(let data): code = data.withUnsafeBytes { sqlite3_bind_blob(result, index, $0.baseAddress, Int32(data.count), transient) }
                case .null: code = sqlite3_bind_null(result, index)
                }
                guard code == SQLITE_OK else { throw MemoryStoreError.databaseOperation }
            }
            return result
        } catch { sqlite3_finalize(result); throw error }
    }
    private func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw MemoryStoreError.databaseOperation }
    }
    private func scalar(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
        return sqlite3_column_int64(query, 0)
    }
    private func text(_ query: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(query, column) else { return "" }
        return String(cString: pointer)
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func setMetadata(_ key: String, _ value: String) throws {
        try execute("INSERT INTO memory_metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
    }
    private func metadata(_ key: String) throws -> String? {
        let query = try statement("SELECT value FROM memory_metadata WHERE key=?", [.text(key)])
        defer { sqlite3_finalize(query) }
        let code = sqlite3_step(query)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
        return text(query, 0)
    }

    func prepare(legacyURLs: [URL]) throws -> MemoryStoreHealth {
        if active { return try health() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if db == nil {
                var connection: OpaquePointer?
                let result = sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite").path, &connection,
                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
                guard result == SQLITE_OK, let connection else {
                    if let connection { sqlite3_close_v2(connection) }
                    throw MemoryStoreError.databaseOpen
                }
                db = connection
                sqlite3_busy_timeout(connection, 4)
                // WAL + FULL means a successful commit is synced, not merely queued.
                let mode = try statement("PRAGMA journal_mode=WAL")
                let walReady = sqlite3_step(mode) == SQLITE_ROW && text(mode, 0).lowercased() == "wal"
                sqlite3_finalize(mode)
                guard walReady else { throw MemoryStoreError.databaseOperation }
                try execute("PRAGMA synchronous=FULL")
                try execute("PRAGMA foreign_keys=ON")
                try execute("PRAGMA trusted_schema=OFF")
            }
            let version = try scalar("PRAGMA user_version")
            guard version == 0 || version == Int64(Self.schemaVersion) else { throw MemoryStoreError.unsupportedSchema }
            if version == 0 { try createSchema() }
            status.integrity = try verifyIntegrity()
            status.migrationStatus = "discovering"
            var found = false, failed = false
            // Never remove originals. A failed import does not block a healthy new store.
            for source in legacyURLs {
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                found = true
                do { try migrate(source) } catch { failed = true }
            }
            status.migrationStatus = failed ? "partial_recovery" : (found ? "ready" : "no_previous_memory")
            try setMetadata("migration_status", status.migrationStatus)
            status.integrity = try verifyIntegrity()
            active = true
            return try health()
        } catch {
            active = false; status.migrationStatus = "failed_recoverably"
            throw error
        }
    }

    private func createSchema() throws {
        try transaction {
            let statements = [
                "CREATE TABLE memory_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)",
                """
                CREATE TABLE memory_entries(
                  id INTEGER PRIMARY KEY, canonical_key TEXT NOT NULL, source_text TEXT NOT NULL,
                  translated_text TEXT NOT NULL, normalized_source TEXT NOT NULL,
                  source_language TEXT, target_language TEXT, unit_type TEXT NOT NULL DEFAULT 'unknown',
                  context_fingerprint TEXT, rules_version TEXT, normalization_version INTEGER,
                  segmentation_version INTEGER, engine_identifier TEXT,
                  validation_state TEXT NOT NULL, confirmation_state TEXT NOT NULL,
                  created_at REAL NOT NULL, updated_at REAL NOT NULL, last_used_at REAL,
                  reuse_count INTEGER NOT NULL DEFAULT 0, confirmation_count INTEGER NOT NULL DEFAULT 1,
                  UNIQUE(canonical_key,translated_text))
                """,
                "CREATE INDEX memory_exact ON memory_entries(canonical_key,validation_state,confirmation_state)",
                "CREATE INDEX memory_normalized ON memory_entries(source_language,target_language,normalized_source)",
                "CREATE INDEX memory_compatibility ON memory_entries(validation_state,rules_version)",
                "CREATE INDEX memory_last_used ON memory_entries(last_used_at)",
                "CREATE TABLE memory_provenance(id INTEGER PRIMARY KEY,entry_id INTEGER NOT NULL REFERENCES memory_entries(id) ON DELETE CASCADE,source_format TEXT NOT NULL,source_fingerprint TEXT NOT NULL,legacy_key TEXT,import_batch TEXT NOT NULL,import_timestamp REAL NOT NULL,original_metadata TEXT,UNIQUE(entry_id,source_fingerprint,legacy_key))",
                "CREATE INDEX memory_provenance_source ON memory_provenance(source_fingerprint,entry_id)",
                "CREATE TABLE memory_conflicts(id INTEGER PRIMARY KEY,entry_id INTEGER NOT NULL REFERENCES memory_entries(id) ON DELETE CASCADE,alternative_id INTEGER NOT NULL REFERENCES memory_entries(id) ON DELETE CASCADE,created_at REAL NOT NULL,resolved INTEGER NOT NULL DEFAULT 0,UNIQUE(entry_id,alternative_id))",
                "CREATE TABLE migration_runs(id TEXT PRIMARY KEY,source_fingerprint TEXT NOT NULL,source_format TEXT NOT NULL,state TEXT NOT NULL,started_at REAL NOT NULL,finished_at REAL,imported INTEGER NOT NULL DEFAULT 0,duplicates INTEGER NOT NULL DEFAULT 0,errors INTEGER NOT NULL DEFAULT 0,reason TEXT)",
                "CREATE INDEX migration_source ON migration_runs(source_fingerprint,state)",
                "CREATE TABLE diagnostic_sessions(id TEXT PRIMARY KEY,started_at REAL NOT NULL,ended_at REAL NOT NULL,payload BLOB NOT NULL)",
                "CREATE TABLE diagnostic_events(id INTEGER PRIMARY KEY,session_id TEXT NOT NULL REFERENCES diagnostic_sessions(id) ON DELETE CASCADE,timestamp REAL NOT NULL,payload BLOB NOT NULL)",
                "CREATE INDEX diagnostic_event_time ON diagnostic_events(session_id,timestamp)",
                "CREATE INDEX diagnostic_session_time ON diagnostic_sessions(ended_at)",
                "PRAGMA user_version=1"
            ]
            for sql in statements { try execute(sql) }
            try setMetadata("schema_version", "1")
            try setMetadata("translation_rules_version", "v4-fingerprint")
            try setMetadata("normalization_version", "1")
            try setMetadata("segmentation_version", "1")
            try setMetadata("cache_key_version", "4")
            try setMetadata("diagnostic_event_version", "1")
            try setMetadata("export_version", "1")
        }
    }

    /// Parses historical byte-length prefixes, not delimiter splitting of source text.
    /// Delimiters and emoji may legitimately occur inside protected-token context.
    private struct KeyParts {
        var source: String; var target: String; var sourceText: String; var context: String; var rules: String?
    }
    private func keyParts(_ key: String) -> KeyParts? {
        var bytes = Array(key.utf8)
        func field() -> String? {
            guard let end = bytes.firstIndex(of: 124), let value = String(bytes: bytes[..<end], encoding: .utf8) else { return nil }
            bytes.removeFirst(end + 1); return value
        }
        guard let version = field(), ["v2","v3","v4"].contains(version) else { return nil }
        var rules: String?
        if version == "v4" {
            guard let value = field(), value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { return nil }
            rules = value
        }
        guard let pair = field() else { return nil }
        let languages = pair.split(separator: ">", omittingEmptySubsequences: false)
        guard languages.count == 2, languages.allSatisfy({ !$0.isEmpty && $0.count < 40 && $0.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) }),
              let separator = bytes.firstIndex(of: 58), separator < 12,
              let sizeString = String(bytes: bytes[..<separator], encoding: .utf8), let size = Int(sizeString), size >= 0 else { return nil }
        bytes.removeFirst(separator + 1)
        guard size < bytes.count, bytes[size] == 124, let context = String(bytes: bytes.prefix(size), encoding: .utf8),
              let sourceText = String(bytes: bytes.dropFirst(size + 1), encoding: .utf8), !sourceText.isEmpty else { return nil }
        return KeyParts(source: String(languages[0]), target: String(languages[1]), sourceText: sourceText, context: context, rules: rules)
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func normalized(_ text: String) -> String {
        // Conservative: case and punctuation carry meaning and are retained.
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private func insert(key: String, value: String, compatible: Bool, confirmed: Bool = true) throws -> (id: Int64, inserted: Bool) {
        let parts = keyParts(key)
        let reusable = compatible && parts?.rules != nil && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let now = Date().timeIntervalSince1970
        let query = try statement("SELECT id FROM memory_entries WHERE canonical_key=? AND translated_text=?", [.text(key), .text(value)])
        defer { sqlite3_finalize(query) }
        let found = sqlite3_step(query)
        if found == SQLITE_ROW {
            let existingID = sqlite3_column_int64(query, 0)
            if reusable && confirmed {
                try execute("UPDATE memory_entries SET validation_state='ready',confirmation_state='persisted',updated_at=?,confirmation_count=confirmation_count+1 WHERE id=?", [.real(now), .integer(existingID)])
            }
            return (existingID, false)
        }
        guard found == SQLITE_DONE else { throw MemoryStoreError.databaseOperation }
        try execute("""
            INSERT INTO memory_entries(canonical_key,source_text,translated_text,normalized_source,source_language,target_language,
            unit_type,context_fingerprint,rules_version,normalization_version,segmentation_version,engine_identifier,
            validation_state,confirmation_state,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(key), .text(parts?.sourceText ?? ""), .text(value), .text(normalized(parts?.sourceText ?? "")),
                   parts.map { .text($0.source) } ?? .null, parts.map { .text($0.target) } ?? .null,
                   .text(MemoryUnitClassifier.classify(parts?.sourceText ?? "").rawValue),
                   parts.map { .text(digest(Data($0.context.utf8))) } ?? .null,
                   parts?.rules.map { .text($0) } ?? .null,
                   reusable ? .integer(1) : .null, reusable ? .integer(1) : .null,
                   reusable ? .text("apple.translation") : .null,
                   .text(reusable ? "ready" : "needs_validation"), .text(confirmed ? "persisted" : "needs_validation"), .real(now), .real(now)])
        let id = sqlite3_last_insert_rowid(db)
        try execute("INSERT OR IGNORE INTO memory_conflicts(entry_id,alternative_id,created_at) SELECT id,?,? FROM memory_entries WHERE canonical_key=? AND id<>?", [.integer(id), .real(now), .text(key), .integer(id)])
        return (id, true)
    }

    private struct LegacyEnvelope: Decodable { let version: Int; let entries: [String:String] }
    private func migrate(_ source: URL) throws {
        status.migrationStatus = "backing_up"
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 <= 256 * 1024 * 1024 else { throw MemoryStoreError.tooLarge }
            data = try Data(contentsOf: source)
        } catch { throw MemoryStoreError.sourceUnreadable }
        let fingerprint = digest(data)
        let backupDirectory = directory.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backup = backupDirectory.appendingPathComponent(fingerprint + ".json")
        if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
        guard digest(try Data(contentsOf: backup)) == fingerprint else { throw MemoryStoreError.backupFailed }
        if try scalar("SELECT COUNT(*) FROM migration_runs WHERE source_fingerprint=? AND state='ready'", [.text(fingerprint)]) > 0 { return }
        let batch = UUID().uuidString
        try execute("INSERT INTO migration_runs(id,source_fingerprint,source_format,state,started_at) VALUES(?,?,?,'importing',?)", [.text(batch), .text(fingerprint), .text("unknown"), .real(Date().timeIntervalSince1970)])
        do {
            let entries: [String:String], format: String, compatible: Bool
            if let envelope = try? JSONDecoder().decode(LegacyEnvelope.self, from: data) {
                entries = envelope.entries; format = "envelope_v\(envelope.version)"; compatible = envelope.version == 4
            } else if let dictionary = try? JSONDecoder().decode([String:String].self, from: data) {
                entries = dictionary; format = "legacy_dictionary"; compatible = false
            } else { throw MemoryStoreError.invalidImport }
            status.migrationStatus = "importing"
            try transaction {
                var imported = 0, duplicates = 0
                for (key, value) in entries {
                    let entry = try insert(key: key, value: value, compatible: compatible)
                    if entry.inserted { imported += 1 } else { duplicates += 1 }
                    try execute("INSERT OR IGNORE INTO memory_provenance(entry_id,source_format,source_fingerprint,legacy_key,import_batch,import_timestamp,original_metadata) VALUES(?,?,?,?,?,?,?)",
                        [.integer(entry.id), .text(format), .text(fingerprint), .text(key), .text(batch), .real(Date().timeIntervalSince1970), .text("{\"metadata\":\"not_supplied\"}")])
                }
                let verified = try scalar("SELECT COUNT(*) FROM memory_provenance WHERE source_fingerprint=?", [.text(fingerprint)])
                guard verified == entries.count else { throw MemoryStoreError.integrityFailure }
                try execute("UPDATE migration_runs SET source_format=?,state='ready',finished_at=?,imported=?,duplicates=? WHERE id=?", [.text(format), .real(Date().timeIntervalSince1970), .integer(Int64(imported)), .integer(Int64(duplicates)), .text(batch)])
            }
        } catch {
            try? execute("UPDATE migration_runs SET state='failed_recoverably',errors=1,reason='import_failed',finished_at=? WHERE id=?", [.real(Date().timeIntervalSince1970), .text(batch)])
            throw error
        }
    }

    /// The deadline includes time waiting behind actor work. Timeout wins exactly
    /// once; a delayed lookup is discarded and never publishes an unsolicited result.
    nonisolated func lookup(key: String, timeoutMilliseconds: Double = 8) async -> MemoryLookupResult {
        let started = ProcessInfo.processInfo.systemUptime
        let budget = min(50, max(1, timeoutMilliseconds.isFinite ? timeoutMilliseconds : 8)) / 1000
        let completion = MemoryLookupCompletion()
        return await withCheckedContinuation { continuation in
            completion.install(continuation)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + budget) {
                completion.finish(MemoryLookupResult(value: nil, origin: "none", outcome: "timeout", durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000))
            }
            Task {
                let result = await self.lookupNow(key: key, started: started, deadline: started + budget)
                completion.finish(result)
            }
        }
    }
    private func lookupNow(key: String, started: Double, deadline: Double) -> MemoryLookupResult {
        func result(_ value: String? = nil, _ origin: String = "none", _ outcome: String) -> MemoryLookupResult {
            MemoryLookupResult(value: value, origin: origin, outcome: outcome, durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
        guard active else { return result(nil, "none", "unavailable") }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return result(nil, "none", "timeout") }
        guard keyParts(key)?.rules != nil else { return result(nil, "none", "incompatible") }
        do {
            // At most two indexed rows are read. Any conflicting ready outputs make
            // automatic reuse ambiguous; keep both and request fresh translation.
            let query = try statement("SELECT id,translated_text,EXISTS(SELECT 1 FROM memory_provenance p WHERE p.entry_id=memory_entries.id) FROM memory_entries WHERE canonical_key=? AND validation_state='ready' AND confirmation_state='persisted' LIMIT 2", [.text(key)])
            defer { sqlite3_finalize(query) }
            let first = sqlite3_step(query)
            if first == SQLITE_DONE { return result(nil, "none", "miss") }
            guard first == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
            let value = text(query, 1), imported = sqlite3_column_int(query, 2) != 0
            let second = sqlite3_step(query)
            if second == SQLITE_ROW { return result(nil, "none", "conflict") }
            guard second == SQLITE_DONE else { throw MemoryStoreError.databaseOperation }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return result(nil, "none", "timeout") }
            return result(value, imported ? "legacy" : "persistent", "hit")
        } catch { return result(nil, "none", "database_error") }
    }

    /// The caller supplies only confirmed eligible results. Return means COMMIT has
    /// succeeded. A failed transaction leaves every prior translation untouched.
    func save(_ entries: [String:String], revision: Int) throws -> MemoryStoreHealth {
        guard active else { throw MemoryStoreError.unavailable }
        guard revision > latestRevision else { throw MemoryStoreError.staleRevision }
        latestRevision = revision
        do {
            try transaction {
                for (key, value) in entries {
                    guard keyParts(key)?.rules != nil, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    _ = try insert(key: key, value: value, compatible: true)
                }
            }
        } catch { status.failedWrites += 1; throw error }
        return try health()
    }

    func health() throws -> MemoryStoreHealth {
        status.totalEntries = Int(try scalar("SELECT COUNT(*) FROM memory_entries"))
        status.readyEntries = Int(try scalar("SELECT COUNT(*) FROM memory_entries WHERE validation_state='ready'"))
        status.needsValidation = status.totalEntries - status.readyEntries
        status.conflicts = Int(try scalar("SELECT COUNT(*) FROM memory_conflicts WHERE resolved=0"))
        status.importedEntries = Int(try scalar("SELECT COALESCE(SUM(imported),0) FROM migration_runs WHERE state='ready'"))
        status.duplicateEntries = Int(try scalar("SELECT COALESCE(SUM(duplicates),0) FROM migration_runs WHERE state='ready'"))
        let categories = try statement("SELECT unit_type,COUNT(*) FROM memory_entries GROUP BY unit_type")
        defer { sqlite3_finalize(categories) }
        var counts: [String: Int] = [:]
        while true {
            let code = sqlite3_step(categories)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
            counts[text(categories, 0)] = Int(sqlite3_column_int64(categories, 1))
        }
        status.categoryCounts = counts
        status.lastVerifiedBackup = try metadata("last_verified_backup")
        status.databaseBytes = ["memory.sqlite","memory.sqlite-wal","memory.sqlite-shm"].reduce(0) {
            $0 + ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($1).path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return status
    }

    func verifyIntegrity() throws -> String {
        let query = try statement("PRAGMA quick_check"); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, text(query, 0) == "ok" else { throw MemoryStoreError.integrityFailure }
        let foreign = try statement("PRAGMA foreign_key_check"); defer { sqlite3_finalize(foreign) }
        guard sqlite3_step(foreign) == SQLITE_DONE else { throw MemoryStoreError.integrityFailure }
        status.integrity = "ok"
        return "ok"
    }

    /// Make a consistent SQLite snapshot without copying live WAL/SHM files.
    /// This maintenance operation is explicit and never runs in the OCR path.
    /// Restore is intentionally not automatic: a newer active DB may contain
    /// confirmations made after this snapshot.
    func createRecoverySnapshot() throws -> String {
        guard active else { throw MemoryStoreError.unavailable }
        let recovery = directory.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        let staging = recovery.appendingPathComponent(".pending-" + identifier + ".sqlite")
        let destination = recovery.appendingPathComponent("memory-" + identifier + ".sqlite")
        do {
            try execute("VACUUM INTO ?", [.text(staging.path)])
            var snapshot: OpaquePointer?
            let opened = sqlite3_open_v2(staging.path, &snapshot,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            guard opened == SQLITE_OK, let snapshot else {
                if let snapshot { sqlite3_close_v2(snapshot) }
                throw MemoryStoreError.backupFailed
            }
            var validation: OpaquePointer?
            let prepared = sqlite3_prepare_v2(snapshot, "PRAGMA quick_check", -1, &validation, nil)
            guard prepared == SQLITE_OK, let validation else {
                if let validation { sqlite3_finalize(validation) }
                sqlite3_close_v2(snapshot)
                throw MemoryStoreError.backupFailed
            }
            let valid = sqlite3_step(validation) == SQLITE_ROW && text(validation, 0) == "ok"
            sqlite3_finalize(validation)
            sqlite3_close_v2(snapshot)
            guard valid else { throw MemoryStoreError.backupFailed }
            try FileManager.default.moveItem(at: staging, to: destination)
            let timestamp = ISO8601DateFormatter().string(from: Date())
            try setMetadata("last_verified_backup", timestamp)
            status.lastVerifiedBackup = timestamp
            return destination.lastPathComponent
        } catch {
            // A failed snapshot must never touch memory.sqlite or its WAL.
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    func clear(revision: Int) throws {
        guard active else { throw MemoryStoreError.unavailable }
        guard revision > latestRevision else { throw MemoryStoreError.staleRevision }
        latestRevision = revision
        try transaction {
            try execute("DELETE FROM memory_entries")
            // Retain migration receipts so intentionally deleted entries are not
            // silently reimported from protected legacy originals at next launch.
            try setMetadata("last_explicit_clear", String(Date().timeIntervalSince1970))
        }
    }
    func delete(ids: [Int64]) throws {
        guard active else { throw MemoryStoreError.unavailable }
        try transaction { for id in ids { try execute("DELETE FROM memory_entries WHERE id=?", [.integer(id)]) } }
    }
    private func readEntry(_ query: OpaquePointer) -> MemoryStoredEntry {
        MemoryStoredEntry(id: sqlite3_column_int64(query, 0), key: text(query, 1), sourceText: text(query, 2), translatedText: text(query, 3), sourceLanguage: text(query, 4), targetLanguage: text(query, 5), unitType: text(query, 6), validationState: text(query, 7), confirmationState: text(query, 8), createdAt: sqlite3_column_double(query, 9), updatedAt: sqlite3_column_double(query, 10), reuseCount: Int(sqlite3_column_int(query, 11)))
    }
    private var entryColumns: String { "id,canonical_key,source_text,translated_text,source_language,target_language,unit_type,validation_state,confirmation_state,created_at,updated_at,reuse_count" }
    /// Explicit management query, never called by the live translation path.
    func search(query: String = "", limit: Int = 100) throws -> [MemoryStoredEntry] {
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let sql = try statement("SELECT \(entryColumns) FROM memory_entries WHERE source_text LIKE ? ESCAPE '\\' OR translated_text LIKE ? ESCAPE '\\' ORDER BY id DESC LIMIT ?", [.text("%\(escaped)%"), .text("%\(escaped)%"), .integer(Int64(min(1000, max(1, limit))))])
        defer { sqlite3_finalize(sql) }
        var entries: [MemoryStoredEntry] = []
        while true {
            let code = sqlite3_step(sql)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
            entries.append(readEntry(sql))
        }
        return entries
    }
    /// Explicit management-only query. Never enumerate conflicts in live OCR lookup.
    /// Both alternatives remain intact until an informed user takes action.
    func conflictingEntries(limit: Int = 100) throws -> [MemoryStoredEntry] {
        guard active else { throw MemoryStoreError.unavailable }
        let sql = try statement("""
            SELECT \(entryColumns) FROM memory_entries
            WHERE id IN (
                SELECT entry_id FROM memory_conflicts WHERE resolved=0
                UNION SELECT alternative_id FROM memory_conflicts WHERE resolved=0
            )
            ORDER BY updated_at DESC LIMIT ?
            """, [.integer(Int64(min(100, max(1, limit))))])
        defer { sqlite3_finalize(sql) }
        var entries: [MemoryStoredEntry] = []
        while true {
            let code = sqlite3_step(sql)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
            entries.append(readEntry(sql))
        }
        return entries
    }

    /// Bounded maintenance-only conflict inspection. The live lookup path uses
    /// its existing exact index and never invokes this query.
    func conflictingEntries(limit: Int = 100) throws -> [MemoryStoredEntry] {
        guard active else { throw MemoryStoreError.unavailable }
        let columns = entryColumns.split(separator: ",").map { "e." + $0 }.joined(separator: ",")
        let sql = """
            SELECT \(columns)
            FROM memory_entries e
            JOIN (
                SELECT entry_id AS member_id FROM memory_conflicts WHERE resolved=0
                UNION
                SELECT alternative_id AS member_id FROM memory_conflicts WHERE resolved=0
            ) conflicts ON conflicts.member_id=e.id
            ORDER BY e.updated_at DESC
            LIMIT ?
            """
        let query = try statement(sql, [.integer(Int64(min(100, max(1, limit))))])
        defer { sqlite3_finalize(query) }
        var entries: [MemoryStoredEntry] = []
        while true {
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
            entries.append(readEntry(query))
        }
        return entries
    }

    private struct ExportEnvelope: Codable {
        let formatVersion: Int
        let schemaVersion: Int
        let exportedAt: Date
        let entries: [MemoryStoredEntry]
        let checksum: String
    }
    func exportData() throws -> Data {
        let query = try statement("SELECT \(entryColumns) FROM memory_entries ORDER BY id")
        defer { sqlite3_finalize(query) }
        var entries: [MemoryStoredEntry] = []
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
            entries.append(readEntry(query))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let checksum = digest(try encoder.encode(entries))
        let data = try encoder.encode(ExportEnvelope(formatVersion: 1, schemaVersion: Self.schemaVersion, exportedAt: Date(), entries: entries, checksum: checksum))
        // Keep exports within the same documented 256 MiB transfer ceiling as imports.
        // A too-large export must fail explicitly instead of presenting an unusable file.
        guard data.count <= 256 * 1024 * 1024 else { throw MemoryStoreError.tooLarge }
        return data
    }
    func importData(_ data: Data) throws -> MemoryStoreHealth {
        guard active else { throw MemoryStoreError.unavailable }
        guard data.count <= 256 * 1024 * 1024 else { throw MemoryStoreError.tooLarge }
        guard let envelope = try? JSONDecoder().decode(ExportEnvelope.self, from: data) else { throw MemoryStoreError.invalidImport }
        guard envelope.formatVersion == 1, envelope.schemaVersion == Self.schemaVersion else { throw MemoryStoreError.unsupportedImport }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard digest(try encoder.encode(envelope.entries)) == envelope.checksum else { throw MemoryStoreError.integrityFailure }
        try transaction {
            for entry in envelope.entries {
                _ = try insert(key: entry.key, value: entry.translatedText,
                    compatible: entry.validationState == "ready" && entry.confirmationState == "persisted")
            }
        }
        return try health()
    }

    func saveDiagnosticSession(id: String, startedAt: Date, endedAt: Date, payload: Data) throws {
        guard active else { throw MemoryStoreError.unavailable }
        guard payload.count <= 1024 * 1024 else { throw MemoryStoreError.tooLarge }
        try transaction {
            try execute("INSERT INTO diagnostic_sessions(id,started_at,ended_at,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET ended_at=excluded.ended_at,payload=excluded.payload", [.text(id), .real(startedAt.timeIntervalSince1970), .real(endedAt.timeIntervalSince1970), .blob(payload)])
            try execute("DELETE FROM diagnostic_sessions WHERE ended_at < ? OR id NOT IN (SELECT id FROM diagnostic_sessions ORDER BY ended_at DESC LIMIT 20)", [.real(Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970)])
            while try scalar("SELECT COALESCE(SUM(length(payload)),0) FROM diagnostic_sessions") > 10 * 1024 * 1024 {
                try execute("DELETE FROM diagnostic_sessions WHERE id=(SELECT id FROM diagnostic_sessions ORDER BY ended_at LIMIT 1)")
            }
        }
    }
    func loadDiagnosticSessions() throws -> [Data] {
        let query = try statement("SELECT payload FROM diagnostic_sessions WHERE ended_at>=? ORDER BY ended_at DESC LIMIT 20", [.real(Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970)])
        defer { sqlite3_finalize(query) }
        var results: [Data] = []
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
            if let bytes = sqlite3_column_blob(query, 0) { results.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))) }
        }
        return results
    }
    func clearDiagnosticSessions() throws { try execute("DELETE FROM diagnostic_sessions") }
}
