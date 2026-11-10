import Foundation
import SQLite3
import CryptoKit

extension TranslationMemoryStore {
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
    #if MEMORY_FAULT_TESTING
    func injectLegacyDeletionFailure() { failLegacyDeletion = true }
    #endif

    /// Deletes only still-unvalidated legacy rows, across all language pairs
    /// and lengths. Rechecks state inside the transaction; migration receipts
    /// remain so retained import files cannot silently resurrect these rows.
    func deleteUnvalidatedLegacy(revision: Int) throws -> Int {
        guard active else { throw MemoryStoreError.unavailable }
        guard revision > latestRevision else { throw MemoryStoreError.staleRevision }
        let removed: Int = try transaction {
            try execute("DELETE FROM memory_entries WHERE validation_state='needs_validation' AND rules_version IS NULL")
            let count = Int(sqlite3_changes(db))
            #if MEMORY_FAULT_TESTING
            if failLegacyDeletion {
                failLegacyDeletion = false
                throw MemoryStoreError.databaseOperation
            }
            #endif
            try setMetadata("last_unvalidated_legacy_delete", String(Date().timeIntervalSince1970))
            return count
        }
        latestRevision = revision
        return removed
    }

    func delete(ids: [Int64]) throws {
        guard active else { throw MemoryStoreError.unavailable }
        try transaction { for id in ids { try execute("DELETE FROM memory_entries WHERE id=?", [.integer(id)]) } }
    }
    func readEntry(_ query: OpaquePointer) -> MemoryStoredEntry {
        MemoryStoredEntry(id: sqlite3_column_int64(query, 0), key: text(query, 1), sourceText: text(query, 2), translatedText: text(query, 3), sourceLanguage: text(query, 4), targetLanguage: text(query, 5), unitType: text(query, 6), validationState: text(query, 7), confirmationState: text(query, 8), createdAt: sqlite3_column_double(query, 9), updatedAt: sqlite3_column_double(query, 10), reuseCount: Int(sqlite3_column_int(query, 11)))
    }
    var entryColumns: String { "id,canonical_key,source_text,translated_text,source_language,target_language,unit_type,validation_state,confirmation_state,created_at,updated_at,reuse_count" }
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
}
