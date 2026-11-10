import Foundation
import SQLite3
import CryptoKit

extension TranslationMemoryStore {
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
            ORDER BY id LIMIT 1
            """, [.text(target), .integer(id), selectedSource.map(SQLValue.text) ?? .null,
                   selectedSource.map(SQLValue.text) ?? .null])
        defer { sqlite3_finalize(query) }
        let result = sqlite3_step(query)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
        let recordID = sqlite3_column_int64(query, 0)
        let key = text(query, 1)
        let parsed = keyParts(key)
        let eligible = parsed?.rules == nil && parsed?.context.isEmpty == true &&
            parsed?.source == text(query, 4) && parsed?.target == text(query, 5)
        // Return an empty source for malformed rows so the caller can advance
        // its cursor without accidentally sending unknown text to the model.
        return LegacyIdleCandidate(id: recordID,
            source: eligible ? (parsed?.source ?? "") : "",
            target: eligible ? (parsed?.target ?? "") : "",
            text: eligible ? (parsed?.sourceText ?? "") : "",
            previousOutput: text(query, 3))
    }

    /// Read-only inventory. Categories partition pending legacy records; scan
    /// candidates still require key, cleanup, segmentation and model checks.
    func legacyValidationInventory(target: String, selectedSource: String?) throws -> [String: Int] {
        guard active else { throw MemoryStoreError.unavailable }
        let pending = "validation_state='needs_validation' AND rules_version IS NULL"
        let all = Int(try scalar("SELECT COUNT(*) FROM memory_entries WHERE \(pending)"))
        let targetCount = Int(try scalar("SELECT COUNT(*) FROM memory_entries WHERE \(pending) AND target_language=?", [.text(target)]))
        let pair = pending + " AND target_language=? AND (? IS NULL OR source_language=?)"
        let values: [SQLValue] = [.text(target), selectedSource.map(SQLValue.text) ?? .null, selectedSource.map(SQLValue.text) ?? .null]
        let matching = Int(try scalar("SELECT COUNT(*) FROM memory_entries WHERE \(pair)", values))
        let candidates = Int(try scalar("SELECT COUNT(*) FROM memory_entries WHERE \(pair) AND LENGTH(source_text) BETWEEN 4 AND 240", values))
        return ["Pending legacy records": all, "Different target language": all - targetCount,
                "Different source language": targetCount - matching,
                "Outside 4–240 character range": matching - candidates,
                "Scan candidates before safety checks": candidates]
    }

    /// One bounded read instead of a separate SQLite call for each old entry.
    /// The caller can skip malformed rows, missing models and context-incompatible
    /// sources without loading all historical data into RAM.
    func nextLegacyIdleCandidates(target: String, selectedSource: String?,
                                  after id: Int64, limit: Int = 96) throws -> [LegacyIdleCandidate] {
        guard active else { throw MemoryStoreError.unavailable }
        let q = try statement("""
            SELECT id,canonical_key,translated_text,source_language,target_language
            FROM memory_entries
            WHERE validation_state='needs_validation' AND rules_version IS NULL
              AND target_language=? AND id>? AND LENGTH(source_text) BETWEEN 4 AND 240
              AND (? IS NULL OR source_language=?)
            ORDER BY id LIMIT ?
            """, [.text(target), .integer(id),
                   selectedSource.map(SQLValue.text) ?? .null,
                   selectedSource.map(SQLValue.text) ?? .null,
                   .integer(Int64(max(1, min(128, limit))))])
        defer { sqlite3_finalize(q) }
        var candidates: [LegacyIdleCandidate] = []
        while true {
            let result = sqlite3_step(q)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw MemoryStoreError.databaseOperation }
            let parsed = keyParts(text(q, 1))
            let eligible = parsed?.rules == nil && parsed?.context.isEmpty == true &&
                parsed?.source == text(q, 3) && parsed?.target == text(q, 4)
            candidates.append(LegacyIdleCandidate(id: sqlite3_column_int64(q, 0),
                source: eligible ? (parsed?.source ?? "") : "",
                target: eligible ? (parsed?.target ?? "") : "",
                text: eligible ? (parsed?.sourceText ?? "") : "",
                previousOutput: text(q, 2)))
        }
        return candidates
    }

    struct LegacyIdleConfirmation: Sendable {
        let id: Int64
        let currentKey: String
        let freshOutput: String
    }

    /// Batch commit is one WAL transaction and one health refresh. Every row is
    /// checked again against its original key, language and pending state before
    /// insertion. If one entry changed, rollback *all* new translations.
    func confirmIdleLegacyBatch(_ entries: [LegacyIdleConfirmation],
                                revision: Int) throws -> MemoryStoreHealth {
        guard active else { throw MemoryStoreError.unavailable }
        guard revision > latestRevision else { throw MemoryStoreError.staleRevision }
        guard !entries.isEmpty, entries.count <= IdleLegacyBatchPolicy.maximumEntries,
              Set(entries.map(\.id)).count == entries.count
        else { throw MemoryStoreError.invalidImport }
        do {
            try transaction {
                for item in entries {
                    guard let parts = keyParts(item.currentKey),
                          parts.rules != nil, parts.context.isEmpty,
                          !item.freshOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { throw MemoryStoreError.invalidImport }
                    let q = try statement("""
                        SELECT canonical_key,translated_text FROM memory_entries
                        WHERE id=? AND rules_version IS NULL
                          AND validation_state='needs_validation'
                        """, [.integer(item.id)])
                    let result = sqlite3_step(q)
                    let originalKey = result == SQLITE_ROW ? text(q, 0) : ""
                    let originalOutput = result == SQLITE_ROW ? text(q, 1) : ""
                    sqlite3_finalize(q)
                    guard result == SQLITE_ROW, let old = keyParts(originalKey),
                          old.rules == nil, old.source == parts.source,
                          old.target == parts.target, old.context.isEmpty,
                          old.sourceText == parts.sourceText
                    else { throw MemoryStoreError.staleRevision }
                    _ = try insert(key: item.currentKey,
                                   value: item.freshOutput, compatible: true)
                    try execute("""
                        UPDATE memory_entries SET validation_state=?, updated_at=?
                        WHERE id=? AND validation_state='needs_validation'
                        """, [.text(originalOutput == item.freshOutput ?
                                    "validated_legacy" : "superseded_legacy"),
                               .real(Date().timeIntervalSince1970), .integer(item.id)])
                }
            }
        } catch {
            status.failedWrites += 1
            throw error
        }
        latestRevision = revision
        return try health()
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
}
