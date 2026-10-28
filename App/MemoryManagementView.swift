import SwiftUI
import UniformTypeIdentifiers

struct MemoryManagementView: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @State private var entries: [MemoryStoredEntry] = []
    @State private var conflictingEntries: [MemoryStoredEntry] = []
    @State private var showConflicts = false
    @State private var snapshotNames: [String] = []
    @State private var selectedSnapshot: String?
    @State private var confirmSnapshotMerge = false
    @State private var confirmUnavailableRestore = false
    @State private var query = ""
    @State private var confirmClear = false
    @State private var message = ""
    @State private var transfer = MemoryTransferDocument(data: Data())
    @State private var exporting = false
    @State private var importing = false
    @State private var transferBusy = false
    @AppStorage("memoryRAMCapacity") private var ramCapacity = 3000
    @AppStorage("memorySoftLimit") private var softLimit = 100000

    var body: some View {
        List {
            Section("Storage") {
                LabeledContent("Committed entries", value: String(engine.memoryCount))
                LabeledContent("Pending writes", value: String(engine.memoryPendingWrites))
                if let h = engine.memoryHealth {
                    LabeledContent("Migration", value: h.migrationStatus)
                    LabeledContent("Integrity", value: h.integrity)
                    LabeledContent("Needs validation", value: String(h.needsValidation))
                    LabeledContent("Conflicts", value: String(h.conflicts))
                    LabeledContent("Database", value: ByteCountFormatter.string(fromByteCount: h.databaseBytes, countStyle: .file))
                    LabeledContent("Last verified backup", value: h.lastVerifiedBackup ?? "None")
                }
                if let h = engine.memoryHealth, !h.categoryCounts.isEmpty {
                    ForEach(h.categoryCounts.keys.sorted(), id: \.self) { category in
                        LabeledContent(category.replacingOccurrences(of: "_", with: " ").capitalized,
                                       value: String(h.categoryCounts[category, default: 0]))
                    }
                }
                if let failure = engine.memoryFailure { Text(failure).foregroundStyle(.orange) }
                Picker("RAM entries", selection: $ramCapacity) {
                    Text("1,000").tag(1000); Text("3,000").tag(3000); Text("6,000").tag(6000)
                }
                Picker("Management threshold", selection: $softLimit) {
                    Text("25,000").tag(25000); Text("100,000").tag(100000)
                    Text("500,000").tag(500000); Text("Storage aware").tag(0)
                }
                if let health = engine.memoryHealth, softLimit > 0, health.totalEntries >= softLimit {
                    Label("Storage management threshold reached. No entries were deleted.", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.footnote)
                }
                Text("Thresholds do not delete translations. RAM eviction preserves committed entries.").font(.footnote)
            }
            Section("Transfer") {
                Button(transferBusy ? "Preparing…" : "Export translation memory") {
                    transferBusy = true
                    Task {
                        defer { transferBusy = false }
                        do { transfer = MemoryTransferDocument(data: try await engine.memoryStore.exportData()); exporting = true }
                        catch { message = "Export failed; memory unchanged" }
                    }
                }.disabled(transferBusy)
                Button("Import translation memory") { importing = true }.disabled(transferBusy)
                Text("Memory exports contain source and translated text. Choose where to save them.").font(.footnote)
            }
            Section("Conflicts") {
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
                                .font(.caption)
                        }
                    }
                }
                Text("Conflicting alternatives are preserved. Inspect them before removing any entry.").font(.footnote)
            }
            Section("Maintenance") {
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
                }.disabled(transferBusy)
                Text("Snapshots protect stored memory, but restoring an older snapshot can omit newer translations. No automatic rollback is performed.").font(.footnote)
                Button("Clear RAM cache") { engine.clearRAMCache() }
                Button("Verify integrity") {
                    Task {
                        do { message = try await engine.memoryStore.verifyIntegrity(); await engine.refreshMemoryHealth() }
                        catch { message = "Integrity verification failed; data preserved" }
                    }
                }
                Button("Delete all translation memory", role: .destructive) { confirmClear = true }
                if !message.isEmpty { Text(message) }
            }
            Section("Recovery snapshots") {
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
                        if engine.memoryHealth == nil {
                            confirmUnavailableRestore = true
                        } else {
                            confirmSnapshotMerge = true
                        }
                    }
                    .disabled(transferBusy || engine.pipActive)
                }
                Text("If the database is healthy, recovery merges translations without replacing it. If the database cannot open, an explicit restore preserves its damaged files but may exclude newer translations not in the snapshot. Stop live translation before restoring.")
                    .font(.footnote)
            }
            Section("Entries · up to 100 matches") {
                ForEach(entries) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.sourceText)
                        Text(entry.translatedText).foregroundStyle(.secondary)
                        Text("\(entry.sourceLanguage) → \(entry.targetLanguage) · \(entry.validationState)").font(.caption)
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
        .navigationTitle("Translation memory")
        .fileExporter(isPresented: $exporting, document: transfer, contentType: .json, defaultFilename: "screenlingo-memory") { result in
            switch result {
            case .success: message = "Memory exported"
            case .failure: message = "Export cancelled or failed"
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
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
                await engine.refreshMemoryHealth()
            } catch { message = "Memory is preparing or unavailable" }
        }
        .confirmationDialog("Restore an unavailable database from this snapshot? The unreadable database and its journals will be preserved separately. Translations newer than the snapshot may not be in the restored database.", isPresented: $confirmUnavailableRestore, titleVisibility: .visible) {
            Button("Restore from verified snapshot", role: .destructive) {
                guard let name = selectedSnapshot, !engine.pipActive else {
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
