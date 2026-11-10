import Foundation
import SQLite3
import CryptoKit

extension TranslationMemoryStore {
    /// Reconcile *only* independently generated, confirmed current-rule model results.
    /// An older key with no rules digest never becomes directly reusable: a new v4
    /// translation is persisted first, then the old row is marked as historical evidence.
    /// Exact language, NFC-equivalent source, and context must match. No fuzzy matching,
    /// no app-start mass validation, and no additional translation requests are made.
    func reconcileLegacy(key: String, confirmedValue: String) throws {
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
              AND (normalized_source=? OR normalized_source LIKE ?
                   OR normalized_source LIKE ? OR INSTR(?, normalized_source)>0)
            ORDER BY CASE WHEN normalized_source=? THEN 0 ELSE 1 END, id DESC
            LIMIT 65
            """, [.text(fresh.source), .text(fresh.target),
                   .text(normalizedSource), .text(prefix + "%"),
                   .text("%" + normalizedSource + "%"), .text(normalizedSource),
                   .text(normalizedSource)])
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
}
