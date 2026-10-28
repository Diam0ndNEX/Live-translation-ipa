import SwiftUI

struct MemoryManagementView: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @State private var entries: [MemoryStoredEntry] = []
    @State private var query = ""
    @State private var confirmClear = false
    @State private var message = ""
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
                }
                if let failure = engine.memoryFailure { Text(failure).foregroundStyle(.orange) }
                Picker("RAM entries", selection: $ramCapacity) {
                    Text("1,000").tag(1000); Text("3,000").tag(3000); Text("6,000").tag(6000)
                }
                Picker("Management threshold", selection: $softLimit) {
                    Text("25,000").tag(25000); Text("100,000").tag(100000)
                    Text("500,000").tag(500000); Text("Storage aware").tag(0)
                }
                Text("Thresholds do not delete translations. RAM eviction preserves committed entries.").font(.footnote)
            }
            Section("Maintenance") {
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
            Section("Entries · up to 100 matches") {
                ForEach(entries) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.sourceText)
                        Text(entry.translatedText).foregroundStyle(.secondary)
                        Text("\(entry.sourceLanguage) → \(entry.targetLanguage) · \(entry.validationState)").font(.caption)
                    }
                    .swipeActions {
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
        .confirmationDialog("Permanently delete translation memory? History and settings remain.", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete translation memory", role: .destructive) { engine.clearMemory(); entries = [] }
        }
    }
}
