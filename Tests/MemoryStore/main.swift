import Foundation

@main struct MemoryTests {
    static func main() async throws {
        precondition(MemoryUnitClassifier.classify("Olá") == .word)
        precondition(MemoryUnitClassifier.classify("don't") == .word)
        precondition(MemoryUnitClassifier.classify("Olá meu amigo") == .phrase)
        precondition(MemoryUnitClassifier.classify("How are you?") == .sentence)
        precondition(MemoryUnitClassifier.classify("Scrolling lyric\ncontinued") == .subtitleFragment)
        precondition(MemoryUnitClassifier.classify("I don't know what else to say now") == .subtitleFragment)
        precondition(MemoryUnitClassifier.classify("123") == .unknown)
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
        // A partially unreadable legacy file must not be silently described as migrated.
        let damagedLegacy = root.appendingPathComponent("corrupt-legacy.json")
        try Data("{broken json".utf8).write(to: damagedLegacy)
        let damagedStore = TranslationMemoryStore(directory: root.appendingPathComponent("damaged-db"))
        let damagedHealth = try await damagedStore.prepare(legacyURLs: [damagedLegacy])
        precondition(damagedHealth.migrationStatus == "partial_recovery" && damagedHealth.totalEntries == 0)
        precondition(FileManager.default.fileExists(atPath: damagedLegacy.path))
        let malformedBackup = root.appendingPathComponent("damaged-db/legacy")
        precondition((try FileManager.default.contentsOfDirectory(atPath: malformedBackup.path)).count == 1)

        // A fresh authoritative sentence receives an explicit category. Unknown legacy
        // keys keep their restricted validation state and must not be reclassified as ready.
        let sentenceKey = "v4|\\(rules)|pt>en|0:|How are you?"
        _ = try await store.save([sentenceKey:"Como você está?"], revision: 2)
        let classified = try await store.search(query: "How are you?", limit: 5)
        precondition(classified.count == 1 && classified[0].sourceText == "How are you?")
        let counted = try await store.health()
        precondition(counted.categoryCounts["sentence", default: 0] >= 1)

        _ = try await store.save([key:"Alternative"], revision: 3)
        let conflict = await store.lookup(key: key, timeoutMilliseconds: 50)
        precondition(conflict.value == nil, "Conflicting outputs must force fresh translation")
        let exported = try await store.exportData()
        let imported = TranslationMemoryStore(directory: root.appendingPathComponent("roundtrip"))
        _ = try await imported.prepare(legacyURLs: [])
        let importedHealth = try await imported.importData(exported)
        precondition(importedHealth.totalEntries == 3)
        // A changed export must fail checksum verification without touching the store.
        var tampered = exported
        let original = Data("Alternative".utf8), replacement = Data("Mischievous".utf8)
        if let range = tampered.range(of: original) { tampered.replaceSubrange(range, with: replacement) }
        let previouslyImported = (try await imported.health()).totalEntries
        do {
            _ = try await imported.importData(tampered)
            preconditionFailure("Modified backup must be rejected")
        } catch {
            let stillImported = try await imported.health()
            precondition(stillImported.totalEntries == previouslyImported)
        }

        try await store.clear(revision: 4)
        do {
            _ = try await store.save([key:"Stale work"], revision: 3)
            preconditionFailure("Old in-flight write must be fenced by clear revision")
        } catch MemoryStoreError.staleRevision { }

        let reopened = TranslationMemoryStore(directory: root.appendingPathComponent("db"))
        let cleared = try await reopened.prepare(legacyURLs: [legacy])
        precondition(cleared.totalEntries == 0, "Clear must not reimport legacy memory")
        precondition(FileManager.default.fileExists(atPath: legacy.path))
        print("SQLite migration, recovery, integrity checks, classification, revision barrier and clear/reopen passed")
    }
}
