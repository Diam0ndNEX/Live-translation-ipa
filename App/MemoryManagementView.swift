// ScreenLingo – App – Translation memory (2.1.0)
import SwiftUI
import UniformTypeIdentifiers

/// Everything this screen shows from the engine. Equatable, so the page redraws only when one of these changes.
struct MemoryFacts: Equatable {
    struct Health: Equatable {
        var totalEntries: Int, readyEntries: Int, needsValidation: Int
        var legacyValidated: Int, legacySuperseded: Int, legacyUnverified: Int
        var suggestedOCRMatches: Int, suggestedFragmentMatches: Int, conflicts: Int
        var databaseBytes: Int64
        var migrationStatus: String, integrity: String
        var failedWrites: Int, importedEntries: Int, duplicateEntries: Int
        var categoryCounts: [String: Int]
        var lastVerifiedBackup: String?
        init(_ h: MemoryStoreHealth) {
            totalEntries = h.totalEntries; readyEntries = h.readyEntries; needsValidation = h.needsValidation
            legacyValidated = h.legacyValidated; legacySuperseded = h.legacySuperseded; legacyUnverified = h.legacyUnverified
            suggestedOCRMatches = h.suggestedOCRMatches; suggestedFragmentMatches = h.suggestedFragmentMatches; conflicts = h.conflicts
            databaseBytes = h.databaseBytes; migrationStatus = h.migrationStatus; integrity = h.integrity
            failedWrites = h.failedWrites; importedEntries = h.importedEntries; duplicateEntries = h.duplicateEntries
            categoryCounts = h.categoryCounts; lastVerifiedBackup = h.lastVerifiedBackup
        }
    }
    var count: Int
    var pendingWrites: Int
    var health: Health?
    var failure: String?
    var captureInProgress: Bool
    var idleStatus: String
    var inventory: [String: Int]
    var scanReasons: [String: Int]
    var warmupMs: Double?
    var batchActive: Bool
    var batchTotal: Int, batchProcessed: Int, batchCompleted: Int, batchSkipped: Int, batchWorkers: Int
    var validatedThisSession: Int
    var perMinute: Double
    var remainingMinutes: Double?

    @MainActor static func read(_ e: TranslatorEngine) -> MemoryFacts {
        MemoryFacts(count: e.memoryCount, pendingWrites: e.memoryPendingWrites, health: e.memoryHealth.map(Health.init),
                    failure: e.memoryFailure, captureInProgress: e.captureAlive || e.pipActive,
                    idleStatus: e.legacyIdleValidationStatus, inventory: e.legacyValidationInventory,
                    scanReasons: e.legacyScanReasons, warmupMs: e.warmupLastDurationMs, batchActive: e.legacyBatchActive,
                    batchTotal: e.legacyBatchTotal, batchProcessed: e.legacyBatchProcessed, batchCompleted: e.legacyBatchCompleted,
                    batchSkipped: e.legacyBatchSkipped, batchWorkers: e.legacyBatchWorkers,
                    validatedThisSession: e.legacyValidatedThisSession, perMinute: e.legacyEntriesPerMinute,
                    remainingMinutes: e.legacyEstimatedRemainingMinutes)
    }
}

struct MemoryManagementView: View {
    @EngineHandle private var engine
    @EngineFacts(MemoryFacts.read) private var facts
    @State private var entries: [MemoryStoredEntry] = []
    @State private var conflictingEntries: [MemoryStoredEntry] = []
    @State private var showConflicts = false
    @State private var snapshotNames: [String] = []
    @State private var selectedSnapshot: String?
    @State private var confirmSnapshotMerge = false
    @State private var confirmUnavailableRestore = false
    @State private var query = ""
    @State private var healthRefreshed = false
    @State private var confirmClear = false
    @State private var confirmDeleteLegacy = false
    @State private var message = ""
    @State private var transfer = MemoryTransferDocument(data: Data())
    @State private var exporting = false
    @State private var importing = false
    @State private var transferBusy = false
    @AppStorage("legacyIdleValidationEnabled") private var legacyIdleValidationEnabled = false
    @AppStorage("memoryRAMCapacity") private var ramCapacity = 3000
    @AppStorage("memorySoftLimit") private var softLimit = 100000

    /// Bulk database operations must not compete with active OCR/PiP lookups.
    private var captureInProgress: Bool { facts.captureInProgress }

    var body: some View {
        List {
            Section {
                MemorySummary(facts: facts)
                if let failure = facts.failure { Banner(text: failure, severity: .warning) }
                if let health = facts.health, softLimit > 0, health.totalEntries >= softLimit {
                    Banner(text: "Storage management threshold reached. No entries were deleted.", severity: .info)
                }
            } header: { Text("What is remembered") }
            Section {
                Picker("RAM entries", selection: $ramCapacity) {
                    Text("1,000").tag(1000); Text("3,000").tag(3000); Text("6,000").tag(6000)
                }
                Picker("Management threshold", selection: $softLimit) {
                    Text("25,000").tag(25000); Text("100,000").tag(100000)
                    Text("500,000").tag(500000); Text("Storage aware").tag(0)
                }
                Hint("Thresholds do not delete translations. RAM eviction preserves committed entries.")
            } header: { Text("Limits") }
            AdvancedSection(title: "Memory details") {
                if let h = facts.health {
                    LabeledContent("Migration", value: h.migrationStatus)
                    LabeledContent("Integrity", value: h.integrity)
                    LabeledContent("Ready for compatible reuse", value: String(h.readyEntries))
                    LabeledContent("Needs validation", value: String(h.needsValidation))
                    LabeledContent("Older entries pending verification", value: String(h.legacyUnverified))
                    LabeledContent("Older translations independently verified", value: String(h.legacyValidated))
                    LabeledContent("Older translations superseded", value: String(h.legacySuperseded))
                    LabeledContent("Conflicts", value: String(h.conflicts))
                    LabeledContent("Legacy imports", value: String(h.importedEntries))
                    LabeledContent("Legacy duplicates", value: String(h.duplicateEntries))
                    LabeledContent("Failed write attempts", value: String(h.failedWrites))
                    LabeledContent("Last verified backup", value: h.lastVerifiedBackup ?? "None")
                    ForEach(h.categoryCounts.keys.sorted(), id: \.self) { category in
                        LabeledContent(category.replacingOccurrences(of: "_", with: " ").capitalized,
                                       value: String(h.categoryCounts[category, default: 0]))
                    }
                }
                Hint("Live validation uses independently confirmed model output; optional idle validation makes bounded on-device model requests when screen capture is stopped. Originals remain preserved.")
            }
            AdvancedSection(title: "Review old saved translations") {
                Toggle("Automatically validate while idle", isOn: $legacyIdleValidationEnabled)
                Text("Off by default. Automatic batches check up to 24 eligible entries every 8 seconds after the prior batch finishes (20 seconds when warm). Each model call translates up to 12 entries; up to 2 independent sessions operate concurrently (1 when warm). Only runs in the foreground without capture or PiP.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Validate up to 48 entries now") {
                    engine.startLegacyValidation(maxEntries: IdleLegacyBatchPolicy.manualEntries)
                }.disabled(captureInProgress || transferBusy ||
                    facts.health == nil)
                Button("Delete unvalidated legacy entries…", role: .destructive) { confirmDeleteLegacy = true }
                    .disabled(captureInProgress || transferBusy || facts.batchActive ||
                        (facts.health?.legacyUnverified ?? 0) == 0)
                LabeledContent("Validation activity", value: facts.idleStatus)
                Button("Rescan pending legacy records") { engine.rescanLegacyValidation() }
                    .disabled(captureInProgress || transferBusy || facts.batchActive || facts.health == nil)
                ForEach(facts.inventory.keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: String(facts.inventory[key] ?? 0))
                }
                ForEach(facts.scanReasons.keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: String(facts.scanReasons[key] ?? 0))
                }
                Text("Inventory is a snapshot from the last scan. Scan candidates still need compatible keys, unchanged cleanup, one sentence unit and an installed model. Skip reasons describe the latest scanned batch, not every pending record. Scanning resumes automatically after language, rule or database changes. Originals are preserved.")
                    .font(.footnote).foregroundStyle(.secondary)
                TranslationActivityView()
                if let duration = facts.warmupMs {
                    LabeledContent("Last model warm-up", value: "\(Int(duration)) ms")
                }
                if let h = facts.health {
                    LabeledContent("Older entries remaining", value: String(h.legacyUnverified))
                    let resolved = h.legacyValidated + h.legacySuperseded
                    let totalHistorical = resolved + h.legacyUnverified
                    if totalHistorical > 0 {
                        ProgressView(value: Double(resolved), total: Double(totalHistorical)) {
                            Text("Historical memory classified")
                        } currentValueLabel: {
                            Text("\(resolved) / \(totalHistorical)")
                        }
                    }
                }
                if facts.batchActive {
                    ProgressView(value: Double(facts.batchProcessed),
                        total: Double(max(1, facts.batchTotal))) {
                        Text("Current batch — translated")
                    } currentValueLabel: {
                        Text("\(facts.batchProcessed) / \(facts.batchTotal)")
                    }
                    Text("Model results are saved only after the batch passes validation checks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Model workers", value: String(facts.batchWorkers))
                LabeledContent("Selected in batch", value: String(facts.batchTotal))
                LabeledContent("Translated in batch", value: String(facts.batchProcessed))
                LabeledContent("Validated in batch", value: String(facts.batchCompleted))
                LabeledContent("Skipped or unsupported", value: String(facts.batchSkipped))
                LabeledContent("Verified this session", value: String(facts.validatedThisSession))
                if facts.perMinute > 0 {
                    LabeledContent("Observed validation speed",
                        value: String(format: "%.1f entries/min", facts.perMinute))
                    if let estimate = facts.remainingMinutes {
                        LabeledContent("Estimated time remaining",
                            value: estimate >= 60 ?
                                String(format: "~%.1f hours", estimate / 60) :
                                String(format: "~%.0f min", estimate))
                        Text("Estimate assumes all remaining entries are eligible and the last batches' speed continues. Unsupported or incompatible entries can remain pending.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if facts.batchActive {
                    Button("Stop validation") { engine.cancelLegacyValidation() }
                }
                if let h = facts.health {
                    LabeledContent("OCR-related suggestions", value: String(h.suggestedOCRMatches))
                    LabeledContent("Fragment alignment suggestions", value: String(h.suggestedFragmentMatches))
                }
                Text("Similar text is a review suggestion only, not a trusted cache hit. Older answers are preserved, including alternative wording.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Export and import") {
                HStack(spacing: KitSpace.tight) {
                    SecondaryButton(title: transferBusy ? "Preparing…" : "Export", symbol: "square.and.arrow.up", enabled: !(transferBusy || captureInProgress)) {
                        transferBusy = true
                        Task {
                            defer { transferBusy = false }
                            do { transfer = MemoryTransferDocument(data: try await engine.memoryStore.exportData()); exporting = true }
                            catch { message = "Export failed; memory unchanged" }
                        }
                    }
                    SecondaryButton(title: "Import", symbol: "square.and.arrow.down", enabled: !(transferBusy || captureInProgress)) { importing = true }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: KitSpace.tight, leading: KitSpace.gap, bottom: KitSpace.tight, trailing: KitSpace.gap))
                Text("Memory exports contain source and translated text. Choose where to save them.").font(.footnote)
            }
            AdvancedSwitchSection()
            AdvancedSection(title: "Conflicting translations") {
                Button(showConflicts ? "Refresh conflict inspection" : "Inspect conflicting translations") {
                    Task {
                        do {
                            conflictingEntries = try await engine.memoryStore.conflictingEntries(limit: 100)
                            showConflicts = true
                        } catch { message = "Conflict inspection unavailable; memory unchanged" }
                    }
                }
                if showConflicts {
                    if conflictingEntries.isEmpty { Text("No unresolved conflicts").foregroundStyle(.secondary) }
                    ForEach(conflictingEntries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.sourceText)
                            Text(entry.translatedText).foregroundStyle(.secondary)
                            Text("\(entry.sourceLanguage) → \(entry.targetLanguage) · \(entry.validationState)")
                                .font(.footnote)
                        }
                    }
                }
                Text("Conflicting alternatives are preserved. Inspect them before removing any entry.").font(.footnote)
            }
            AdvancedSection(title: "Maintenance") {
                Button(transferBusy ? "Preparing snapshot…" : "Create recovery snapshot") {
                    transferBusy = true
                    Task {
                        defer { transferBusy = false }
                        do {
                            _ = try await engine.memoryStore.createRecoverySnapshot()
                            await engine.refreshMemoryHealth()
                            message = "Verified recovery snapshot created. Existing memory preserved."
                        } catch { message = "Recovery snapshot failed; existing memory unchanged" }
                    }
                }.disabled(transferBusy || captureInProgress)
                Text("Snapshots protect stored memory, but restoring an older snapshot can omit newer translations. No automatic rollback is performed.").font(.footnote)
                if facts.pendingWrites > 0 {
                    Button("Retry pending confirmed-memory writes") {
                        engine.saveMemory(force: true)
                        message = "Persistence retry requested; verify that pending writes reach zero."
                    }
                    .disabled(transferBusy || captureInProgress || facts.health == nil)
                }
                Button("Clear RAM cache") { engine.clearRAMCache() }
                Button("Verify integrity") {
                    Task {
                        do { message = try await engine.memoryStore.verifyIntegrity(); await engine.refreshMemoryHealth() }
                        catch { message = "Integrity verification failed; data preserved" }
                    }
                }.disabled(captureInProgress || transferBusy)
                Button("Delete all translation memory", role: .destructive) { confirmClear = true }
                    .disabled(captureInProgress || transferBusy)
                if captureInProgress {
                    Text("Stop screen capture and PiP before running database maintenance.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Banner(text: message, severity: .info) }
            }
            AdvancedSection(title: "Recovery copies") {
                Button("Inspect saved recovery snapshots") {
                    Task {
                        do {
                            snapshotNames = try await engine.memoryStore.recoverySnapshots()
                            if snapshotNames.isEmpty { message = "No recovery snapshots available" }
                        } catch { message = "Cannot inspect recovery snapshots" }
                    }
                }
                ForEach(snapshotNames, id: \.self) { name in
                    Button(name) {
                        selectedSnapshot = name
                        if facts.health == nil {
                            confirmUnavailableRestore = true
                        } else {
                            confirmSnapshotMerge = true
                        }
                    }
                    .disabled(transferBusy || captureInProgress)
                }
                Text("If the database is healthy, recovery merges translations without replacing it. If the database cannot open, an explicit restore preserves its damaged files but may exclude newer translations not in the snapshot. Stop live translation before restoring.")
                    .font(.footnote)
            }
            AdvancedSection(title: "Browse entries (up to 100 matches)") {
                ForEach(entries) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.sourceText)
                        Text(entry.translatedText).foregroundStyle(.secondary)
                        Text("\(entry.sourceLanguage) → \(entry.targetLanguage) · \(entry.validationState)").font(.footnote)
                    }
                    .swipeActions {
                        Button("Review") {
                            Task {
                                do {
                                    try await engine.quarantineMemoryEntries(ids: [entry.id])
                                    entries = try await engine.memoryStore.search(query: query, limit: 100)
                                    message = "Entry preserved, but excluded from automatic reuse"
                                } catch { message = "Cannot review while memory is being saved" }
                            }
                        }.tint(.orange)
                        Button("Delete", role: .destructive) {
                            Task {
                                do { try await engine.removeMemoryEntries(ids: [entry.id]); entries.removeAll { $0.id == entry.id } }
                                catch { message = "Deletion unavailable while writes are pending; retry after saving" }
                            }
                        }
                    }
                }
            }
        }
        .settingsPage("Memory")
        .fileExporter(isPresented: $exporting, document: transfer, contentType: .json, defaultFilename: "screenlingo-memory") { result in
            switch result {
            case .success: message = "Memory exported"
            case .failure: message = "Export cancelled or failed"
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard !captureInProgress else { message = "Stop screen capture before importing memory"; return }
            guard case .success(let url) = result else { message = "Import cancelled or failed"; return }
            transferBusy = true
            Task {
                defer { transferBusy = false }
                do {
                    let data = try await Task.detached(priority: .utility) {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 256 * 1024 * 1024 else { throw MemoryStoreError.tooLarge }
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        // A security-scoped provider may omit fileSize; cap the actual
                        // bytes read so large documents cannot bypass the size check.
                        let data = try handle.read(upToCount: 256 * 1024 * 1024 + 1) ?? Data()
                        guard data.count <= 256 * 1024 * 1024 else { throw MemoryStoreError.tooLarge }
                        return data
                    }.value
                    try await engine.importMemoryData(data)
                    message = "Memory imported; compatibility checks remain active"
                } catch { message = "Import failed; existing memory preserved" }
            }
        }
        .searchable(text: $query)
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                let results = try await engine.memoryStore.search(query: query, limit: 100)
                guard !Task.isCancelled else { return }
                entries = results
                // 2.2.1 (U8): health is a full set of COUNT queries on the memory actor that also serves live lookups,
                // so it is refreshed once when the page opens and after maintenance actions, not after every search.
                if !healthRefreshed {
                    healthRefreshed = true
                    await engine.refreshMemoryHealth()
                }
            } catch { message = "Memory is preparing or unavailable" }
        }
        .confirmationDialog("Restore an unavailable database from this snapshot? The unreadable database and its journals will be preserved separately. Translations newer than the snapshot may not be in the restored database.", isPresented: $confirmUnavailableRestore, titleVisibility: .visible) {
            Button("Restore from verified snapshot", role: .destructive) {
                guard let name = selectedSnapshot, !captureInProgress else {
                    message = "Stop live translation before restoring the database"
                    return
                }
                transferBusy = true
                Task {
                    defer { transferBusy = false }
                    do {
                        try await engine.restoreUnavailableMemoryFromSnapshot(named: name)
                        entries = try await engine.memoryStore.search(query: query, limit: 100)
                        message = "Memory recovered. Original unreadable SQLite files were preserved."
                    } catch {
                        message = "Database recovery failed. Original files were preserved; fresh translation remains available."
                    }
                }
            }
        }
        .confirmationDialog("Merge a recovery snapshot with current memory? Existing entries will be preserved.", isPresented: $confirmSnapshotMerge, titleVisibility: .visible) {
            Button("Merge snapshot") {
                guard let name = selectedSnapshot, !engine.pipActive else {
                    message = "Stop live translation before recovering memory"
                    return
                }
                transferBusy = true
                Task {
                    defer { transferBusy = false }
                    do {
                        try await engine.mergeMemoryRecoverySnapshot(named: name)
                        message = "Recovery snapshot merged; conflicting alternatives retained"
                    } catch {
                        message = "Recovery merge failed; current memory preserved"
                    }
                }
            }
        }
        .confirmationDialog("Delete only unvalidated legacy entries? This removes pending legacy records across ALL source/target languages and lengths, including those outside 4–240 characters. Validated legacy records, current memory, history and settings remain. Recovery copies are retained.", isPresented: $confirmDeleteLegacy, titleVisibility: .visible) {
            Button("Delete unvalidated legacy entries", role: .destructive) {
                transferBusy = true
                Task {
                    defer { transferBusy = false }
                    do {
                        let count = try await engine.deleteUnvalidatedLegacy()
                        entries = (try? await engine.memoryStore.search(query: query)) ?? entries
                        message = "Deleted \(count) unvalidated legacy entries. Validated and current memory preserved."
                    } catch {
                        message = "Deletion unavailable or failed. Stop capture/PiP and wait for writes/validation, then retry."
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Delete translation memory? History and settings remain. Choose whether to retain recovery copies.", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear active memory (keep recovery copies)", role: .destructive) {
                Task {
                    let committed = await engine.clearMemoryConfirmed()
                    if committed {
                        entries.removeAll()
                        message = "Active memory cleared. Legacy originals and recovery snapshots were retained."
                    } else {
                        message = engine.memoryFailure ?? "Memory deletion was not completed"
                    }
                }
            }
            Button("Clear memory and erase recovery copies", role: .destructive) {
                Task {
                    guard await engine.clearMemoryConfirmed() else {
                        message = engine.memoryFailure ?? "Memory deletion was not completed"
                        return
                    }
                    entries.removeAll()
                    do {
                        try await engine.purgePreservedMemoryCopies()
                        message = "Active memory and preserved app memory copies erased; history and settings retained"
                    } catch {
                        message = "Active memory cleared, but some recovery copies could not be erased; retry required"
                    }
                }
            }
        }
    }
}

struct MemoryTransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}



/// Opens on one number and a verdict, e.g. "3,204 remembered · healthy" (§13.5.8).
private struct MemorySummary: View {
    let facts: MemoryFacts
    private var integrityOK: Bool { facts.health.map { $0.integrity == "ok" } ?? false }
    private var verdict: (text: String, tone: PhaseTone) {
        guard let health = facts.health else { return ("preparing", .neutral) }
        if !integrityOK { return ("integrity: \(health.integrity.replacingOccurrences(of: "_", with: " "))", .caution) }
        if health.failedWrites > 0 || facts.failure != nil { return ("check the details below", .caution) }
        return ("healthy", .neutral)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: KitSpace.tight) {
            HeroNumber(text: facts.count.formatted())
            HStack(spacing: KitSpace.unit) {
                Text("remembered ·").foregroundStyle(.secondary)
                Text(verdict.text).foregroundStyle(verdict.tone == .neutral ? Color.secondary : verdict.tone.color)
            }
            .font(.subheadline)
            Text([facts.pendingWrites > 0 ? "\(facts.pendingWrites.formatted()) waiting to be written" : nil,
                  facts.health.map { ByteCountFormatter.string(fromByteCount: $0.databaseBytes, countStyle: .file) + " on disk" },
                  facts.health.flatMap { $0.legacyUnverified > 0 ? "\($0.legacyUnverified.formatted()) older entries not reused until verified" : nil }]
                .compactMap { $0 }.joined(separator: "  ·  "))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
