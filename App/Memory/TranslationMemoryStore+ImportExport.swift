import Foundation
import SQLite3
import CryptoKit

extension TranslationMemoryStore {
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
        guard envelope.formatVersion == 1, [1, Self.schemaVersion].contains(envelope.schemaVersion) else { throw MemoryStoreError.unsupportedImport }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard digest(try encoder.encode(envelope.entries)) == envelope.checksum else { throw MemoryStoreError.integrityFailure }
        try transaction {
            for entry in envelope.entries {
                let inserted = try insert(key: entry.key, value: entry.translatedText,
                    compatible: entry.validationState == "ready" && entry.confirmationState == "persisted",
                    revalidateExisting: false)
                if inserted.inserted, keyParts(entry.key)?.rules == nil,
                   ["validated_legacy", "superseded_legacy"].contains(entry.validationState) {
                    try execute("""
                        UPDATE memory_entries SET validation_state=?,confirmation_state=?
                        WHERE id=? AND rules_version IS NULL
                        """, [.text(entry.validationState),
                               .text(entry.confirmationState), .integer(inserted.id)])
                }
            }
        }
        return try health()
    }
}
