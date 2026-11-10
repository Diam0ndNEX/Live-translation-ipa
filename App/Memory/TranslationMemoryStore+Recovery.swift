import Foundation
import SQLite3
import CryptoKit

extension TranslationMemoryStore {
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

        func statementForReadOnly(_ db: OpaquePointer, sql: String) throws -> OpaquePointer {
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK,
                  let pointer else { throw MemoryStoreError.backupFailed }
            return pointer
        }
        func check(_ sql: String, expected: String) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(snapshotDB, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw MemoryStoreError.backupFailed }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  text(statement, 0) == expected else { throw MemoryStoreError.backupFailed }
        }
        try check("PRAGMA quick_check", expected: "ok")
        // A verified schema-v1 recovery image is still a valid source of saved
        // translations. Its memory_entries layout is compatible with schema-v2.
        let versionQuery = try statementForReadOnly(snapshotDB, sql: "PRAGMA user_version")
        let snapshotVersion = sqlite3_step(versionQuery) == SQLITE_ROW ?
            sqlite3_column_int64(versionQuery, 0) : -1
        sqlite3_finalize(versionQuery)
        guard snapshotVersion == 1 || snapshotVersion == Int64(Self.schemaVersion)
        else { throw MemoryStoreError.backupFailed }

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
                   ["1", String(Self.schemaVersion)].contains(value("PRAGMA user_version") ?? "")
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
        clearLookupStatements()
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
            clearLookupStatements()
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
}
