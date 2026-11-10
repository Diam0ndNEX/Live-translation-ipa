import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    // MARK: Translation memory (kept between launches)
    private var memoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenLingo", isDirectory: true).appendingPathComponent("translation-memory-v4.json")
    }

    func loadMemory() {
        diag.memoryStore = memoryStore
        // 2.2.1 (D10): the store reports each lookup's queue wait; it is recorded here so the lookup call sites stay untouched.
        memoryStore.measurement.install { [weak self] ms in
            Task { @MainActor in self?.diag.noteMemoryLookupWait(ms) }
        }
        let legacy = [memoryURL, FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("translation-memory.json")]
        Task { [weak self] in
            guard let self else { return }
            do {
                let health = try await self.memoryStore.prepare(legacyURLs: legacy)
                self.memoryReady = true
                self.applyMemoryHealth(health)
                self.saveMemory(force: true)
                await self.diag.migrateOldSessions()
            } catch {
                self.memoryFailure = "Memory unavailable; fresh translation remains available"
                self.diag.log("Memory initialization failed; preserved data requires recovery")
            }
        }
    }

    func touchCache(_ key: String) {
        if temporaryMemoryEntries != processMemory.temporary.values.count {
            temporaryMemoryEntries = processMemory.temporary.values.count
        }
        ram.clock &+= 1
        ram.use[key] = ram.clock
    }

    func queueMemory(_ key: String, _ value: String, independentlyConfirmed: Bool = false, knownDefault: Bool = false) {
        guard allowsPersistentTranslations, flag("remember", true), !flag("privateSession", false),
              !flag("freshTranslationTest", false) else { return }
        // Bound pending writes without claiming unsaved entries are durable.
        guard pendingMemory[key] != nil || pendingMemory.count < 3000 else {
            memoryFailure = "Memory write queue full; new entries remain session-only"
            return
        }
        pendingMemory[key] = value
        if independentlyConfirmed || knownDefault || ram.specKeys.contains(key) { pendingDefaultStrategy[key] = value }
        if independentlyConfirmed { pendingLegacyProof[key] = value }
        else if pendingLegacyProof[key] != value { pendingLegacyProof[key] = nil }
        memoryPendingWrites = pendingMemory.count
        memoryDirty = true
        if memoryCoalescingTask == nil {
            memoryCoalescingTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 75_000_000)
                guard !Task.isCancelled, let self else { return }
                self.memoryCoalescingTask = nil
                self.saveMemory()
            }
        }
    }

    func saveMemory(force: Bool = false) {
        if force { memoryCoalescingTask?.cancel(); memoryCoalescingTask = nil }
        guard memoryReady, !memorySaving, !memoryMutationInProgress, !pendingMemory.isEmpty,
              force || Date() >= storageFullRetryNotBefore else { return }
        memorySaving = true
        let snapshot = pendingMemory
        let freshKeys = Set(snapshot.compactMap { key, value in
            pendingLegacyProof[key] == value ? key : nil
        })
        memoryRevision += 1
        let revision = memoryRevision
        let diagnosticEpoch = diag.started
        Task { [weak self] in
            guard let self else { return }
            let writeStart = ProcessInfo.processInfo.systemUptime
            var committed = false
            var storageFull = false
            var committedHealth: MemoryStoreHealth?
            do {
                committedHealth = try await self.memoryStore.save(snapshot,
                    revision: revision, independentlyConfirmedKeys: freshKeys,
                    knownDefaultStrategyKeys: Set(snapshot.keys.filter { self.pendingDefaultStrategy[$0] == snapshot[$0] }))
                committed = true
                if self.memoryRevision == revision {
                    for (key, value) in snapshot where self.pendingMemory[key] == value {
                        self.pendingMemory[key] = nil
                        if self.pendingDefaultStrategy[key] == value { self.pendingDefaultStrategy[key] = nil }
                        if self.pendingLegacyProof[key] == value {
                            self.pendingLegacyProof[key] = nil
                        }
                    }
                }
                self.memoryFailure = nil
                if self.diag.started == diagnosticEpoch {
                    self.diag.recordMemory(.persisted, durationMs: (ProcessInfo.processInfo.systemUptime - writeStart) * 1000)
                }
            } catch MemoryStoreError.storageFull {
                storageFull = true
                // Avoid retry storms on every changed subtitle when storage is full.
                // Confirmed results remain pending for the next explicit/periodic retry.
                self.storageFullRetryNotBefore = Date().addingTimeInterval(30)
                self.memoryFailure = "Device storage full; remembered translations are pending, not saved"
                if self.diag.started == diagnosticEpoch {
                    self.diag.recordMemory(.writeFailed,
                        durationMs: (ProcessInfo.processInfo.systemUptime - writeStart) * 1000)
                }
            } catch {
                self.memoryFailure = "Memory write failed; pending entries will retry"
                if self.diag.started == diagnosticEpoch {
                    self.diag.recordMemory(.writeFailed,
                        durationMs: (ProcessInfo.processInfo.systemUptime - writeStart) * 1000)
                }
            }
            self.memorySaving = false
            self.memoryPendingWrites = self.pendingMemory.count
            self.memoryDirty = !self.pendingMemory.isEmpty
            if committed {
                self.memoryRetryAttempts = 0
                self.storageFullRetryNotBefore = .distantPast
            }
            if let committedHealth { self.applyMemoryHealth(committedHealth) }
            else { await self.refreshMemoryHealth() }
            guard !self.pendingMemory.isEmpty else { return }
            if committed {
                // Confirmations queued during the previous commit must not get stranded.
                self.saveMemory(force: true)
            } else if !storageFull && self.memoryRetryAttempts < 3 {
                self.memoryRetryAttempts += 1
                let delay: UInt64 = [2, 5, 15][self.memoryRetryAttempts - 1] * 1_000_000_000
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: delay)
                    self?.saveMemory(force: true)
                }
            }
        }
    }

    /// Best-effort bounded persistence for iOS suspension. Returning false means
    /// confirmed entries remain visibly pending; it is never a durability claim.
    func flushPendingMemory(maxWaitSeconds: Double = 2.5) async -> Bool {
        guard memoryReady else { return pendingMemory.isEmpty && !memorySaving }
        let seconds = min(5.0, max(0.1, maxWaitSeconds))
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var retries = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            if pendingMemory.isEmpty && !memorySaving { return true }
            if !memorySaving && !memoryMutationInProgress && retries < 2 {
                retries += 1
                saveMemory(force: true)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        memoryPendingWrites = pendingMemory.count
        if !pendingMemory.isEmpty {
            memoryFailure = "Confirmed translations remain pending after background flush"
        }
        return pendingMemory.isEmpty && !memorySaving
    }

    func refreshMemoryHealth() async {
        do { applyMemoryHealth(try await memoryStore.health()) }
        catch { memoryFailure = "Memory health unavailable" }
    }

    /// Reuse the health snapshot already returned after COMMIT. A second full
    /// health query would occupy the same SQLite actor that serves live lookups.
    func applyMemoryHealth(_ health: MemoryStoreHealth) {
        diag.noteMemoryHealth(health.lastHealthMs)
        memoryHealth = health
        memoryCount = health.totalEntries
        var diagnosticHealth = diag.memoryHealth
        diagnosticHealth.totalEntries = health.totalEntries
        diagnosticHealth.readyEntries = health.readyEntries
        diagnosticHealth.needsValidation = health.needsValidation
        diagnosticHealth.legacyValidated = health.legacyValidated
        diagnosticHealth.legacySuperseded = health.legacySuperseded
        diagnosticHealth.legacyUnverified = health.legacyUnverified
        diagnosticHealth.suggestedOCRMatches = health.suggestedOCRMatches
        diagnosticHealth.suggestedFragmentMatches = health.suggestedFragmentMatches
        diagnosticHealth.conflicts = health.conflicts
        diagnosticHealth.databaseBytes = health.databaseBytes
        diagnosticHealth.migrationStatus = health.migrationStatus
        diagnosticHealth.integrity = health.integrity
        diagnosticHealth.failedWrites = health.failedWrites
        diagnosticHealth.pendingWrites = memoryPendingWrites
        diagnosticHealth.ramEntries = ram.values.count
        diagnosticHealth.categoryCounts = health.categoryCounts
        diag.memoryHealth = diagnosticHealth
    }

    func removeMemoryEntries(ids: [Int64]) async throws {
        guard memoryReady, !memorySaving, !memoryMutationInProgress, pendingMemory.isEmpty
        else { throw MemoryStoreError.unavailable }
        memoryMutationInProgress = true
        defer {
            memoryMutationInProgress = false
            saveMemory(force: true)
        }
        clearRAMCache()
        try await memoryStore.delete(ids: ids)
        await refreshMemoryHealth()
    }


    /// Storage imports and review operations are serialized against engine writes.
    /// New confirmations arriving while a maintenance operation awaits the store
    /// remain in pendingMemory and are flushed after its commit.
    func importMemoryData(_ data: Data) async throws {
        guard memoryReady, !memorySaving, !memoryMutationInProgress, pendingMemory.isEmpty
        else { throw MemoryStoreError.unavailable }
        memoryMutationInProgress = true
        defer {
            memoryMutationInProgress = false
            saveMemory(force: true)
        }
        let health = try await memoryStore.importData(data)
        clearRAMCache()
        applyMemoryHealth(health)
    }

    func quarantineMemoryEntries(ids: [Int64]) async throws {
        guard memoryReady, !memorySaving, !memoryMutationInProgress, pendingMemory.isEmpty
        else { throw MemoryStoreError.unavailable }
        memoryMutationInProgress = true
        defer {
            memoryMutationInProgress = false
            saveMemory(force: true)
        }
        let health = try await memoryStore.quarantineEntries(ids: ids)
        clearRAMCache()
        applyMemoryHealth(health)
    }

    func mergeMemoryRecoverySnapshot(named name: String) async throws {
        guard memoryReady, !memorySaving, !memoryMutationInProgress, pendingMemory.isEmpty
        else { throw MemoryStoreError.unavailable }
        memoryMutationInProgress = true
        defer {
            memoryMutationInProgress = false
            saveMemory(force: true)
        }
        let health = try await memoryStore.mergeRecoverySnapshot(named: name)
        clearRAMCache()
        applyMemoryHealth(health)
    }

    /// The management UI must not report deletion until the SQLite transaction commits.
    /// Existing callers can still invoke the fire-and-forget compatibility entry point.
    func clearMemory() {
        Task { _ = await clearMemoryConfirmed() }
    }

    @discardableResult
    func clearMemoryConfirmed() async -> Bool {
        // Enforce a barrier across the suspension: new confirmed translations
        // remain pending and cannot be written until the clear completes.
        guard memoryReady, !memoryMutationInProgress, !memorySaving, pendingMemory.isEmpty else {
            memoryFailure = "Wait for pending memory writes before deleting"
            return false
        }
        memoryMutationInProgress = true
        clearRAMCache()
        memoryRevision += 1
        let revision = memoryRevision
        defer {
            memoryMutationInProgress = false
            // Any new confirmations queued while SQLite was busy are still owed a write.
            saveMemory(force: true)
        }
        do {
            try await memoryStore.clear(revision: revision)
            clearRAMCache()
            await refreshMemoryHealth()
            memoryFailure = nil
            toast("Translation memory cleared")
            return true
        } catch {
            memoryFailure = "Memory could not be cleared; saved data was preserved"
            return false
        }
    }

    /// Only call after clearMemoryConfirmed() succeeded and the user explicitly
    /// requested erasure of recoverable memory originals and snapshots.
    func purgePreservedMemoryCopies() async throws {
        let legacy = [memoryURL,
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("translation-memory.json")]
        try await memoryStore.deletePreservedCopies(legacyURLs: legacy)
        await refreshMemoryHealth()
    }

    /// Explicit maintenance route when SQLite initialization failed. A failed
    /// recovery leaves pending confirmations intact and fresh translation active.
    func restoreUnavailableMemoryFromSnapshot(named name: String) async throws {
        guard !memoryReady, !memorySaving, !memoryMutationInProgress else {
            throw MemoryStoreError.unavailable
        }
        memoryMutationInProgress = true
        defer {
            memoryMutationInProgress = false
            if memoryReady { saveMemory(force: true) }
        }
        let health = try await memoryStore.recoverUnavailableStore(named: name)
        memoryReady = true
        clearRAMCache()
        applyMemoryHealth(health)
        memoryFailure = nil
        diag.log("Unavailable memory database restored from verified snapshot; damaged originals retained")
    }

    /// Called from the live app on an iOS memory warning. Persistent SQLite entries
    /// remain untouched; only evictable RAM entries are reduced.
    func handleMemoryPressure() {
        if activeTranslationSystem != .legacy { modeCoordinator.reduceSpeculation(memoryPressure: true) }
        let configured = max(250, min(6000, int("memoryRAMCapacity", 3000)))
        memoryPressureCapacity = max(250, configured / 4)
        trimCache()
    }

    func trimCache() {
        let configured = max(250, min(6000, int("memoryRAMCapacity", 3000)))
        let limit = min(configured, memoryPressureCapacity ?? configured)
        let excess = ram.values.count - limit
        guard excess > 0 else { return }
        // The common case is one insertion beyond capacity. Finding the oldest
        // key with a linear scan avoids sorting the entire cache on every frame.
        let victims: [String]
        if excess == 1 {
            victims = ram.use.min(by: { $0.value < $1.value }).map { [$0.key] } ??
                      Array(ram.values.keys.prefix(1))
        } else {
            victims = ram.use.sorted(by: { $0.value < $1.value }).prefix(excess).map(\.key)
        }
        for key in victims {
            ram.values[key] = nil; ram.use[key] = nil
            if ram.specKeys.remove(key) != nil { diag.noteSpeculativeUnit("evictedUnused") }; ram.speculativeOrigins.removeValue(forKey: key); ram.savedKeys.remove(key); ram.confirmedKeys.remove(key)
        }
        // Report entries evicted, not maintenance batches; persistence is untouched.
        if temporaryMemoryEntries != processMemory.temporary.values.count {
            temporaryMemoryEntries = processMemory.temporary.values.count
        }
        diag.recordMemory(.ramEviction, count: victims.count)
    }
}
