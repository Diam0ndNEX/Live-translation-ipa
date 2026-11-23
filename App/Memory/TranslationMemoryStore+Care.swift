import Foundation
import SQLite3

// 2.6.3 (switch memoryCare): RAM warm-up and quarantine of a defective saved translation. Neither changes the
// schema. A database error gives an empty result and never fails the caller.
extension TranslationMemoryStore {
    /// The most recently used ready, persisted units of these rules and this target language, at most `limit`,
    /// as (unit key, translation). A key saved with two different translations is left out.
    func recentEntries(rules: String, target: String, limit: Int) -> [(String, String)] {
        guard active, !rules.isEmpty, !target.isEmpty, limit > 0 else { return [] }
        let prefix = MemoryCare.rulesPrefix(rules)
        do {
            let query = try statement("""
                SELECT canonical_key, MIN(translated_text), COUNT(DISTINCT translated_text) AS variants,
                       MAX(COALESCE(last_used_at, updated_at)) AS used
                FROM memory_entries
                WHERE substr(canonical_key,1,?)=? AND validation_state='ready' AND confirmation_state='persisted'
                GROUP BY canonical_key
                HAVING variants=1
                ORDER BY used DESC
                LIMIT ?
                """, [.integer(Int64(prefix.count)), .text(prefix), .integer(Int64(limit * 4))])
            defer { sqlite3_finalize(query) }
            var out: [(String, String)] = []
            while out.count < limit, sqlite3_step(query) == SQLITE_ROW {
                let key = text(query, 0), value = text(query, 1)
                guard MemoryCare.target(key) == target, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                out.append((key, value))
            }
            return out
        } catch { return [] }
    }

    /// Sends the saved translation(s) behind `key` back for validation: the exact row and, with the same rules,
    /// language pair and context, the rows a loose lookup would reuse. The text stays saved and inspectable.
    /// Returns the number of rows changed.
    func quarantine(requestedKey key: String) -> Int {
        guard active, let parts = keyParts(key), let rules = parts.rules else { return 0 }
        do {
            var ids = Set<Int64>()
            let exact = try statement("SELECT id FROM memory_entries WHERE canonical_key=? AND validation_state='ready'", [.text(key)])
            while sqlite3_step(exact) == SQLITE_ROW { ids.insert(sqlite3_column_int64(exact, 0)) }
            sqlite3_finalize(exact)
            let loose = LooseReuse.key(parts.sourceText)
            if loose.count >= LooseReuse.minimumCharacters {
                let similar = try statement("""
                    SELECT id, canonical_key FROM memory_entries
                    WHERE source_language=? AND target_language=? AND loose_key=? AND validation_state='ready' LIMIT 16
                    """, [.text(parts.source), .text(parts.target), .text(loose)])
                while sqlite3_step(similar) == SQLITE_ROW {
                    if let other = keyParts(text(similar, 1)), other.rules == rules, other.context == parts.context {
                        ids.insert(sqlite3_column_int64(similar, 0))
                    }
                }
                sqlite3_finalize(similar)
            }
            guard !ids.isEmpty else { return 0 }
            let now = Date().timeIntervalSince1970
            try transaction {
                for id in ids {
                    try execute("UPDATE memory_entries SET validation_state='needs_validation',confirmation_state='needs_validation',updated_at=? WHERE id=?",
                                [.real(now), .integer(id)])
                }
            }
            return ids.count
        } catch { return 0 }
    }
}
