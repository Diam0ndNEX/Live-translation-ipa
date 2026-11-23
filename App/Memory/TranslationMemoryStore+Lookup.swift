import Foundation
import SQLite3
import CryptoKit

extension TranslationMemoryStore {
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
                self.measurement.report(result.waitMs)
                completion.finish(result)
            }
        }
    }
    /// Canonical Unicode equivalence is the only automatic normalized reuse.
    /// Never remove punctuation, whitespace, names or context to manufacture a hit.
    /// The language/normalized_source index bounds work before compatibility checks.
    func lookupNormalized(key: String, started: Double, deadline: Double) throws -> MemoryLookupResult {
        func result(_ value: String? = nil, _ origin: String = "none", _ outcome: String) -> MemoryLookupResult {
            MemoryLookupResult(value: value, origin: origin, outcome: outcome,
                durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
        guard let requested = keyParts(key), let rules = requested.rules
        else { return result(nil, "none", "incompatible") }
        let composed = requested.sourceText.precomposedStringWithCanonicalMapping
        let query = try lookupStatement("""
            SELECT canonical_key,translated_text,validation_state,confirmation_state
            FROM memory_entries
            WHERE source_language=? AND target_language=? AND normalized_source=?
            LIMIT 16
            """, [.text(requested.source), .text(requested.target),
                   .text(normalized(requested.sourceText))])
        defer { finishLookup(query) }
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

    /// 2.6.1: a saved unit whose letters and numbers equal the requested unit's (only case, punctuation or spacing
    /// differ). Same language pair, same rules and same context are required, a quarantined entry never counts,
    /// and two different saved translations mean no reuse. The translation gets the closing punctuation of the
    /// requested source. Any database problem is a miss: this path can only add hits.
    func lookupLoose(key: String, started: Double, deadline: Double) -> MemoryLookupResult {
        func result(_ value: String? = nil, _ origin: String = "none", _ outcome: String) -> MemoryLookupResult {
            MemoryLookupResult(value: value, origin: origin, outcome: outcome,
                durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
        guard let requested = keyParts(key), let rules = requested.rules else { return result(nil, "none", "miss") }
        let loose = LooseReuse.key(requested.sourceText)
        guard loose.count >= LooseReuse.minimumCharacters else { return result(nil, "none", "miss") }
        do {
            let query = try lookupStatement("""
                SELECT canonical_key,translated_text,validation_state,confirmation_state,source_text
                FROM memory_entries
                WHERE source_language=? AND target_language=? AND loose_key=?
                LIMIT 8
                """, [.text(requested.source), .text(requested.target), .text(loose)])
            defer { finishLookup(query) }
            var values: [String] = []
            var scanned = 0
            while true {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return result(nil, "none", "timeout") }
                let state = sqlite3_step(query)
                if state == SQLITE_DONE { break }
                guard state == SQLITE_ROW else { return result(nil, "none", "miss") }
                scanned += 1
                if scanned == 8 { return result(nil, "none", "ambiguous") }
                guard let parts = keyParts(text(query, 0)), parts.rules == rules, parts.context == requested.context,
                      text(query, 2) == "ready", text(query, 3) == "persisted" else { continue }
                let adapted = LooseReuse.adapt(storedSource: text(query, 4), storedTranslation: text(query, 1),
                                               requestedSource: requested.sourceText)
                if !values.contains(adapted) { values.append(adapted) }
            }
            if values.count == 1 { return result(values[0], "loose", "loose_hit") }
            return result(nil, "none", values.isEmpty ? "miss" : "conflict")
        } catch { return result(nil, "none", "miss") }
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
}
