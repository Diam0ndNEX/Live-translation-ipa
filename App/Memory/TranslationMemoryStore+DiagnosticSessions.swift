import Foundation
import SQLite3

extension TranslationMemoryStore {
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
