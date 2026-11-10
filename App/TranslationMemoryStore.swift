import Foundation
import SQLite3
import CryptoKit

final class MemoryLookupCompletion: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<MemoryLookupResult, Never>?
    func install(_ value: CheckedContinuation<MemoryLookupResult, Never>) { lock.lock(); continuation = value; lock.unlock() }
    func finish(_ value: MemoryLookupResult) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(returning: value)
    }
}

/// Owns all SQLite access. None of these operations run on MainActor. The persistent
/// store is additive: evicting a RAM entry or saving a partial snapshot cannot erase it.
/// Hands the queue wait of each executed lookup to whoever installed a handler (2.2.1, D10). Measurement only.
final class MemoryLookupMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Double) -> Void)?
    func install(_ handler: @escaping @Sendable (Double) -> Void) { lock.lock(); self.handler = handler; lock.unlock() }
    func report(_ ms: Double?) {
        guard let ms, ms.isFinite else { return }
        lock.lock(); let current = handler; lock.unlock()
        current?(ms)
    }
}

actor TranslationMemoryStore {
    static let schemaVersion = 2
    nonisolated let measurement = MemoryLookupMeasurement()
    let directory: URL
    var db: OpaquePointer?
    private var lookupStatements: [String: OpaquePointer] = [:]
    var active = false
    var latestRevision = -1
    var status = MemoryStoreHealth()
    #if MEMORY_FAULT_TESTING
    private var injectedInsertCountdown: Int?
    /// A deterministic simulated SQLITE_FULL fault; never compiled into the app.
    func injectStorageFull(afterSuccessfulInserts count: Int) {
        injectedInsertCountdown = max(0, count)
    }
    #endif
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL) { self.directory = directory }
    deinit {
        for query in lookupStatements.values { sqlite3_finalize(query) }
        if let db { sqlite3_close_v2(db) }
    }

    func clearLookupStatements() {
        for query in lookupStatements.values { sqlite3_finalize(query) }
        lookupStatements.removeAll()
    }

    /// Only the two read-only lookup shapes are retained, on this actor.
    /// Reset AND clear bindings after every use, including conflicts/timeouts.
    func lookupStatement(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        guard let query = lookupStatements[sql] else {
            let query = try statement(sql, values)
            lookupStatements[sql] = query
            return query
        }
        for (offset, value) in values.enumerated() {
            guard case .text(let value) = value else { throw MemoryStoreError.databaseOperation }
            let result = value.withCString { sqlite3_bind_text(query, Int32(offset + 1), $0, -1, transient) }
            guard result == SQLITE_OK else { finishLookup(query); throw MemoryStoreError.databaseOperation }
        }
        return query
    }

    func finishLookup(_ query: OpaquePointer) {
        let reset = sqlite3_reset(query)
        let cleared = sqlite3_clear_bindings(query)
        if reset != SQLITE_OK || cleared != SQLITE_OK {
            if let sql = lookupStatements.first(where: { $0.value == query })?.key {
                lookupStatements.removeValue(forKey: sql)
            }
            sqlite3_finalize(query)
        }
    }

    enum SQLValue {
        case text(String), integer(Int64), real(Double), blob(Data), null
    }
    func statement(_ sql: String, _ values: [SQLValue] = []) throws -> OpaquePointer {
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
    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        #if MEMORY_FAULT_TESTING
        if sql.contains("INSERT INTO memory_entries"), let remaining = injectedInsertCountdown {
            if remaining == 0 {
                injectedInsertCountdown = nil
                throw MemoryStoreError.storageFull
            }
            injectedInsertCountdown = remaining - 1
        }
        #endif
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        let result = sqlite3_step(query)
        guard result == SQLITE_DONE else {
            if result == SQLITE_FULL { throw MemoryStoreError.storageFull }
            throw MemoryStoreError.databaseOperation
        }
    }
    func scalar(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
        return sqlite3_column_int64(query, 0)
    }
    func text(_ query: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(query, column) else { return "" }
        return String(cString: pointer)
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func setMetadata(_ key: String, _ value: String) throws {
        try execute("INSERT INTO memory_metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
    }
    func metadata(_ key: String) throws -> String? {
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
            guard version == 0 || version == 1 || version == Int64(Self.schemaVersion) else { throw MemoryStoreError.unsupportedSchema }
            if version == 0 { try createSchema() }
            else if version == 1 { try upgradeSchemaV2() }
            status.integrity = try verifyIntegrity()
            let previousMigrationState = try metadata("migration_status")
            status.migrationStatus = "discovering"
            var found = false, failed = false
            // Never remove originals. A failed import does not block a healthy new store.
            for source in legacyURLs {
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                found = true
                do { try migrate(source) } catch { failed = true }
            }
            let durableEntries = try scalar("SELECT COUNT(*) FROM memory_entries")
            if failed {
                status.migrationStatus = "partial_recovery"
            } else if previousMigrationState == "restored_from_snapshot", durableEntries > 0 {
                status.migrationStatus = "restored_from_snapshot"
            } else if previousMigrationState == "partial_recovery", !found {
                status.migrationStatus = "partial_recovery"
            } else if durableEntries == 0, try metadata("last_explicit_clear") != nil {
                status.migrationStatus = "cleared"
            } else if found || durableEntries > 0 {
                status.migrationStatus = "ready"
            } else {
                status.migrationStatus = "no_previous_memory"
            }
            if previousMigrationState != status.migrationStatus {
                try setMetadata("migration_status", status.migrationStatus)
            }
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
                "CREATE INDEX memory_legacy_pending ON memory_entries(source_language,target_language,validation_state,rules_version)",
                "CREATE TABLE memory_legacy_associations(legacy_id INTEGER NOT NULL REFERENCES memory_entries(id) ON DELETE CASCADE,current_id INTEGER NOT NULL REFERENCES memory_entries(id) ON DELETE CASCADE,kind TEXT NOT NULL,created_at REAL NOT NULL,PRIMARY KEY(legacy_id,current_id))",
                "CREATE INDEX memory_legacy_kind ON memory_legacy_associations(kind)",
                "CREATE TABLE memory_provenance(id INTEGER PRIMARY KEY,entry_id INTEGER NOT NULL REFERENCES memory_entries(id) ON DELETE CASCADE,source_format TEXT NOT NULL,source_fingerprint TEXT NOT NULL,legacy_key TEXT,import_batch TEXT NOT NULL,import_timestamp REAL NOT NULL,original_metadata TEXT,UNIQUE(entry_id,source_fingerprint,legacy_key))",
                "CREATE INDEX memory_provenance_source ON memory_provenance(source_fingerprint,entry_id)",
                "CREATE TABLE memory_conflicts(id INTEGER PRIMARY KEY,entry_id INTEGER NOT NULL REFERENCES memory_entries(id) ON DELETE CASCADE,alternative_id INTEGER NOT NULL REFERENCES memory_entries(id) ON DELETE CASCADE,created_at REAL NOT NULL,resolved INTEGER NOT NULL DEFAULT 0,UNIQUE(entry_id,alternative_id))",
                "CREATE TABLE migration_runs(id TEXT PRIMARY KEY,source_fingerprint TEXT NOT NULL,source_format TEXT NOT NULL,state TEXT NOT NULL,started_at REAL NOT NULL,finished_at REAL,imported INTEGER NOT NULL DEFAULT 0,duplicates INTEGER NOT NULL DEFAULT 0,errors INTEGER NOT NULL DEFAULT 0,reason TEXT)",
                "CREATE INDEX migration_source ON migration_runs(source_fingerprint,state)",
                "CREATE TABLE diagnostic_sessions(id TEXT PRIMARY KEY,started_at REAL NOT NULL,ended_at REAL NOT NULL,payload BLOB NOT NULL)",
                "CREATE TABLE diagnostic_events(id INTEGER PRIMARY KEY,session_id TEXT NOT NULL REFERENCES diagnostic_sessions(id) ON DELETE CASCADE,timestamp REAL NOT NULL,payload BLOB NOT NULL)",
                "CREATE INDEX diagnostic_event_time ON diagnostic_events(session_id,timestamp)",
                "CREATE INDEX diagnostic_session_time ON diagnostic_sessions(ended_at)",
                "PRAGMA user_version=2"
            ]
            for sql in statements { try execute(sql) }
            try setMetadata("schema_version", "2")
            try setMetadata("translation_rules_version", "v4-fingerprint")
            try setMetadata("normalization_version", "1")
            try setMetadata("segmentation_version", "1")
            try setMetadata("cache_key_version", "4")
            try setMetadata("diagnostic_event_version", "1")
            try setMetadata("export_version", "1")
        }
    }

    /// Non-destructive upgrade for devices that installed Memory 2.0 in v1.4.0 or v1.4.1.
    /// The old rows, their IDs and the existing recovery copies remain untouched.
    private func upgradeSchemaV2() throws {
        try transaction {
            try execute("CREATE INDEX IF NOT EXISTS memory_legacy_pending ON memory_entries(source_language,target_language,validation_state,rules_version)")
            try execute("CREATE TABLE IF NOT EXISTS memory_legacy_associations(legacy_id INTEGER NOT NULL REFERENCES memory_entries(id) ON DELETE CASCADE,current_id INTEGER NOT NULL REFERENCES memory_entries(id) ON DELETE CASCADE,kind TEXT NOT NULL,created_at REAL NOT NULL,PRIMARY KEY(legacy_id,current_id))")
            try execute("CREATE INDEX IF NOT EXISTS memory_legacy_kind ON memory_legacy_associations(kind)")
            try execute("PRAGMA user_version=2")
            try setMetadata("schema_version", "2")
        }
    }

    /// Parses historical byte-length prefixes, not delimiter splitting of source text.
    /// Delimiters and emoji may legitimately occur inside protected-token context.
    struct KeyParts {
        var source: String; var target: String; var sourceText: String; var context: String; var rules: String?
    }
    func keyParts(_ key: String) -> KeyParts? {
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
    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func normalized(_ text: String) -> String {
        // Conservative: case and punctuation carry meaning and are retained.
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    func insert(key: String, value: String, compatible: Bool, confirmed: Bool = true,
                        revalidateExisting: Bool = true) throws -> (id: Int64, inserted: Bool) {
        let parts = keyParts(key)
        let reusable = compatible && parts?.rules != nil && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let now = Date().timeIntervalSince1970
        let query = try statement("SELECT id FROM memory_entries WHERE canonical_key=? AND translated_text=?", [.text(key), .text(value)])
        defer { sqlite3_finalize(query) }
        let found = sqlite3_step(query)
        if found == SQLITE_ROW {
            let existingID = sqlite3_column_int64(query, 0)
            if reusable && confirmed && revalidateExisting {
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

    func lookupNow(key: String, started: Double, deadline: Double) -> MemoryLookupResult {
        // 2.2.1 (D10): measure how long this lookup queued behind saves, health queries and other lookups.
        let waitMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        var measured = lookupBody(key: key, started: started, deadline: deadline)
        measured.waitMs = waitMs
        return measured
    }

    private func lookupBody(key: String, started: Double, deadline: Double) -> MemoryLookupResult {
        func result(_ value: String? = nil, _ origin: String = "none", _ outcome: String) -> MemoryLookupResult {
            MemoryLookupResult(value: value, origin: origin, outcome: outcome, durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
        guard active else { return result(nil, "none", "unavailable") }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return result(nil, "none", "timeout") }
        guard keyParts(key)?.rules != nil else { return result(nil, "none", "incompatible") }
        do {
            // At most two indexed rows are read. Any conflicting ready outputs make
            // automatic reuse ambiguous; keep both and request fresh translation.
            let query = try lookupStatement("SELECT id,translated_text,EXISTS(SELECT 1 FROM memory_provenance p WHERE p.entry_id=memory_entries.id AND p.source_format IN ('envelope_v4','legacy_dictionary','envelope_v3','envelope_v2')) FROM memory_entries WHERE canonical_key=? AND validation_state='ready' AND confirmation_state='persisted' LIMIT 2", [.text(key)])
            defer { finishLookup(query) }
            let first = sqlite3_step(query)
            if first == SQLITE_DONE {
                return try lookupNormalized(key: key, started: started, deadline: deadline)
            }
            guard first == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
            let value = text(query, 1), imported = sqlite3_column_int(query, 2) != 0
            let second = sqlite3_step(query)
            if second == SQLITE_ROW { return result(nil, "none", "conflict") }
            guard second == SQLITE_DONE else { throw MemoryStoreError.databaseOperation }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return result(nil, "none", "timeout") }
            return result(value, imported ? "legacy" : "persistent", "hit")
        } catch { return result(nil, "none", "database_error") }
    }


    var failLegacyDeletion = false
}

