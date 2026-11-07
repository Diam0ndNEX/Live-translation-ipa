import Foundation

// Test Runs storage (v2.0.0 build 84, spec §11.3–§11.4).
// Standalone on purpose: depends only on Foundation and DiagnosticArchive.swift so that
// Tests/TestRuns can compile it with swiftc exactly like Tests/DiagnosticArchive.
// Runs live in Application Support/TestRuns, never in the translation-memory database.

enum TestRunSkipReason: String, Codable, Equatable {
    case privateSession, savingOff, tooShort, noData
}
enum TestRunFailReason: String, Codable, Equatable {
    case diskFull, encodeFailed, writeFailed
}
/// Pure save policy (spec §11.3) so it can be tested without the UI layer.
enum TestRunPolicy {
    static func skipReason(meta: TestRunMeta, privateSession: Bool, savingMode: String,
                           diagnosticsEnabled: Bool) -> (TestRunSkipReason, String)? {
        if privateSession { return (.privateSession, "Private session – runs are not saved") }
        if savingMode == "off" { return (.savingOff, "Saving test runs is off") }
        if !diagnosticsEnabled { return (.noData, "Diagnostics collection is off") }
        if meta.durationSeconds < TestRunMeta.minimumSeconds {
            return (.tooShort, "Run too short to save – \(Int(meta.durationSeconds)) s")
        }
        if meta.captions == 0 { return (.noData, "Run has no captions to save") }
        return nil
    }
}
enum TestRunSaveResult: Equatable {
    case saved(TestRunMeta)
    case skipped(TestRunSkipReason, detail: String)
    case failed(TestRunFailReason)
}

/// Run metadata only (no OCR text, no filenames). The list screen reads only this.
struct TestRunMeta: Codable, Identifiable, Equatable {
    var id: UUID
    var testID: UUID
    var testName: String
    var mode: String
    var startedAt: Date
    var endedAt: Date
    var durationSeconds: Double
    var endReason: String
    var appVersion: String
    var systemVersion: String
    var hardwareModel: String
    var languagePair: String
    var label: String
    var pinned: Bool
    /// complete | recovered | trimmed | imported
    var completeness: String
    var trimmed: [String]
    var captions: Int
    var enqueueP50Ms: Double?
    var enqueueP95Ms: Double?
    var thermal: String
    var startingRAMEntries: Int
    /// Modes seen during the run other than the starting one. Should always be empty.
    var modeChanges: [String]
    var bytes: Int

    var reportInfo: RunReportInfo {
        RunReportInfo(id: id, testName: testName, label: label, endReason: endReason,
                      completeness: completeness, trimmed: trimmed, mixedMode: mixedMode)
    }
    var mixedMode: Bool { !modeChanges.isEmpty || completeness == "imported" }

    static let minimumSeconds = 30.0
    static let maximumLabelLength = 40
    static func cleanLabel(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(Character.init).prefix(maximumLabelLength)).trimmingCharacters(in: .whitespaces)
    }

    /// Builds metadata from a snapshot. `startingRAM` and `modeChanges` come from the run, not the snapshot.
    static func make(snapshot: DiagnosticSessionExport, testID: UUID, testName: String, endReason: String,
                     startingRAMEntries: Int, modeChanges: [String], completeness: String,
                     label: String = "", pinned: Bool = false) -> TestRunMeta {
        let mode = snapshot.translationModes?.active ?? "unknown"
        let first = snapshot.translationModes?.events.first
        let pair = first.map { "\($0.source)>\($0.target)" } ?? "?"
        let latency = snapshot.distributions["enqueueLatencyMs"]
        let captions = max(snapshot.counters["enqueuedCandidateFrames"] ?? 0, latency?.count ?? 0)
        return TestRunMeta(id: snapshot.id, testID: testID, testName: testName, mode: mode,
            startedAt: snapshot.startedAt, endedAt: snapshot.endedAt,
            durationSeconds: max(0, snapshot.endedAt.timeIntervalSince(snapshot.startedAt)),
            endReason: endReason, appVersion: snapshot.appVersion, systemVersion: snapshot.systemVersion,
            hardwareModel: snapshot.hardwareModel ?? "?", languagePair: pair, label: cleanLabel(label),
            pinned: pinned, completeness: completeness, trimmed: [], captions: captions,
            enqueueP50Ms: latency?.p50, enqueueP95Ms: latency?.p95,
            thermal: snapshot.settings["thermalState"] ?? "?",
            startingRAMEntries: startingRAMEntries, modeChanges: modeChanges, bytes: 0)
    }
}

struct TestRunIndex: Codable {
    var runs: [TestRunMeta] = []
    /// Shown in the list footer after automatic pruning, e.g. "2 older runs removed to stay under 100 MB".
    var pruneNote: String? = nil
}

private struct StoredTestRun: Codable {
    var meta: TestRunMeta
    var snapshot: DiagnosticSessionExport
}

actor TestRunStore {
    static let keepUnpinned = 40
    static let importedMarker = "migrated-diagnostic-sessions-v1"

    private let directory: URL
    private let maximumRunBytes: Int
    private let maximumTotalBytes: Int
    private let writer = DiagnosticExportWriter()
    private var cache: TestRunIndex?
    /// Test hook: pretend the volume is full.
    private var simulateDiskFull = false

    /// The limits are parameters only so tests can exercise trimming and size pruning with small data.
    init(directory: URL, maximumRunBytes: Int = 8 * 1024 * 1024, maximumTotalBytes: Int = 100 * 1024 * 1024) {
        self.directory = directory
        self.maximumRunBytes = maximumRunBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TestRuns", isDirectory: true)
    }

    func directoryPath() -> String { directory.path }
    func setSimulatedDiskFull(_ value: Bool) { simulateDiskFull = value }

    // MARK: files

    private func runURL(_ id: UUID) -> URL { directory.appendingPathComponent("run-\(id.uuidString).json.lzfse") }
    private func partialURL(_ id: UUID) -> URL { directory.appendingPathComponent("run-\(id.uuidString).partial") }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func prepareDirectory() throws {
        var url = directory
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        if simulateDiskFull { throw CocoaError(.fileWriteOutOfSpace) }
        try prepareDirectory()
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    private func pack(_ stored: StoredTestRun) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(stored)
        return try (json as NSData).compressed(using: .lzfse) as Data
    }
    private func unpack(_ data: Data) throws -> StoredTestRun {
        let json = try (data as NSData).decompressed(using: .lzfse) as Data
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoredTestRun.self, from: json)
    }

    // MARK: index

    func index() -> TestRunIndex {
        if let cache { return cache }
        var loaded = TestRunIndex()
        if let data = try? Data(contentsOf: indexURL) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if let value = try? decoder.decode(TestRunIndex.self, from: data) { loaded = value }
        }
        // Drop entries whose file vanished; adopt nothing implicitly.
        loaded.runs.removeAll { !FileManager.default.fileExists(atPath: runURL($0.id).path) }
        cache = loaded
        return loaded
    }

    private func saveIndex(_ value: TestRunIndex) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try write(try encoder.encode(value), to: indexURL)
        cache = value
    }

    func totalBytes() -> Int { index().runs.reduce(0) { $0 + $1.bytes } }

    // MARK: save

    /// Trims in the documented order until the compressed run fits. Never rejects for size.
    static func trim(_ snapshot: DiagnosticSessionExport, step: Int) -> (DiagnosticSessionExport, String)? {
        var value = snapshot
        switch step {
        case 0:
            guard value.oneSecondIntervals?.isEmpty == false else { return nil }
            value.oneSecondIntervals = nil
            return (value, "oneSecondBuckets")
        case 1:
            guard value.events.count > 200 else { return nil }
            value.events = Array(value.events.suffix(value.events.count / 2))
            return (value, "oldestStructuredEvents")
        case 2:
            guard var modes = value.translationModes, modes.events.count > 200 else { return nil }
            modes.events = Array(modes.events.suffix(modes.events.count / 2))
            value.translationModes = modes
            return (value, "oldestModeTrace")
        default:
            return nil
        }
    }

    /// `snapshot` may be raw; it is redacted here with the same allowlists as exports.
    func save(meta input: TestRunMeta, snapshot raw: DiagnosticSessionExport) async -> TestRunSaveResult {
        var meta = input
        var snapshot = await writer.redactedForStorage(raw)
        var packed: Data
        do {
            packed = try pack(StoredTestRun(meta: meta, snapshot: snapshot))
            var step = 0
            var attempts = 0
            while packed.count > maximumRunBytes && attempts < 40 {
                attempts += 1
                if let (smaller, what) = Self.trim(snapshot, step: step) {
                    snapshot = smaller
                    if !meta.trimmed.contains(what) { meta.trimmed.append(what) }
                    packed = try pack(StoredTestRun(meta: meta, snapshot: snapshot))
                } else { step += 1; if step > 2 { break } }
            }
        } catch { return .failed(.encodeFailed) }
        if !meta.trimmed.isEmpty, meta.completeness == "complete" { meta.completeness = "trimmed" }
        meta.bytes = packed.count
        do {
            // Re-pack so the stored meta (trimmed list, completeness, bytes) matches the index.
            packed = try pack(StoredTestRun(meta: meta, snapshot: snapshot))
            meta.bytes = packed.count
            try write(packed, to: runURL(meta.id))
            var current = index()
            current.runs.removeAll { $0.id == meta.id }
            current.runs.append(meta)
            try? FileManager.default.removeItem(at: partialURL(meta.id))
            current = pruned(current)
            try saveIndex(current)
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            return .failed(.diskFull)
        } catch { return .failed(.writeFailed) }
        return .saved(meta)
    }

    // MARK: checkpoints and recovery

    /// Crash safety: the latest checkpoint of a running run. Overwrites the previous one.
    func checkpoint(meta: TestRunMeta, snapshot raw: DiagnosticSessionExport) async -> Bool {
        let snapshot = await writer.redactedForStorage(raw)
        do {
            var small = meta; small.completeness = "recovered"; small.endReason = "recovered"
            let packed = try pack(StoredTestRun(meta: small, snapshot: snapshot))
            guard packed.count <= maximumRunBytes else { return false }
            try write(packed, to: partialURL(meta.id))
            return true
        } catch { return false }
    }

    func discardCheckpoint(id: UUID) { try? FileManager.default.removeItem(at: partialURL(id)) }

    /// At launch: every leftover checkpoint becomes a run marked "Recovered (incomplete)".
    @discardableResult
    func recover() -> [TestRunMeta] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var recovered: [TestRunMeta] = []
        var current = index()
        for name in names where name.hasSuffix(".partial") {
            let url = directory.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url), var stored = try? unpack(data) else { continue }
            if current.runs.contains(where: { $0.id == stored.meta.id }) { continue }
            stored.meta.completeness = "recovered"
            stored.meta.endReason = "recovered"
            guard let packed = try? pack(stored) else { continue }
            stored.meta.bytes = packed.count
            guard let final = try? pack(stored), (try? write(final, to: runURL(stored.meta.id))) != nil else { continue }
            stored.meta.bytes = final.count
            current.runs.append(stored.meta)
            recovered.append(stored.meta)
        }
        if !recovered.isEmpty {
            current = pruned(current)
            try? saveIndex(current)
        }
        return recovered
    }

    // MARK: load and edit

    func load(id: UUID) throws -> (TestRunMeta, DiagnosticSessionExport) {
        let stored = try unpack(try Data(contentsOf: runURL(id)))
        return (stored.meta, stored.snapshot)
    }

    func loadSnapshots(ids: [UUID]) -> [DiagnosticSessionExport] {
        ids.compactMap { try? load(id: $0).1 }
    }

    func delete(ids: [UUID]) {
        var current = index()
        for id in ids {
            try? FileManager.default.removeItem(at: runURL(id))
            try? FileManager.default.removeItem(at: partialURL(id))
        }
        current.runs.removeAll { ids.contains($0.id) }
        try? saveIndex(current)
    }

    func deleteAllUnpinned() -> Int {
        let ids = index().runs.filter { !$0.pinned }.map(\.id)
        delete(ids: ids)
        return ids.count
    }

    /// Edits only change the index and the run's own embedded meta; the snapshot is untouched.
    private func update(id: UUID, _ change: (inout TestRunMeta) -> Void) {
        var current = index()
        guard let position = current.runs.firstIndex(where: { $0.id == id }) else { return }
        change(&current.runs[position])
        try? saveIndex(current)
        if var stored = try? unpack((try? Data(contentsOf: runURL(id))) ?? Data()) {
            stored.meta = current.runs[position]
            if let packed = try? pack(stored) { try? write(packed, to: runURL(id)) }
        }
    }
    func setPinned(id: UUID, _ pinned: Bool) { update(id: id) { $0.pinned = pinned } }
    func rename(id: UUID, label: String) { update(id: id) { $0.label = TestRunMeta.cleanLabel(label) } }
    func move(id: UUID, toTest testID: UUID, name: String) {
        update(id: id) { $0.testID = testID; $0.testName = name }
    }
    func renameTest(testID: UUID, name: String) {
        let ids = index().runs.filter { $0.testID == testID }.map(\.id)
        for id in ids { update(id: id) { $0.testName = name } }
    }

    // MARK: retention

    /// Pinned runs are never removed. Unpinned: newest 40 and at most 100 MB in total.
    private func pruned(_ input: TestRunIndex) -> TestRunIndex {
        var value = input
        let unpinned = value.runs.filter { !$0.pinned }.sorted { $0.endedAt > $1.endedAt }
        var removed: [TestRunMeta] = []
        var kept = unpinned
        while kept.count > Self.keepUnpinned { removed.append(kept.removeLast()) }
        func total() -> Int { value.runs.reduce(0) { $0 + $1.bytes } - removed.reduce(0) { $0 + $1.bytes } }
        while total() > maximumTotalBytes, let oldest = kept.popLast() { removed.append(oldest) }
        guard !removed.isEmpty else { return value }
        for run in removed { try? FileManager.default.removeItem(at: runURL(run.id)) }
        let ids = Set(removed.map(\.id))
        value.runs.removeAll { ids.contains($0.id) }
        value.pruneNote = "\(removed.count) older run\(removed.count == 1 ? "" : "s") removed to stay under 100 MB / \(Self.keepUnpinned) runs"
        return value
    }

    func clearPruneNote() {
        var current = index(); current.pruneNote = nil; try? saveIndex(current)
    }

    // MARK: migration from diagnostic_sessions rows

    var migrationDone: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.importedMarker).path) }

    /// Converts old payloads (JSON `DiagnosticSessionExport`) once. Never deletes the source rows.
    func migrate(payloads: [Data], testID: UUID = UUID()) async -> Int {
        guard !migrationDone else { return 0 }
        var imported = 0
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for payload in payloads {
            guard let old = try? decoder.decode(DiagnosticSessionExport.self, from: payload) else { continue }
            if index().runs.contains(where: { $0.id == old.id }) { continue }
            let meta = TestRunMeta.make(snapshot: old, testID: testID, testName: "Imported sessions",
                endReason: "imported", startingRAMEntries: 0, modeChanges: [], completeness: "imported")
            if case .saved = await save(meta: meta, snapshot: old) { imported += 1 }
        }
        try? write(Data(), to: directory.appendingPathComponent(Self.importedMarker))
        return imported
    }
}
