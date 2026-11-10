import Foundation
import SQLite3
import CryptoKit

extension TranslationMemoryStore {
    /// The caller supplies only confirmed eligible results. Return means COMMIT has
    /// succeeded. A failed transaction leaves every prior translation untouched.
    /// independentlyConfirmedKeys come only from current-model results that
    /// reached confirmed OCR (including an exact-match speculative result after
    /// confirmation), never from ordinary RAM, disk or imported memory hits.
    func save(_ entries: [String:String], revision: Int,
              independentlyConfirmedKeys: Set<String> = [],
              knownDefaultStrategyKeys: Set<String> = []) throws -> MemoryStoreHealth {
        guard active else { throw MemoryStoreError.unavailable }
        guard revision > latestRevision else { throw MemoryStoreError.staleRevision }
        do {
            try transaction {
                for (key, value) in entries {
                    guard keyParts(key)?.rules != nil, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let inserted = try insert(key: key, value: value, compatible: true)
                    if knownDefaultStrategyKeys.contains(key) {
                        // Add a new observation; do not relabel or erase historical provenance.
                        // The existing schema can represent this metadata without a migration.
                        let fingerprint = digest(Data((key + "\u{1F}" + value + "\u{1F}appleDefault").utf8))
                        try execute("""
                            INSERT OR IGNORE INTO memory_provenance(entry_id,source_format,source_fingerprint,legacy_key,import_batch,import_timestamp,original_metadata)
                            VALUES(?,?,?,?,?,?,?)
                            """, [.integer(inserted.id), .text("live_v190"), .text(fingerprint), .text(key),
                                   .text("live_v190"), .real(Date().timeIntervalSince1970),
                                   .text("{\"requestedStrategy\":\"appleDefault\",\"effectiveModel\":\"unknown\",\"qualityTier\":\"preferred\",\"sourceConfirmed\":true}")])
                    }
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
        let healthBegan = ProcessInfo.processInfo.systemUptime
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
        // Set before the copy is returned, so the caller sees the time this query took.
        status.lastHealthMs = (ProcessInfo.processInfo.systemUptime - healthBegan) * 1000
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
}
