import Foundation

@main struct MemoryTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rules = String(repeating: "a", count: 64)
        let key = "v4|\(rules)|pt>en|0:|Olá."
        let legacy = root.appendingPathComponent("translation-memory-v4.json")
        try JSONEncoder().encode(MemoryEnvelope(entries: [key:"Hello."])).write(to: legacy)
        let store = TranslationMemoryStore(directory: root.appendingPathComponent("db"))
        let first = try await store.prepare(legacyURLs: [legacy])
        precondition(first.totalEntries == 1)
        let hit = await store.lookup(key: key, timeoutMilliseconds: 1000)
        precondition(hit.value == "Hello.")
        _ = try await store.save([key:"Hello."], revision: 1)
        let repeated = try await store.prepare(legacyURLs: [legacy])
        precondition(repeated.totalEntries == 1)
        let unknownKey = "v2|pt>en|0:|Antigo"
        let oldJSON = root.appendingPathComponent("translation-memory.json")
        try JSONEncoder().encode([unknownKey:"Old"]).write(to: oldJSON)
        let secondStore = TranslationMemoryStore(directory: root.appendingPathComponent("legacy-db"))
        let unknownHealth = try await secondStore.prepare(legacyURLs: [oldJSON])
        precondition(unknownHealth.totalEntries == 1 && unknownHealth.needsValidation == 1)
        let unsafeHit = await secondStore.lookup(key: unknownKey)
        precondition(unsafeHit.value == nil, "Unknown rules must never be authoritative")
        _ = try await store.save([key:"Alternative"], revision: 2)
        let conflict = await store.lookup(key: key, timeoutMilliseconds: 50)
        precondition(conflict.value == nil, "Conflicting outputs must force fresh translation")
        let exported = try await store.exportData()
        let imported = TranslationMemoryStore(directory: root.appendingPathComponent("roundtrip"))
        _ = try await imported.prepare(legacyURLs: [])
        let importedHealth = try await imported.importData(exported)
        precondition(importedHealth.totalEntries == 2)
        try await store.clear(revision: 3)
        let reopened = TranslationMemoryStore(directory: root.appendingPathComponent("db"))
        let cleared = try await reopened.prepare(legacyURLs: [legacy])
        precondition(cleared.totalEntries == 0, "Clear must not reimport legacy memory")
        precondition(FileManager.default.fileExists(atPath: legacy.path))
        print("SQLite import, exact reuse, idempotence, clear/reopen and original preservation passed")
    }
}
