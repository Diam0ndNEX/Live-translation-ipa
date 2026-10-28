import Foundation
import SQLite3
import CryptoKit

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
    case invalidImport, unsupportedImport, sourceUnreadable, backupFailed, tooLarge, staleRevision, memoryNotEmpty, storageFull
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
    static let schemaVersion = 2
    let directory: URL
    private var db: OpaquePointer?
    private var active = false
    private var latestRevision = -1
    private var status = MemoryStoreHealth()
    #if MEMORY_FAULT_TESTING
    private var injectedInsertCountdown: Int?
    /// A deterministic simulated SQLITE_FULL fault; never compiled into the app.
    func injectStorageFull(afterSuccessfulInserts count: Int) {
        injectedInsertCountdown = max(0, count)
    }
    #endif
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
    private func insert(key: String, value: String, compatible: Bool, confirmed: Bool = true,
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
            let query = try statement("SELECT id,translated_text,EXISTS(SELECT 1 FROM memory_provenance p WHERE p.entry_id=memory_entries.id AND p.source_format IN ('envelope_v4','legacy_dictionary','envelope_v3','envelope_v2')) FROM memory_entries WHERE canonical_key=? AND validation_state='ready' AND confirmation_state='persisted' LIMIT 2", [.text(key)])
            defer { sqlite3_finalize(query) }
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


    /// Canonical Unicode equivalence is the only automatic normalized reuse.
    /// Never remove punctuation, whitespace, names or context to manufacture a hit.
    /// The language/normalized_source index bounds work before compatibility checks.
    private func lookupNormalized(key: String, started: Double, deadline: Double) throws -> MemoryLookupResult {
        func result(_ value: String? = nil, _ origin: String = "none", _ outcome: String) -> MemoryLookupResult {
            MemoryLookupResult(value: value, origin: origin, outcome: outcome,
                durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
        guard let requested = keyParts(key), let rules = requested.rules
        else { return result(nil, "none", "incompatible") }
        let composed = requested.sourceText.precomposedStringWithCanonicalMapping
        let query = try statement("""
            SELECT canonical_key,translated_text,validation_state,confirmation_state
            FROM memory_entries
            WHERE source_language=? AND target_language=? AND normalized_source=?
            LIMIT 16
            """, [.text(requested.source), .text(requested.target),
                   .text(normalized(requested.sourceText))])
        defer { sqlite3_finalize(query) }
        var matched: String?
        var scanned = 0
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline
            else { return result(nil, "none", "timeout") }
            let state = sqlite3_step(query)
            if state == SQLITE_DONE { break }
            guard state == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
            scanned += 1
            // If more matches might be unseen, refuse to guess.
            if scanned == 16 { return result(nil, "none", "ambiguous") }
            guard let parts = keyParts(text(query, 0)),
                  parts.rules == rules,
                  parts.context == requested.context,
                  parts.source == requested.source,
                  parts.target == requested.target,
                  parts.sourceText.precomposedStringWithCanonicalMapping == composed
            else { continue }
            // A quarantined canonical-equivalent variant must block automatic
            // normalized reuse instead of being bypassed by a different byte form.
            guard text(query, 2) == "ready", text(query, 3) == "persisted"
            else { return result(nil, "none", "incompatible") }
            if matched != nil { return result(nil, "none", "conflict") }
            matched = text(query, 1)
        }
        guard ProcessInfo.processInfo.systemUptime < deadline
        else { return result(nil, "none", "timeout") }
        return matched.map { result($0, "normalized", "normalized_hit") }
            ?? result(nil, "none", "miss")
    }

    /// Safely quarantine suspect entries for fresh translation. The original text
    /// remains persisted and inspectable; user history and settings are untouched.
    func quarantineEntries(ids: [Int64]) throws -> MemoryStoreHealth {
        guard active else { throw MemoryStoreError.unavailable }
        try transaction {
            for id in Set(ids) {
                try execute("""
                    UPDATE memory_entries SET validation_state='needs_validation',
                    confirmation_state='needs_validation',updated_at=?
                    WHERE id=?
                    """, [.real(Date().timeIntervalSince1970), .integer(id)])
            }
        }
        return try health()
    }

    /// Reconcile *only* independently generated, confirmed current-rule model results.
    /// An older key with no rules digest never becomes directly reusable: a new v4
    /// translation is persisted first, then the old row is marked as historical evidence.
    /// Exact language, NFC-equivalent source, and context must match. No fuzzy matching,
    /// no app-start mass validation, and no additional translation requests are made.
    private func reconcileLegacy(key: String, confirmedValue: String) throws {
        // Common case after migration: no pending legacy rows, so avoid even an
        // indexed SQLite lookup on the asynchronous confirmation-write path.
        guard status.legacyUnverified > 0 else { return }
        guard let fresh = keyParts(key), fresh.rules != nil,
              !confirmedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Indexed exact/prefix selection, capped even on large legacy stores.
        // Cross-language matches and unconstrained full-table fuzzy scans are forbidden.
        let normalizedSource = normalized(fresh.sourceText)
        let prefix = String(normalizedSource.prefix(2))
        guard prefix.count == 2 && !prefix.contains(where: { "*?[]%_".contains($0) }) else { return }
        let q = try statement("""
            SELECT id,canonical_key,source_text,translated_text FROM memory_entries
            WHERE source_language=? AND target_language=?
              AND rules_version IS NULL AND validation_state='needs_validation'
              AND (normalized_source=? OR normalized_source LIKE ?)
            ORDER BY CASE WHEN normalized_source=? THEN 0 ELSE 1 END, id DESC
            LIMIT 65
            """, [.text(fresh.source), .text(fresh.target),
                   .text(normalizedSource), .text(prefix + "%"), .text(normalizedSource)])
        defer { sqlite3_finalize(q) }
        var updates: [(id: Int64, state: String)] = []
        var suggestions: [(id: Int64, kind: LegacyAssociationKind)] = []
        var seen = 0
        while true {
            let code = sqlite3_step(q)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
            // Refuse an ambiguous or excessive set; leave all historical rows untouched.
            seen += 1
            if seen > 64 { return }
            let oldKey = text(q, 1)
            guard let old = keyParts(oldKey), old.rules == nil,
                  old.source == fresh.source, old.target == fresh.target,
                  old.context == fresh.context else { continue }
            let association = LegacyAssociation.classify(old: old.sourceText, new: fresh.sourceText)
            let id = sqlite3_column_int64(q, 0)
            if association == .exact {
                let oldValue = text(q, 3)
                // Differing natural translations are alternate wording, not proof
                // of a wrong old answer. Both outputs remain inspectable.
                let state = oldValue == confirmedValue ? "validated_legacy" : "superseded_legacy"
                updates.append((id: id, state: state))
            } else if association != .none {
                // Only store a review suggestion. No fuzzy OCR/fragment match
                // ever promotes a legacy translation to a usable memory hit.
                suggestions.append((id: id, kind: association))
            }
        }
        let now = Date().timeIntervalSince1970
        if !suggestions.isEmpty {
            let q = try statement("SELECT id FROM memory_entries WHERE canonical_key=? AND translated_text=? LIMIT 1",
                [.text(key), .text(confirmedValue)])
            let row = sqlite3_step(q)
            let currentID: Int64? = row == SQLITE_ROW ? sqlite3_column_int64(q, 0) : nil
            sqlite3_finalize(q)
            guard let currentID else { throw MemoryStoreError.databaseOperation }
            for suggestion in suggestions {
                try execute("""
                    INSERT OR IGNORE INTO memory_legacy_associations
                    (legacy_id,current_id,kind,created_at) VALUES(?,?,?,?)
                    """, [.integer(suggestion.id), .integer(currentID),
                           .text(suggestion.kind.rawValue), .real(now)])
            }
        }
        for update in updates {
            try execute("""
                UPDATE memory_entries SET validation_state=?, updated_at=?
                WHERE id=? AND validation_state='needs_validation' AND rules_version IS NULL
                """, [.text(update.state), .real(now), .integer(update.id)])
        }
    }

    struct LegacyIdleCandidate: Sendable {
        let id: Int64
        let source: String
        let target: String
        let text: String
        let previousOutput: String
    }

    /// Only called after user opt-in while foreground/idle. Cursor avoids repeatedly
    /// scheduling the same unsupported language pair or failing old entry.
    func nextLegacyIdleCandidate(target: String, selectedSource: String?,
                                 after id: Int64) throws -> LegacyIdleCandidate? {
        guard active else { throw MemoryStoreError.unavailable }
        let query = try statement("""
            SELECT id,canonical_key,source_text,translated_text,source_language,target_language
            FROM memory_entries
            WHERE validation_state='needs_validation' AND rules_version IS NULL
              AND target_language=? AND id>? AND LENGTH(source_text) BETWEEN 4 AND 240
              AND (? IS NULL OR source_language=?)
            ORDER BY id LIMIT 64
            """, [.text(target), .integer(id), selectedSource.map(SQLValue.text) ?? .null,
                   selectedSource.map(SQLValue.text) ?? .null])
        defer { sqlite3_finalize(query) }
        var scanned = 0
        while scanned < 64 {
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
            scanned += 1
            let key = text(query, 1)
            guard let parsed = keyParts(key), parsed.rules == nil,
                  parsed.context.isEmpty,
                  parsed.source == text(query, 4),
                  parsed.target == text(query, 5) else { continue }
            return LegacyIdleCandidate(id: sqlite3_column_int64(query, 0),
                source: parsed.source, target: parsed.target,
                text: parsed.sourceText, previousOutput: text(query, 3))
        }
        return nil
    }

    /// A successful fresh on-device model translation, independently requested
    /// while idle. This never trusts the historical output as translation truth.
    /// One transaction saves the v4 current translation and classifies the old
    /// record without deleting it. Fails closed if state changed in the meantime.
    func confirmIdleLegacy(id: Int64, currentKey: String,
                           freshOutput: String, revision: Int) throws -> MemoryStoreHealth {
        guard active else { throw MemoryStoreError.unavailable }
        guard revision > latestRevision else { throw MemoryStoreError.staleRevision }
        guard let parts = keyParts(currentKey), parts.rules != nil, parts.context.isEmpty,
              !freshOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw MemoryStoreError.invalidImport }
        try transaction {
            let query = try statement("""
                SELECT canonical_key,translated_text FROM memory_entries
                WHERE id=? AND rules_version IS NULL AND validation_state='needs_validation'
                """, [.integer(id)])
            let result = sqlite3_step(query)
            let oldKey = result == SQLITE_ROW ? text(query, 0) : ""
            let oldOutput = result == SQLITE_ROW ? text(query, 1) : ""
            sqlite3_finalize(query)
            guard result == SQLITE_ROW, let old = keyParts(oldKey),
                  old.source == parts.source, old.target == parts.target,
                  old.context.isEmpty, old.sourceText == parts.sourceText
            else { throw MemoryStoreError.staleRevision }
            _ = try insert(key: currentKey, value: freshOutput, compatible: true)
            try execute("""
                UPDATE memory_entries SET validation_state=?, updated_at=?
                WHERE id=? AND validation_state='needs_validation'
                """, [.text(oldOutput == freshOutput ? "validated_legacy" : "superseded_legacy"),
                       .real(Date().timeIntervalSince1970), .integer(id)])
        }
        latestRevision = revision
        return try health()
    }

    /// The caller supplies only confirmed eligible results. Return means COMMIT has
    /// succeeded. A failed transaction leaves every prior translation untouched.
    /// independentlyConfirmedKeys come only from current-model results that
    /// reached confirmed OCR (including an exact-match speculative result after
    /// confirmation), never from ordinary RAM, disk or imported memory hits.
    func save(_ entries: [String:String], revision: Int,
              independentlyConfirmedKeys: Set<String> = []) throws -> MemoryStoreHealth {
        guard active else { throw MemoryStoreError.unavailable }
        guard revision > latestRevision else { throw MemoryStoreError.staleRevision }
        do {
            try transaction {
                for (key, value) in entries {
                    guard keyParts(key)?.rules != nil, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    _ = try insert(key: key, value: value, compatible: true)
                    if independentlyConfirmedKeys.contains(key) {
                        try reconcileLegacy(key: key, confirmedValue: value)
                    }
                }
            }
        } catch { status.failedWrites += 1; throw error }
        latestRevision = revision // Only acknowledge the revision after SQLite COMMIT.
        return try health()
    }

    func health() throws -> MemoryStoreHealth {
        status.totalEntries = Int(try scalar("SELECT COUNT(*) FROM memory_entries"))
        status.readyEntries = Int(try scalar("SELECT COUNT(*) FROM memory_entries WHERE validation_state='ready'"))
        status.needsValidation = Int(try scalar("SELECT COUNT(*) FROM memory_entries WHERE validation_state='needs_validation'"))
        status.legacyValidated = Int(try scalar("SELECT COUNT(*) FROM memory_entries WHERE validation_state='validated_legacy'"))
        status.legacySuperseded = Int(try scalar("SELECT COUNT(*) FROM memory_entries WHERE validation_state='superseded_legacy'"))
        status.legacyUnverified = Int(try scalar("SELECT COUNT(*) FROM memory_entries WHERE validation_state='needs_validation' AND rules_version IS NULL"))
        status.suggestedOCRMatches = Int(try scalar("SELECT COUNT(DISTINCT legacy_id) FROM memory_legacy_associations WHERE kind IN ('orthographic','ocrCandidate')"))
        status.suggestedFragmentMatches = Int(try scalar("SELECT COUNT(DISTINCT legacy_id) FROM memory_legacy_associations WHERE kind='fragment'"))
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
        status.lastVerifiedBackup = try metadata("last_verified_backup").flatMap { $0.isEmpty ? nil : $0 }
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

    /// Destructive opt-in only, after a confirmed active-memory clear. This
    /// deliberately leaves history, settings, diagnostic sessions, and the
    /// active SQLite database untouched. A failed removal is not reported as
    /// success and can be retried without restoring deleted translations.
    /// Only explicit user actions enumerate or restore snapshots. Never replace
    /// an active SQLite/WAL file; merge entries transactionally instead.
    func recoverySnapshots() throws -> [String] {
        let folder = directory.appendingPathComponent("recovery", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("memory-") && $0.hasSuffix(".sqlite") &&
                !$0.contains("/") && !$0.contains("\\") }
            .sorted(by: >)
            .prefix(20)
            .map { $0 }
    }

    /// A recovery is additive: conflicting translations are retained and exact
    /// lookup rejects ambiguous matches. The active database is never replaced.
    func mergeRecoverySnapshot(named name: String) throws -> MemoryStoreHealth {
        guard active else { throw MemoryStoreError.unavailable }
        guard try recoverySnapshots().contains(name) else { throw MemoryStoreError.sourceUnreadable }
        let source = directory.appendingPathComponent("recovery", isDirectory: true)
            .appendingPathComponent(name)
        let handle = try FileHandle(forReadingFrom: source)
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            try? handle.close()
            throw MemoryStoreError.sourceUnreadable
        }
        try? handle.close()
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        var snapshotDB: OpaquePointer?
        guard sqlite3_open_v2(source.path, &snapshotDB,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
            let snapshotDB else {
            if let snapshotDB { sqlite3_close_v2(snapshotDB) }
            throw MemoryStoreError.backupFailed
        }
        defer { sqlite3_close_v2(snapshotDB) }

        func check(_ sql: String, expected: String) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(snapshotDB, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw MemoryStoreError.backupFailed }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  text(statement, 0) == expected else { throw MemoryStoreError.backupFailed }
        }
        try check("PRAGMA quick_check", expected: "ok")
        try check("PRAGMA user_version", expected: String(Self.schemaVersion))

        var reader: OpaquePointer?
        guard sqlite3_prepare_v2(snapshotDB,
            "SELECT canonical_key,translated_text,validation_state,confirmation_state FROM memory_entries ORDER BY id",
            -1, &reader, nil) == SQLITE_OK, let reader else {
            throw MemoryStoreError.backupFailed
        }
        defer { sqlite3_finalize(reader) }
        let batch = UUID().uuidString
        let now = Date().timeIntervalSince1970
        try transaction {
            var imported = 0, duplicates = 0
            while true {
                let step = sqlite3_step(reader)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw MemoryStoreError.backupFailed }
                let key = text(reader, 0)
                let value = text(reader, 1)
                let compatible = text(reader, 2) == "ready" &&
                    text(reader, 3) == "persisted"
                let result = try insert(key: key, value: value,
                    compatible: compatible, confirmed: compatible,
                    revalidateExisting: false)
                if result.inserted { imported += 1 } else { duplicates += 1 }
                try execute("""
                    INSERT OR IGNORE INTO memory_provenance(
                        entry_id,source_format,source_fingerprint,legacy_key,
                        import_batch,import_timestamp,original_metadata)
                    VALUES(?,?,?,?,?,?,?)
                    """, [.integer(result.id), .text("recovery_snapshot"),
                        .text(fingerprint), .text(key), .text(batch), .real(now),
                        .text("verified_snapshot")])
            }
            try execute("""
                INSERT INTO migration_runs(
                    id,source_fingerprint,source_format,state,started_at,finished_at,
                    imported,duplicates)
                VALUES(?,?,?,'ready',?,?,?,?)
                """, [.text(batch), .text(fingerprint), .text("recovery_snapshot"),
                    .real(now), .real(now), .integer(Int64(imported)),
                    .integer(Int64(duplicates))])
        }
        return try health()
    }

    /// Explicit, offline repair for an unreadable database. Never invoked by the
    /// translation pipeline. The damaged DB plus its WAL/SHM are moved together
    /// into a retained quarantine; a verified snapshot becomes the active store.
    /// Writes newer than the selected snapshot remain recoverable only from the
    /// quarantined files, so the UI must disclose that limitation.
    func recoverUnavailableStore(named name: String) throws -> MemoryStoreHealth {
        guard !active else { throw MemoryStoreError.unavailable }
        guard try recoverySnapshots().contains(name) else { throw MemoryStoreError.sourceUnreadable }
        let recovery = directory.appendingPathComponent("recovery", isDirectory: true)
        let snapshot = recovery.appendingPathComponent(name)

        func verified(_ url: URL) -> Bool {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(url.path, &handle,
                    SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                    let handle else {
                if let handle { sqlite3_close_v2(handle) }
                return false
            }
            defer { sqlite3_close_v2(handle) }
            func value(_ sql: String) -> String? {
                var query: OpaquePointer?
                guard sqlite3_prepare_v2(handle, sql, -1, &query, nil) == SQLITE_OK,
                      let query else { return nil }
                defer { sqlite3_finalize(query) }
                guard sqlite3_step(query) == SQLITE_ROW else { return nil }
                guard let bytes = sqlite3_column_text(query, 0) else { return nil }
                return String(cString: bytes)
            }
            return value("PRAGMA quick_check") == "ok" &&
                   value("PRAGMA user_version") == String(Self.schemaVersion)
        }
        guard verified(snapshot) else { throw MemoryStoreError.backupFailed }

        let temp = directory.appendingPathComponent(".restoring-" + UUID().uuidString + ".sqlite")
        try FileManager.default.copyItem(at: snapshot, to: temp)
        guard verified(temp) else {
            try? FileManager.default.removeItem(at: temp)
            throw MemoryStoreError.backupFailed
        }
        // A failed open can leave an inactive SQLite connection. No file move
        // is allowed until it has closed successfully.
        if let db {
            guard sqlite3_close(db) == SQLITE_OK else {
                try? FileManager.default.removeItem(at: temp)
                throw MemoryStoreError.databaseOperation
            }
            self.db = nil
        }

        let quarantine = recovery.appendingPathComponent("unhealthy-" + UUID().uuidString,
                                                           isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine,
                                                withIntermediateDirectories: true)
        let names = ["memory.sqlite", "memory.sqlite-wal", "memory.sqlite-shm"]
        var moved: [(original: URL, preserved: URL)] = []
        do {
            for filename in names {
                let original = directory.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: original.path) else { continue }
                let preserved = quarantine.appendingPathComponent(filename)
                try FileManager.default.moveItem(at: original, to: preserved)
                moved.append((original, preserved))
            }
            try FileManager.default.moveItem(
                at: temp, to: directory.appendingPathComponent("memory.sqlite"))
            _ = try prepare(legacyURLs: [])
            status.migrationStatus = "restored_from_snapshot"
            try setMetadata("migration_status", status.migrationStatus)
            return try self.health()
        } catch {
            active = false
            if let db {
                sqlite3_close_v2(db)
                self.db = nil
            }
            let newDatabase = directory.appendingPathComponent("memory.sqlite")
            if FileManager.default.fileExists(atPath: newDatabase.path) {
                try? FileManager.default.moveItem(
                    at: newDatabase,
                    to: quarantine.appendingPathComponent("uncommitted-restoration.sqlite"))
            }
            // If the staged database opened before a later error, it may have
            // created new WAL/SHM companions. Quarantine those separately so
            // they can never be paired with the original damaged database.
            for suffix in ["-wal", "-shm"] {
                let sidecar = directory.appendingPathComponent("memory.sqlite" + suffix)
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    try? FileManager.default.moveItem(
                        at: sidecar,
                        to: quarantine.appendingPathComponent("uncommitted-restoration" + suffix))
                }
            }
            for entry in moved.reversed() where
                FileManager.default.fileExists(atPath: entry.preserved.path) &&
                !FileManager.default.fileExists(atPath: entry.original.path) {
                try? FileManager.default.moveItem(at: entry.preserved, to: entry.original)
            }
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    func deletePreservedCopies(legacyURLs: [URL]) throws {
        guard active else { throw MemoryStoreError.unavailable }
        // Enforce the destructive operation's precondition at the storage boundary,
        // not only in the UI. Do not erase the last recovery sources of active data.
        guard try scalar("SELECT COUNT(*) FROM memory_entries") == 0 else {
            throw MemoryStoreError.memoryNotEmpty
        }
        let permitted = Set(["translation-memory-v4.json", "translation-memory.json"])
        for url in legacyURLs {
            guard permitted.contains(url.lastPathComponent) else { throw MemoryStoreError.sourceUnreadable }
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        for name in ["legacy", "recovery"] {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
        }
        try setMetadata("last_verified_backup", "")
        status.lastVerifiedBackup = nil
    }

    func clear(revision: Int) throws {
        guard active else { throw MemoryStoreError.unavailable }
        guard revision > latestRevision else { throw MemoryStoreError.staleRevision }
        try transaction {
            try execute("DELETE FROM memory_entries")
            // Retain migration receipts so intentionally deleted entries are not
            // silently reimported from protected legacy originals at next launch.
            try setMetadata("last_explicit_clear", String(Date().timeIntervalSince1970))
        }
        latestRevision = revision // A rolled-back clear must remain retryable.
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
                    compatible: entry.validationState == "ready" && entry.confirmationState == "persisted",
                    revalidateExisting: false)
            }
        }
        return try health()
    }

    /// The complete diagnostic session is stored as a bounded JSON snapshot.
    /// Selected metadata-only events also populate diagnostic_events for indexed
    /// session/time inspection. No OCR text or filenames are accepted from the UI.
    func saveDiagnosticSession(id: String, startedAt: Date, endedAt: Date,
                               payload: Data, events: [(timestamp: Double, payload: Data)] = []) throws {
        guard active else { throw MemoryStoreError.unavailable }
        guard payload.count <= 1024 * 1024, events.count <= 128,
              events.allSatisfy({ $0.timestamp.isFinite && $0.payload.count <= 4096 }),
              events.reduce(0, { $0 + $1.payload.count }) <= 512 * 1024
        else { throw MemoryStoreError.tooLarge }
        try transaction {
            try execute("INSERT INTO diagnostic_sessions(id,started_at,ended_at,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET ended_at=excluded.ended_at,payload=excluded.payload",
                [.text(id), .real(startedAt.timeIntervalSince1970),
                 .real(endedAt.timeIntervalSince1970), .blob(payload)])
            try execute("DELETE FROM diagnostic_events WHERE session_id=?", [.text(id)])
            for event in events {
                try execute("INSERT INTO diagnostic_events(session_id,timestamp,payload) VALUES(?,?,?)",
                    [.text(id), .real(event.timestamp), .blob(event.payload)])
            }
            try execute("DELETE FROM diagnostic_sessions WHERE ended_at < ? OR id NOT IN (SELECT id FROM diagnostic_sessions ORDER BY ended_at DESC LIMIT 20)",
                [.real(Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970)])
            // Both sessions and indexed events share the same 10 MiB cap.
            while try scalar("""
                SELECT COALESCE((SELECT SUM(length(payload)) FROM diagnostic_sessions),0)
                     + COALESCE((SELECT SUM(length(payload)) FROM diagnostic_events),0)
                """) > 10 * 1024 * 1024 {
                try execute("DELETE FROM diagnostic_sessions WHERE id=(SELECT id FROM diagnostic_sessions ORDER BY ended_at LIMIT 1)")
            }
        }
    }

    func loadDiagnosticEvents(sessionID: String, limit: Int = 128) throws -> [Data] {
        guard active else { throw MemoryStoreError.unavailable }
        let query = try statement(
            "SELECT payload FROM diagnostic_events WHERE session_id=? ORDER BY timestamp,id LIMIT ?",
            [.text(sessionID), .integer(Int64(min(128, max(1, limit))))])
        defer { sqlite3_finalize(query) }
        var result: [Data] = []
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
            if let bytes = sqlite3_column_blob(query, 0) {
                result.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0))))
            }
        }
        return result
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
