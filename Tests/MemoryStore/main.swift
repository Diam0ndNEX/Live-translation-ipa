import Foundation
import SQLite3

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
        let preservedBackups = try FileManager.default.contentsOfDirectory(atPath: malformedBackup.path)
        precondition(preservedBackups.count == 1)

        // A fresh authoritative sentence receives an explicit category. Unknown legacy
        // keys keep their restricted validation state and must not be reclassified as ready.
        let sentenceKey = "v4|\(rules)|pt>en|0:|How are you?"
        _ = try await store.save([sentenceKey:"Como você está?"], revision: 2)
        let classified = try await store.search(query: "How are you?", limit: 5)
        precondition(classified.count == 1 && classified[0].sourceText == "How are you?")
        let counted = try await store.health()
        precondition(counted.categoryCounts["sentence", default: 0] >= 1)

        _ = try await store.save([key:"Alternative"], revision: 3)
        let conflict = await store.lookup(key: key, timeoutMilliseconds: 50)
        precondition(conflict.value == nil, "Conflicting outputs must force fresh translation")
        let alternatives = try await store.conflictingEntries(limit: 10)
        precondition(Set(alternatives.map(\.translatedText)).isSuperset(of: ["Hello.", "Alternative"]),
                     "Both legitimate conflicting translations must stay inspectable")
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

        // An accidental recovery purge before a verified clear must be rejected.
        do {
            try await store.deletePreservedCopies(legacyURLs: [legacy])
            preconditionFailure("Recovery originals must not be erased while memory exists")
        } catch MemoryStoreError.memoryNotEmpty {
            precondition(FileManager.default.fileExists(atPath: legacy.path))
        }

        let snapshotName = try await store.createRecoverySnapshot()
        let snapshotURL = root.appendingPathComponent("db/recovery").appendingPathComponent(snapshotName)
        precondition(FileManager.default.fileExists(atPath: snapshotURL.path),
                     "Snapshot must be created through SQLite, not a WAL-blind file copy")
        let backupHealth = try await store.health()
        precondition(backupHealth.lastVerifiedBackup != nil,
                     "Health must expose a verified recovery snapshot timestamp")
        try await store.clear(revision: 4)
        precondition(FileManager.default.fileExists(atPath: snapshotURL.path),
                     "Clearing active memory must never delete the recovery snapshot")
        do {
            _ = try await store.save([key:"Stale work"], revision: 3)
            preconditionFailure("Old in-flight write must be fenced by clear revision")
        } catch MemoryStoreError.staleRevision { }

        // A future database schema is not downgraded or silently overwritten.
        let futureDirectory = root.appendingPathComponent("future-db")
        try FileManager.default.createDirectory(at: futureDirectory, withIntermediateDirectories: true)
        let futureFile = futureDirectory.appendingPathComponent("memory.sqlite")
        var futureConnection: OpaquePointer?
        precondition(sqlite3_open(futureFile.path, &futureConnection) == SQLITE_OK)
        precondition(sqlite3_exec(futureConnection, "PRAGMA user_version=99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(futureConnection)
        let futureStore = TranslationMemoryStore(directory: futureDirectory)
        do {
            _ = try await futureStore.prepare(legacyURLs: [])
            preconditionFailure("Unknown future schema must not be opened for writes")
        } catch MemoryStoreError.unsupportedSchema {
            precondition(FileManager.default.fileExists(atPath: futureFile.path))
        }

        // Corrupt SQLite files are preserved for diagnosis; never recreate an
        // empty database over the damaged original.
        let corruptDirectory = root.appendingPathComponent("corrupt-db")
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let corruptFile = corruptDirectory.appendingPathComponent("memory.sqlite")
        try Data("not-a-sqlite-database".utf8).write(to: corruptFile)
        let corruptStore = TranslationMemoryStore(directory: corruptDirectory)
        do {
            _ = try await corruptStore.prepare(legacyURLs: [])
            preconditionFailure("Corrupt database must not silently initialize")
        } catch {
            precondition(FileManager.default.fileExists(atPath: corruptFile.path))
            let attributes = try FileManager.default.attributesOfItem(atPath: corruptFile.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            precondition(size > 0)
        }

        // Actor serialization must make revisions deterministic independent of
        // task scheduling. A higher-revision clear always defeats an older save.
        let raceStore = TranslationMemoryStore(directory: root.appendingPathComponent("race-db"))
        _ = try await raceStore.prepare(legacyURLs: [])
        let olderSave = Task {
            try? await raceStore.save([key: "Older confirmation"], revision: 7)
        }
        let newerClear = Task {
            try? await raceStore.clear(revision: 8)
        }
        _ = await olderSave.value
        _ = await newerClear.value
        let afterClearRace = try await raceStore.health()
        precondition(afterClearRace.totalEntries == 0,
                     "A late older save must never resurrect entries after a clear")

        // Conversely, a newer confirmed translation is retained even if an older
        // clear is interleaved before or after the new commit.
        let newerSave = Task {
            try? await raceStore.save([key: "Newer confirmation"], revision: 10)
        }
        let olderClear = Task {
            try? await raceStore.clear(revision: 9)
        }
        _ = await newerSave.value
        _ = await olderClear.value
        let afterNewerRace = await raceStore.lookup(key: key, timeoutMilliseconds: 50)
        precondition(afterNewerRace.value == "Newer confirmation",
                     "An older clear must never destroy a newer confirmed write")
        print("Concurrent revision-fence checks passed")

        // Optional diagnostic sessions remain bounded and independent of memory,
        // even when active translation memory is explicitly cleared.
        let sessionStore = TranslationMemoryStore(directory: root.appendingPathComponent("session-db"))
        _ = try await sessionStore.prepare(legacyURLs: [])
        _ = try await sessionStore.save([key: "Keep diagnostic history separate"], revision: 1)
        let now = Date()
        for index in 0..<25 {
            let bytes = Data("metadata-only-session-\(index)".utf8)
            try await sessionStore.saveDiagnosticSession(id: "test-\(index)",
                startedAt: now.addingTimeInterval(Double(index)),
                endedAt: now.addingTimeInterval(Double(index)),
                payload: bytes)
        }
        let boundedSessions = try await sessionStore.loadDiagnosticSessions()
        precondition(boundedSessions.count == 20, "Diagnostic archive must retain at most 20 sessions")
        do {
            try await sessionStore.saveDiagnosticSession(id: "oversized",
                startedAt: now, endedAt: now,
                payload: Data(repeating: 0x78, count: 1_048_577))
            preconditionFailure("Diagnostic sessions larger than 1 MiB must be rejected")
        } catch MemoryStoreError.tooLarge { }
        try await sessionStore.clear(revision: 2)
        let sessionsAfterMemoryClear = try await sessionStore.loadDiagnosticSessions()
        precondition(sessionsAfterMemoryClear.count == 20,
                     "Memory deletion must not erase independent diagnostic sessions")
        try await sessionStore.clearDiagnosticSessions()
        let sessionsAfterDiagnosticClear = try await sessionStore.loadDiagnosticSessions()
        precondition(sessionsAfterDiagnosticClear.isEmpty,
                     "Diagnostic deletion must not depend on translation-memory deletion")
        print("Diagnostic session retention, size cap and independent deletion checks passed")

        let reopened = TranslationMemoryStore(directory: root.appendingPathComponent("db"))
        let cleared = try await reopened.prepare(legacyURLs: [legacy])
        precondition(cleared.totalEntries == 0, "Clear must not reimport legacy memory")
        precondition(FileManager.default.fileExists(atPath: legacy.path))
        // Restore is additive and explicit. A previous Clear cannot be undone by
        // legacy migration, but a user-selected verified snapshot can be merged.
        let availableSnapshots = try await reopened.recoverySnapshots()
        precondition(availableSnapshots.contains(snapshotName))
        let recoveredHealth = try await reopened.mergeRecoverySnapshot(named: snapshotName)
        precondition(recoveredHealth.totalEntries == 3)
        let recoveredConflict = await reopened.lookup(key: key, timeoutMilliseconds: 50)
        precondition(recoveredConflict.value == nil, "Recovered conflicting translations must stay blocked")
        let recoveredSentence = await reopened.lookup(key: sentenceKey, timeoutMilliseconds: 50)
        precondition(recoveredSentence.value == "Como você está?")
        precondition(recoveredSentence.origin == "persistent",
                     "Recovered provenance must not inflate legacy lookup hits")
        let repeatRecovery = try await reopened.mergeRecoverySnapshot(named: snapshotName)
        precondition(repeatRecovery.totalEntries == 3, "Snapshot re-merge must be idempotent")
        do {
            _ = try await reopened.mergeRecoverySnapshot(named: "../memory.sqlite")
            preconditionFailure("Recovery filenames must reject path traversal")
        } catch MemoryStoreError.sourceUnreadable { }
        try await reopened.clear(revision: 5)

        try await reopened.deletePreservedCopies(legacyURLs: [legacy, oldJSON])
        precondition(!FileManager.default.fileExists(atPath: legacy.path))
        precondition(!FileManager.default.fileExists(atPath: snapshotURL.path))
        let purgedHealth = try await reopened.health()
        precondition(purgedHealth.lastVerifiedBackup == nil,
                     "Explicit purge must clear the recovery-backup indicator")
        print("SQLite migration, recovery, integrity checks, classification, revision barrier and clear/reopen passed")
    }
}
