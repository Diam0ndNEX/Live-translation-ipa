import Foundation
import SQLite3
import CryptoKit

@main struct MemoryTests {
    static func main() async throws {
        precondition(MemoryUnitClassifier.classify("Olá") == .word)
        precondition(MemoryUnitClassifier.classify("don't") == .word)
        precondition(MemoryUnitClassifier.classify("Olá meu amigo") == .phrase)
        precondition(MemoryUnitClassifier.classify("How are you?") == .sentence)
        precondition(MemoryUnitClassifier.classify("Scrolling lyric\ncontinued") == .subtitleFragment)
        precondition(MemoryUnitClassifier.classify("I don't know what else to say now") == .phrase)
        precondition(MemoryUnitClassifier.classify("123") == .unknown)
        precondition(MemoryUnitClassifier.classify("— New speaker starts") == .subtitleFragment)
        precondition(MemoryUnitClassifier.classify("To be continued…") == .subtitleFragment)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rules = String(repeating: "a", count: 64)
        let key = "v4|\(rules)|pt>en|0:|Olá."
        // Deterministic disk-full fault in the second INSERT of a transaction.
        // A partial batch must roll back completely while prior memory survives.
        #if MEMORY_FAULT_TESTING
        let fullStore = TranslationMemoryStore(
            directory: root.appendingPathComponent("simulated-low-storage"))
        _ = try await fullStore.prepare(legacyURLs: [])
        let intactKey = "v4|\(rules)|pt>en|0:|Original persisted memory"
        let newKeyA = "v4|\(rules)|pt>en|0:|Pending low-storage entry A"
        let newKeyB = "v4|\(rules)|pt>en|0:|Pending low-storage entry B"
        _ = try await fullStore.save([intactKey: "Original output"], revision: 1)
        await fullStore.injectStorageFull(afterSuccessfulInserts: 1)
        do {
            _ = try await fullStore.save(
                [newKeyA: "First output", newKeyB: "Second output"], revision: 2)
            preconditionFailure("Injected disk-full condition should abort the full batch")
        } catch MemoryStoreError.storageFull { }
        let afterFailedBatch = try await fullStore.health()
        precondition(afterFailedBatch.totalEntries == 1 && afterFailedBatch.failedWrites >= 1,
                     "Failed multi-insert commit must preserve the original durable data")
        let intactHit = await fullStore.lookup(key: intactKey, timeoutMilliseconds: 50)
        let missingA = await fullStore.lookup(key: newKeyA, timeoutMilliseconds: 50)
        let missingB = await fullStore.lookup(key: newKeyB, timeoutMilliseconds: 50)
        precondition(intactHit.value == "Original output" &&
                     missingA.value == nil && missingB.value == nil,
                     "Partially written low-storage transaction must not leak entries")
        _ = try await fullStore.save(
            [newKeyA: "First output", newKeyB: "Second output"], revision: 3)
        let afterRecoveredWrite = try await fullStore.health()
        precondition(afterRecoveredWrite.totalEntries == 3,
                     "Confirmed writes can retry after storage capacity is restored")
        #endif

        // Reopening a populated SQLite store without any legacy JSON file is not
        // "no previous memory"; that status must survive multi-year app upgrades.
        let durableDirectory = root.appendingPathComponent("already-migrated")
        let durableKey = "v4|\(rules)|pt>en|0:|Known durable translation."
        do {
            let previousLaunch = TranslationMemoryStore(directory: durableDirectory)
            _ = try await previousLaunch.prepare(legacyURLs: [])
            _ = try await previousLaunch.save(
                [durableKey: "Persisted from earlier launch."], revision: 1)
        }
        let nextLaunch = TranslationMemoryStore(directory: durableDirectory)
        let reopenedHealth = try await nextLaunch.prepare(legacyURLs: [])
        precondition(reopenedHealth.totalEntries == 1 &&
                     reopenedHealth.migrationStatus == "ready",
                     "Existing SQLite data must be recognized on app restart")
        let reopenedHit = await nextLaunch.lookup(key: durableKey, timeoutMilliseconds: 50)
        precondition(reopenedHit.value == "Persisted from earlier launch.",
                     "Stored translations must survive reopening without legacy source files")

        // Simulate a kill between the 'importing' receipt and transaction COMMIT.
        // A restart must retry idempotently rather than skipping an incomplete
        // migration because an old receipt exists.
        let interruptedDirectory = root.appendingPathComponent("interrupted-db")
        let interruptedSource = root.appendingPathComponent("interrupted-legacy.json")
        let interruptedKey = "v4|\(rules)|pt>en|0:|Interruption recovery."
        try JSONEncoder().encode(
            MemoryEnvelope(entries: [interruptedKey: "Restored after interruption."]))
            .write(to: interruptedSource, options: .atomic)
        do {
            let initializer = TranslationMemoryStore(directory: interruptedDirectory)
            _ = try await initializer.prepare(legacyURLs: [])
        }
        let sourceBytes = try Data(contentsOf: interruptedSource)
        let fingerprint = SHA256.hash(data: sourceBytes)
            .map { String(format: "%02x", $0) }.joined()
        let interruptionDB = interruptedDirectory.appendingPathComponent("memory.sqlite")
        var interruptionConnection: OpaquePointer?
        precondition(sqlite3_open(interruptionDB.path, &interruptionConnection) == SQLITE_OK)
        let incompleteReceipt = """
            INSERT INTO migration_runs(id,source_fingerprint,source_format,state,started_at)
            VALUES('interrupted-test','\(fingerprint)','envelope_v4','importing',0)
            """
        precondition(sqlite3_exec(interruptionConnection, incompleteReceipt,
                                  nil, nil, nil) == SQLITE_OK)
        sqlite3_close(interruptionConnection)
        let restarted = TranslationMemoryStore(directory: interruptedDirectory)
        let resumedHealth = try await restarted.prepare(legacyURLs: [interruptedSource])
        precondition(resumedHealth.totalEntries == 1 && resumedHealth.migrationStatus == "ready")
        let interruptionHit = await restarted.lookup(
            key: interruptedKey, timeoutMilliseconds: 50)
        precondition(interruptionHit.value == "Restored after interruption.")
        let resumedAgain = try await restarted.prepare(legacyURLs: [interruptedSource])
        precondition(resumedAgain.totalEntries == 1,
                     "Interrupted migrations must be safely retryable and idempotent")

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

        // v1.4.2: an imported legacy entry is NEVER a usable lookup. Only an
        // independently generated, confirmed current-rule translation may cause
        // its historical status to change, in the *same* SQLite transaction.
        let freshLegacyKey = "v4|\(rules)|pt>en|0:|Antigo"
        let unverifiedWrite = try await secondStore.save(
            [freshLegacyKey: "Old"], revision: 1)
        precondition(unverifiedWrite.needsValidation == 1 &&
                     unverifiedWrite.legacyUnverified == 1 &&
                     unverifiedWrite.legacyValidated == 0,
                     "Cached or merely inserted results must not validate older translations")
        let independentlyConfirmed = try await secondStore.save(
            [freshLegacyKey: "Old"], revision: 2,
            independentlyConfirmedKeys: [freshLegacyKey])
        precondition(independentlyConfirmed.totalEntries == 2 &&
                     independentlyConfirmed.readyEntries == 1 &&
                     independentlyConfirmed.needsValidation == 0 &&
                     independentlyConfirmed.legacyValidated == 1 &&
                     independentlyConfirmed.legacyUnverified == 0,
                     "Independent fresh verification retires the exact older validation backlog")
        let historical = try await secondStore.search(query: "Antigo", limit: 10)
        precondition(historical.contains { $0.key == unknownKey &&
            $0.translatedText == "Old" && $0.validationState == "validated_legacy" },
            "Historical entry bytes and provenance must remain intact")
        let stillNotReusable = await secondStore.lookup(key: unknownKey,
            timeoutMilliseconds: 50)
        precondition(stillNotReusable.value == nil,
                     "Even validated historical keys must NEVER be directly reused")
        let currentRuleHit = await secondStore.lookup(key: freshLegacyKey,
            timeoutMilliseconds: 50)
        precondition(currentRuleHit.value == "Old",
                     "Only the current confirmed key is eligible for live reuse")
        let differentText = "v4|\(rules)|pt>en|0:|Outros"
        _ = try await secondStore.save([differentText: "Others"], revision: 3,
            independentlyConfirmedKeys: [differentText])
        let afterUnrelated = try await secondStore.health()
        precondition(afterUnrelated.legacyValidated == 1,
                     "No mass validation for unrelated source text")

        let conflictLegacy = root.appendingPathComponent("conflict-legacy.json")
        let conflictOld = "v2|pt>en|0:|Obrigado"
        let conflictNew = "v4|\(rules)|pt>en|0:|Obrigado"
        try JSONEncoder().encode([conflictOld: "Incorrect older answer"])
            .write(to: conflictLegacy)
        let conflictStore = TranslationMemoryStore(directory:
            root.appendingPathComponent("legacy-supersession"))
        _ = try await conflictStore.prepare(legacyURLs: [conflictLegacy])
        let replaced = try await conflictStore.save(
            [conflictNew: "Thank you"], revision: 1,
            independentlyConfirmedKeys: [conflictNew])
        precondition(replaced.legacySuperseded == 1 &&
                     replaced.legacyValidated == 0 && replaced.needsValidation == 0,
                     "A different independently confirmed answer only supersedes historical evidence")
        let preservedAlternative = try await conflictStore.search(query: "Obrigado", limit: 10)
        precondition(preservedAlternative.contains {
            $0.key == conflictOld && $0.translatedText == "Incorrect older answer" &&
            $0.validationState == "superseded_legacy"
        }, "Never silently overwrite old translations")
        let untrustedOldLookup = await conflictStore.lookup(key: conflictOld,
            timeoutMilliseconds: 50)
        precondition(untrustedOldLookup.value == nil, "Superseded old keys remain excluded")
        let unrelatedContext = "v4|\(rules)|pt>en|1:x|Obrigado"
        _ = try await conflictStore.save(
            [unrelatedContext: "Thanks"], revision: 2,
            independentlyConfirmedKeys: [unrelatedContext])
        let afterOtherContext = try await conflictStore.health()
        precondition(afterOtherContext.legacySuperseded == 1,
                     "Context mismatch must not touch previously classified legacy rows")

        // User-quarantined compatible v4 entries must never be auto-revalidated
        // by the legacy migration path. They remain under explicit review controls.
        let quarantinedV4 = root.appendingPathComponent("quarantined-v4")
        let qStore = TranslationMemoryStore(directory: quarantinedV4)
        _ = try await qStore.prepare(legacyURLs: [])
        _ = try await qStore.save([freshLegacyKey: "First"], revision: 1)
        let qRows = try await qStore.search(query: "Antigo", limit: 5)
        _ = try await qStore.quarantineEntries(ids: qRows.map(\.id))
        _ = try await qStore.save([differentText: "Others"], revision: 2,
            independentlyConfirmedKeys: [differentText])
        let quarantinedHealth = try await qStore.health()
        precondition(quarantinedHealth.needsValidation == 1,
                     "Legacy proof must never bypass a user's quarantine of a v4 key")

        // A punctuation/segment association must not silently validate a
        // historical translation or turn it into an authoritative cache hit.
        let fuzzyPath = root.appendingPathComponent("ocr-variant-legacy.json")
        let oldVariantKey = "v2|pt>en|0:|Olá, meu amigo!"
        let newVariantKey = "v4|\(rules)|pt>en|0:|Olá meu amigo"
        let fragmentOldKey = "v2|pt>en|0:|Onde é que vamos esta noite?"
        let fragmentNewKey = "v4|\(rules)|pt>en|0:|é que vamos esta"
        try JSONEncoder().encode([
            oldVariantKey: "Hello my friend",
            fragmentOldKey: "Where are we going tonight?"
        ]).write(to: fuzzyPath)
        let associationStore = TranslationMemoryStore(
            directory: root.appendingPathComponent("legacy-association-db"))
        _ = try await associationStore.prepare(legacyURLs: [fuzzyPath])
        let assocHealth = try await associationStore.save([
            newVariantKey: "Hello, my friend",
            fragmentNewKey: "Where are we going"
        ], revision: 1, independentlyConfirmedKeys: [newVariantKey, fragmentNewKey])
        precondition(assocHealth.legacyUnverified == 2 &&
                     assocHealth.suggestedOCRMatches == 1 &&
                     assocHealth.suggestedFragmentMatches == 1,
                     "Fuzzy and fragment associations must remain unverified suggestions")
        let oldVariantHit = await associationStore.lookup(key: oldVariantKey,
            timeoutMilliseconds: 50)
        precondition(oldVariantHit.value == nil,
                     "A suggestion alone must never become a legacy cache hit")

        // Explicit idle validation independently retranslates the ORIGINAL
        // source text. It creates a fresh current-key translation and marks
        // the old row historical, without importing the old output as truth.
        guard let idleCandidate = try await associationStore.nextLegacyIdleCandidate(
            target: "en", selectedSource: "pt", after: 0),
              idleCandidate.source == "pt" else {
            preconditionFailure("Eligible idled legacy candidate missing")
        }
        let idleKey = "v4|\(rules)|pt>en|0:|\(idleCandidate.text)"
        let idleHealth = try await associationStore.confirmIdleLegacy(
            id: idleCandidate.id, currentKey: idleKey,
            freshOutput: "Independent freshly translated text", revision: 2)
        precondition(idleHealth.legacyUnverified == 1 &&
                     idleHealth.readyEntries == 3,
                     "Idle validation saves a current-rule result and retains old records")
        let postIdleRows = try await associationStore.search(
            query: idleCandidate.text, limit: 20)
        precondition(postIdleRows.contains {
            $0.id == idleCandidate.id &&
            $0.validationState == "superseded_legacy"
        }, "A valid differing translation preserves old wording for review")
        let oldIdleKey = idleCandidate.text == "Olá, meu amigo!" ?
            oldVariantKey : fragmentOldKey
        let notReadyLegacy = await associationStore.lookup(key: oldIdleKey,
            timeoutMilliseconds: 50)
        precondition(notReadyLegacy.value == nil,
                     "Idle-verified v2 key must remain excluded from automatic lookup")

        // Regression: v1 SQLite databases from the previous installed release
        // must upgrade in place to schema v2 without losing committed memory.
        let upgradeDir = root.appendingPathComponent("memory-v1-upgrade")
        let migratedEntry = "v4|\(rules)|pt>en|0:|Preserved through upgrade"
        do {
            let prior = TranslationMemoryStore(directory: upgradeDir)
            _ = try await prior.prepare(legacyURLs: [])
            _ = try await prior.save([migratedEntry: "Still saved"], revision: 1)
        }
        var downgradeConnection: OpaquePointer?
        let databasePath = upgradeDir.appendingPathComponent("memory.sqlite")
        precondition(sqlite3_open(databasePath.path, &downgradeConnection) == SQLITE_OK)
        precondition(sqlite3_exec(downgradeConnection,
            "DROP TABLE memory_legacy_associations", nil, nil, nil) == SQLITE_OK)
        precondition(sqlite3_exec(downgradeConnection,
            "DROP INDEX memory_legacy_pending", nil, nil, nil) == SQLITE_OK)
        precondition(sqlite3_exec(downgradeConnection,
            "PRAGMA user_version=1", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(downgradeConnection)
        let upgraded = TranslationMemoryStore(directory: upgradeDir)
        let updatedHealth = try await upgraded.prepare(legacyURLs: [])
        precondition(updatedHealth.schemaVersion == 2 && updatedHealth.totalEntries == 1 &&
                     updatedHealth.readyEntries == 1,
                     "Schema migration must preserve historical v1 SQLite data")
        let migratedHit = await upgraded.lookup(key: migratedEntry,
            timeoutMilliseconds: 50)
        precondition(migratedHit.value == "Still saved",
                     "Existing confirmed translation must survive schema migration")

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


        // Only NFC-equivalent source bytes may use the indexed normalized path.
        // Language, context, rule digest and actual whitespace must remain exact.
        let accentOriginal = "Cafe\u{301}?"
        let accentEquivalent = "Café?"
        let canonicalKey = "v4|\(rules)|pt>en|0:|\(accentOriginal)"
        let equivalentKey = "v4|\(rules)|pt>en|0:|\(accentEquivalent)"
        _ = try await store.save([canonicalKey:"Coffee?"], revision: 4)
        let normalizedHit = await store.lookup(key: equivalentKey, timeoutMilliseconds: 50)
        precondition(normalizedHit.value == "Coffee?" && normalizedHit.outcome == "normalized_hit",
                     "Only canonically equivalent Unicode may reuse a translation")
        let wrongRules = "v4|\(String(repeating: "b", count: 64))|pt>en|0:|\(accentEquivalent)"
        let wrongContext = "v4|\(rules)|pt>en|1:x|\(accentEquivalent)"
        let wrongLanguage = "v4|\(rules)|pt>fr|0:|\(accentEquivalent)"
        let wrongRulesHit = await store.lookup(key: wrongRules, timeoutMilliseconds: 50)
        let wrongContextHit = await store.lookup(key: wrongContext, timeoutMilliseconds: 50)
        let wrongLanguageHit = await store.lookup(key: wrongLanguage, timeoutMilliseconds: 50)
        precondition(wrongRulesHit.value == nil && wrongContextHit.value == nil &&
                     wrongLanguageHit.value == nil, "Rules, context and language isolate memory")
        let accentRows = try await store.search(query: "Cafe", limit: 20)
        guard let accentEntry = accentRows.first(where: { $0.translatedText == "Coffee?" })
        else { preconditionFailure("Memory entry missing") }
        let quarantined = try await store.quarantineEntries(ids: [accentEntry.id])
        precondition(quarantined.needsValidation >= 1)
        let excluded = await store.lookup(key: equivalentKey, timeoutMilliseconds: 50)
        precondition(excluded.value == nil, "Quarantined entries must not be reused")
        _ = try await store.save([canonicalKey:"Coffee?"], revision: 5)
        let revalidated = await store.lookup(key: equivalentKey, timeoutMilliseconds: 50)
        precondition(revalidated.value == "Coffee?",
                     "A later confirmed translation may revalidate its same canonical key")

        let snapshotName = try await store.createRecoverySnapshot()
        let snapshotURL = root.appendingPathComponent("db/recovery").appendingPathComponent(snapshotName)
        precondition(FileManager.default.fileExists(atPath: snapshotURL.path),
                     "Snapshot must be created through SQLite, not a WAL-blind file copy")
        let backupHealth = try await store.health()
        precondition(backupHealth.lastVerifiedBackup != nil,
                     "Health must expose a verified recovery snapshot timestamp")
        try await store.clear(revision: 6)
        precondition(FileManager.default.fileExists(atPath: snapshotURL.path),
                     "Clearing active memory must never delete the recovery snapshot")
        do {
            _ = try await store.save([key:"Stale work"], revision: 5)
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
        let indexedMetadata = Data(#"{"stage":"memory","privacy":"metadataOnly"}"#.utf8)
        try await sessionStore.saveDiagnosticSession(id: "test-24",
            startedAt: now, endedAt: now.addingTimeInterval(24),
            payload: Data("replacement-session".utf8),
            events: [(timestamp: now.timeIntervalSince1970, payload: indexedMetadata)])
        let indexedBeforeClear = try await sessionStore.loadDiagnosticEvents(sessionID: "test-24")
        precondition(indexedBeforeClear == [indexedMetadata],
                     "Selected structured events must survive SQLite persistence")
        let oversizedEvents = Array(
            repeating: (timestamp: now.timeIntervalSince1970, payload: indexedMetadata),
            count: 129)
        do {
            try await sessionStore.saveDiagnosticSession(id: "test-24",
                startedAt: now, endedAt: now,
                payload: Data("should-not-commit".utf8), events: oversizedEvents)
            preconditionFailure("More than 128 diagnostic events must fail atomically")
        } catch MemoryStoreError.tooLarge {
            let stillIndexed = try await sessionStore.loadDiagnosticEvents(sessionID: "test-24")
            precondition(stillIndexed == [indexedMetadata])
        }
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
        let deletedEvents = try await sessionStore.loadDiagnosticEvents(sessionID: "test-24")
        precondition(deletedEvents.isEmpty, "Deleted diagnostic sessions must cascade to indexed events")
        print("Diagnostic session retention, size cap and independent deletion checks passed")

        // If the active SQLite database is unreadable, the user can explicitly
        // recover from a verified snapshot. The damaged database/WAL are retained.
        let corruptRecovery = corruptDirectory.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: corruptRecovery,
                                                withIntermediateDirectories: true)
        let invalidSnapshot = corruptRecovery.appendingPathComponent("memory-invalid.sqlite")
        try Data("invalid recovery snapshot".utf8).write(to: invalidSnapshot)
        do {
            _ = try await corruptStore.recoverUnavailableStore(named: "memory-invalid.sqlite")
            preconditionFailure("An unreadable recovery image must be rejected")
        } catch MemoryStoreError.backupFailed {
            let damagedFile = try Data(contentsOf: corruptFile)
            precondition(!damagedFile.isEmpty,
                         "Failed restore must not replace the unreadable original")
        }
        try FileManager.default.copyItem(
            at: snapshotURL, to: corruptRecovery.appendingPathComponent(snapshotName))
        let recoveredFromDamage = try await corruptStore.recoverUnavailableStore(
            named: snapshotName)
        precondition(recoveredFromDamage.totalEntries == 4)
        precondition(recoveredFromDamage.migrationStatus == "restored_from_snapshot")
        let recoveredAfterDamage = await corruptStore.lookup(
            key: sentenceKey, timeoutMilliseconds: 50)
        precondition(recoveredAfterDamage.value == "Como você está?")
        let quarantines = try FileManager.default.contentsOfDirectory(
            atPath: corruptRecovery.path).filter { $0.hasPrefix("unhealthy-") }
        precondition(quarantines.count == 1,
                     "Damaged database copies must be preserved for later investigation")
        let preservedBadDatabase = corruptRecovery
            .appendingPathComponent(quarantines[0])
            .appendingPathComponent("memory.sqlite")
        precondition(FileManager.default.fileExists(atPath: preservedBadDatabase.path))

        // SQLite triggers inject deterministic failures without requiring
        // unavailable disk/OS fault injection on production hardware.
        let failureDirectory = root.appendingPathComponent("revision-rollback-db")
        let failureStore = TranslationMemoryStore(directory: failureDirectory)
        _ = try await failureStore.prepare(legacyURLs: [])
        let failureKey = "v4|\(rules)|pt>en|0:|Important."
        var injection: OpaquePointer?
        let failureDB = failureDirectory.appendingPathComponent("memory.sqlite")
        precondition(sqlite3_open_v2(failureDB.path, &injection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(injection) }
        func runInjection(_ sql: String) {
            precondition(sqlite3_exec(injection, sql, nil, nil, nil) == SQLITE_OK,
                "Test trigger could not be created")
        }
        runInjection("""
            CREATE TRIGGER reject_confirmed_insert BEFORE INSERT ON memory_entries
            BEGIN SELECT RAISE(ABORT,'simulated_write_failure'); END
            """)
        do {
            _ = try await failureStore.save([failureKey: "Verified"], revision: 20)
            preconditionFailure("Injected SQLite write failure must propagate")
        } catch { }
        let rolledBackWrite = try await failureStore.health()
        precondition(rolledBackWrite.totalEntries == 0,
            "Failed transaction must not retain partial memory entries")
        runInjection("DROP TRIGGER reject_confirmed_insert")
        _ = try await failureStore.save([failureKey: "Verified"], revision: 20)
        let acknowledgedWrite = try await failureStore.health()
        precondition(acknowledgedWrite.totalEntries == 1,
            "Same revision must retry after a failed commit")
        runInjection("""
            CREATE TRIGGER reject_memory_clear BEFORE DELETE ON memory_entries
            BEGIN SELECT RAISE(ABORT,'simulated_clear_failure'); END
            """)
        do {
            try await failureStore.clear(revision: 21)
            preconditionFailure("Injected clear failure must propagate")
        } catch { }
        let preservedAfterFailedClear = try await failureStore.health()
        precondition(preservedAfterFailedClear.totalEntries == 1,
            "Failed clear must preserve committed translations")
        runInjection("DROP TRIGGER reject_memory_clear")
        try await failureStore.clear(revision: 21)
        let retriedClear = try await failureStore.health()
        precondition(retriedClear.totalEntries == 0,
            "Failed clear revision must remain retryable")
        print("Transactional write/clear rollback and revision retry checks passed")

        // Importing a formerly ready backup must never silently promote an
        // entry that the user subsequently quarantined for review.
        let reviewStore = TranslationMemoryStore(
            directory: root.appendingPathComponent("review-preservation-db"))
        _ = try await reviewStore.prepare(legacyURLs: [])
        let reviewKey = "v4|\(rules)|pt>en|0:|Needs review."
        _ = try await reviewStore.save([reviewKey: "Review me"], revision: 1)
        let reviewBackup = try await reviewStore.exportData()
        let reviewSnapshot = try await reviewStore.createRecoverySnapshot()
        let reviewEntries = try await reviewStore.search(query: "Needs review.", limit: 5)
        precondition(reviewEntries.count == 1)
        _ = try await reviewStore.quarantineEntries(ids: [reviewEntries[0].id])
        _ = try await reviewStore.importData(reviewBackup)
        let afterImport = await reviewStore.lookup(key: reviewKey, timeoutMilliseconds: 50)
        precondition(afterImport.value == nil, "Backup import may not undo explicit quarantine")
        _ = try await reviewStore.mergeRecoverySnapshot(named: reviewSnapshot)
        let afterRecovery = await reviewStore.lookup(key: reviewKey, timeoutMilliseconds: 50)
        precondition(afterRecovery.value == nil,
            "Recovery snapshot may not silently revalidate quarantined translations")
        print("Imported-backup quarantine and recovery compatibility checks passed")

        let reopened = TranslationMemoryStore(directory: root.appendingPathComponent("db"))
        let cleared = try await reopened.prepare(legacyURLs: [legacy])
        precondition(cleared.totalEntries == 0, "Clear must not reimport legacy memory")
        precondition(cleared.migrationStatus == "cleared",
                     "An intentional clear must not be mistaken for an unmigrated installation")
        precondition(FileManager.default.fileExists(atPath: legacy.path))
        // Restore is additive and explicit. A previous Clear cannot be undone by
        // legacy migration, but a user-selected verified snapshot can be merged.
        let availableSnapshots = try await reopened.recoverySnapshots()
        precondition(availableSnapshots.contains(snapshotName))
        let recoveredHealth = try await reopened.mergeRecoverySnapshot(named: snapshotName)
        precondition(recoveredHealth.totalEntries == 4)
        let recoveredConflict = await reopened.lookup(key: key, timeoutMilliseconds: 50)
        precondition(recoveredConflict.value == nil, "Recovered conflicting translations must stay blocked")
        let recoveredSentence = await reopened.lookup(key: sentenceKey, timeoutMilliseconds: 50)
        precondition(recoveredSentence.value == "Como você está?")
        precondition(recoveredSentence.origin == "persistent",
                     "Recovered provenance must not inflate legacy lookup hits")
        let repeatRecovery = try await reopened.mergeRecoverySnapshot(named: snapshotName)
        precondition(repeatRecovery.totalEntries == 4, "Snapshot re-merge must be idempotent")
        do {
            _ = try await reopened.mergeRecoverySnapshot(named: "../memory.sqlite")
            preconditionFailure("Recovery filenames must reject path traversal")
        } catch MemoryStoreError.sourceUnreadable { }
        try await reopened.clear(revision: 9)

        try await reopened.deletePreservedCopies(legacyURLs: [legacy, oldJSON])
        precondition(!FileManager.default.fileExists(atPath: legacy.path))
        precondition(!FileManager.default.fileExists(atPath: snapshotURL.path))
        let purgedHealth = try await reopened.health()
        precondition(purgedHealth.lastVerifiedBackup == nil,
                     "Explicit purge must clear the recovery-backup indicator")
        print("SQLite migration, recovery, integrity checks, classification, revision barrier and clear/reopen passed")
    }
}
