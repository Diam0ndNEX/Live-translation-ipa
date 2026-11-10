import CryptoKit
import SwiftUI
import Charts
import os
import Darwin

extension Diagnostics {
    // MARK: Test Runs (v2.0.0 build 84, spec §11)

    /// "automatic" (default) | "manual" | "off". Replaces persistDiagnosticSessions.
    var runSavingMode: String {
        let value = UserDefaults.standard.string(forKey: "testRunSaving") ?? "automatic"
        return ["automatic", "manual", "off"].contains(value) ? value : "automatic"
    }
    private var privateSessionOn: Bool { UserDefaults.standard.bool(forKey: "privateSession") }

    var currentTestID: UUID {
        if let text = UserDefaults.standard.string(forKey: "testRunCurrentID"), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: "testRunCurrentID")
        return id
    }
    var currentTestName: String {
        if let name = UserDefaults.standard.string(forKey: "testRunCurrentName"), !name.isEmpty { return name }
        return nextTestName()
    }
    private func nextTestName() -> String {
        let existing = Set(testRuns.filter { $0.appVersion.contains(AppVersion.version) }.map(\.testID)).count
        return "\(AppVersion.version) test \(existing + 1)"
    }
    func startNewTest(named name: String? = nil) {
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: "testRunCurrentID")
        let clean = TestRunMeta.cleanLabel(name ?? "")
        UserDefaults.standard.set(clean.isEmpty ? nextTestName() : clean, forKey: "testRunCurrentName")
        objectWillChange.send()
    }
    func renameCurrentTest(_ name: String) {
        let clean = TestRunMeta.cleanLabel(name)
        guard !clean.isEmpty else { return }
        UserDefaults.standard.set(clean, forKey: "testRunCurrentName")
        let id = currentTestID
        Task { await runStore.renameTest(testID: id, name: clean); await refreshRuns() }
    }

    /// Why a run would not be saved right now, or nil. Fixed reason codes plus a human detail.
    func skipReason(for meta: TestRunMeta) -> (TestRunSkipReason, String)? {
        TestRunPolicy.skipReason(meta: meta, privateSession: privateSessionOn, savingMode: runSavingMode,
                                 diagnosticsEnabled: enabled)
    }

    /// Save run: the current run (as a checkpoint, the run continues) or the last ended run that was not saved.
    @discardableResult
    func saveRunNow() async -> TestRunSaveResult {
        let result: TestRunSaveResult
        let mode: String, seconds: Double
        if let run = activeRun {
            let snapshot = sessionSnapshot()
            var changes = run.modeChanges
            if modeActiveSystem != run.mode { changes.append(modeActiveSystem) }
            let meta = TestRunMeta.make(snapshot: snapshot, testID: currentTestID, testName: currentTestName,
                endReason: "savedWhileRecording", startingRAMEntries: startingRAMEntries, modeChanges: changes, completeness: "complete", pausedSeconds: pausedSeconds)
            mode = meta.mode; seconds = meta.durationSeconds
            if let (code, detail) = skipReason(for: meta) { result = .skipped(code, detail: detail) }
            else { result = await runStore.save(meta: meta, snapshot: snapshot) }
        } else if let pending = unsavedEndedRun {
            mode = pending.meta.mode; seconds = pending.meta.durationSeconds
            if privateSessionOn { result = .skipped(.privateSession, detail: "Private session – runs are not saved") }
            else if runSavingMode == "off" { result = .skipped(.savingOff, detail: "Saving test runs is off") }
            else {
                result = await runStore.save(meta: pending.meta, snapshot: pending.snapshot)
                if case .saved = result { unsavedEndedRun = nil }
            }
        } else {
            mode = modeActiveSystem; seconds = 0
            result = .skipped(.noData, detail: "No run to save")
        }
        lastRunBanner = RunBanner(result: result, mode: mode, seconds: seconds)
        await refreshRuns()
        return result
    }

    /// Crash-safety checkpoint. Only the snapshot copy runs on the main actor (its cost is recorded);
    /// redaction, encoding, compression and the write run on the store actor.
    func checkpointRun() {
        guard let run = activeRun, pausedAt == nil, !checkpointInFlight, runSavingMode != "off", !privateSessionOn, enabled else { return }
        let begin = ProcessInfo.processInfo.systemUptime
        let snapshot = sessionSnapshot()
        let spent = ProcessInfo.processInfo.systemUptime - begin
        lastCheckpointCaptureMs = spent * 1000
        checkpointCaptureMicros = Int(spent * 1_000_000)
        var changes = run.modeChanges
        if modeActiveSystem != run.mode { changes.append(modeActiveSystem) }
        let meta = TestRunMeta.make(snapshot: snapshot, testID: currentTestID, testName: currentTestName,
            endReason: "recovered", startingRAMEntries: startingRAMEntries, modeChanges: changes, completeness: "recovered", pausedSeconds: pausedSeconds)
        activeRun?.lastCheckpointAt = Date()
        checkpointInFlight = true
        let store = runStore
        Task { _ = await store.checkpoint(meta: meta, snapshot: snapshot); checkpointInFlight = false }
    }

    func refreshRuns() async {
        let index = await runStore.index()
        testRuns = index.runs.sorted { $0.endedAt > $1.endedAt }
        runPruneNote = index.pruneNote
    }

    /// Launch: leftover checkpoints become runs marked "Recovered (incomplete)".
    func recoverRuns() async {
        let recovered = await runStore.recover()
        await refreshRuns()
        if let last = recovered.last {
            lastRunBanner = RunBanner(result: .saved(last), mode: last.mode, seconds: last.durationSeconds)
        }
    }

    /// Build 84, once: rows of the old diagnostic_sessions table become runs marked
    /// "Imported (mode may be mixed)". The table and its rows are left in place and never written again.
    func migrateOldSessions() async {
        guard let store = memoryStore else { return }
        if await runStore.migrationDone { return }
        do {
            let payloads = try await store.loadDiagnosticSessions()
            let imported = await runStore.migrate(payloads: payloads)
            if imported > 0 { archiveStatus = "Imported \(imported) earlier diagnostic session(s) as test runs" }
            await refreshRuns()
        } catch { /* marker stays unset; retried at the next launch */ }
    }

    func deleteRuns(_ ids: [UUID]) async { await runStore.delete(ids: ids); await refreshRuns() }
    func deleteAllUnpinnedRuns() async { _ = await runStore.deleteAllUnpinned(); await refreshRuns() }
    func setRunPinned(_ id: UUID, _ pinned: Bool) async { await runStore.setPinned(id: id, pinned); await refreshRuns() }
    func renameRun(_ id: UUID, label: String) async { await runStore.rename(id: id, label: label); await refreshRuns() }
    func moveRun(_ id: UUID, toTest testID: UUID, name: String) async { await runStore.move(id: id, toTest: testID, name: name); await refreshRuns() }
    func clearRunPruneNote() async { await runStore.clearPruneNote(); await refreshRuns() }

    /// One Markdown file for up to six saved runs.
    func exportTestReport(ids: [UUID]) async {
        guard !exportInProgress else { return }
        let ordered = Array(ids.prefix(CombinedDiagnosticReport.maximumSessions))
        let snapshots = await runStore.loadSnapshots(ids: ordered)
        guard !snapshots.isEmpty else { archiveStatus = "Select at least one saved run"; return }
        exportInProgress = true
        defer { exportInProgress = false }
        do {
            let url = try await exportWriter.exportCombinedReport(snapshots,
                version: AppVersion.version, build: AppVersion.build,
                runs: testRuns.filter { ordered.contains($0.id) }.map(\.reportInfo))
            Sharer.present([url])
            archiveStatus = "Test report ready"
        } catch {
            archiveStatus = "Test report export failed; no file was shared"
        }
    }

    var names: [String] {
        guard enabled, !UserDefaults.standard.bool(forKey: "privateSession"),
              (UserDefaults.standard.object(forKey: "showSessionSpeakers") as? Bool) ?? true else { return [] }
        return speakerSession.names
    }
    var enabled: Bool { (UserDefaults.standard.object(forKey: "diagnosticsEnabled") as? Bool) ?? true }
    var detailedCollection: Bool {
        guard ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return false }
        return RuntimePolicy(coolMode: false, diagnosticsEnabled: enabled,
                      detailedRequested: UserDefaults.standard.bool(forKey: "detailedCollection")).detailedDiagnostics
    }

    func collectionChanged() {
        // A new collection interval must never be mistaken for continuous history.
        let costs = recorderCosts
        reset()
        recorderCosts = costs
        UIDevice.current.isBatteryMonitoringEnabled = detailedCollection
    }

    func clearSpeakers() { speakerSession = SpeakerSession() }
    func add(_ kp: ReferenceWritableKeyPath<Diagnostics, [Sample]>, _ v: Double, cap: Int = 600) {
        guard detailedCollection else { return }
        self[keyPath: kp].append(Sample(t: Date(), v: v))
        let limit = max(300, min(1200, (UserDefaults.standard.object(forKey: "diagSamples") as? Int) ?? 600))
        let extra = self[keyPath: kp].count - limit
        if extra > 0 { self[keyPath: kp].removeFirst(extra) }
    }
}
