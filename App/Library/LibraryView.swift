// ScreenLingo – App – Library tab (2.0.0 build 85)
import SwiftUI
import UniformTypeIdentifiers

extension HistoryItem: Equatable {}

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All", saved = "Saved", week = "Last 7 days"
    var id: String { rawValue }
}

struct LibraryView: View {
    let engine: TranslatorEngine
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var feedback: FeedbackCenter
    @StateObject private var store: EngineSlice<[HistoryItem]>
    @State private var query = ""
    @State private var filter = LibraryFilter.all
    @State private var selection: Set<UUID> = []
    @State private var editMode = EditMode.inactive
    @State private var confirmDelete = false
    @State private var importing = false

    init(engine: TranslatorEngine) {
        self.engine = engine
        _store = StateObject(wrappedValue: EngineSlice(engine) { $0.history })
    }

    private var items: [HistoryItem] {
        store.value.filter { h in
            (filter != .saved || h.starred)
                && (filter != .week || h.date >= Date().addingTimeInterval(-7 * 86400))
                && (query.isEmpty || h.original.localizedCaseInsensitiveContains(query)
                    || h.translated.localizedCaseInsensitiveContains(query)
                    || (h.note ?? "").localizedCaseInsensitiveContains(query))
        }
    }
    private var groups: [(day: Date, items: [HistoryItem])] {
        Dictionary(grouping: items, by: { Calendar.current.startOfDay(for: $0.date) })
            .map { (day: $0.key, items: $0.value) }.sorted { $0.day > $1.day }
    }
    private var exportItems: [HistoryItem] { selection.isEmpty ? items : items.filter { selection.contains($0.id) } }
    private var selecting: Bool { editMode.isEditing }

    var body: some View {
        NavigationStack(path: $router.libraryPath) {
            List(selection: $selection) {
                Section {
                    Button { router.present(.workspace) } label: {
                        ListRow(title: "Text & photos", subtitle: "Translate typed text, a photo or a file", symbol: "text.viewfinder") {
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }.buttonStyle(.plain)
                }
                ForEach(groups, id: \.day) { group in
                    Section(group.day.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(group.items) { item in
                            NavigationLink(value: item.id) { row(item) }
                                .tag(item.id)
                                .swipeActions(edge: .leading) {
                                    Button { engine.toggleStar(item.id) } label: { Label(item.starred ? "Unsave" : "Save", systemImage: item.starred ? "star.slash" : "star") }.tint(.yellow)
                                }
                                .swipeActions {
                                    Button(role: .destructive) { delete([item.id]) } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background.ignoresSafeArea())
            .overlay {
                if items.isEmpty {
                    EmptyState(title: query.isEmpty && filter == .all ? "Your library is empty" : "No matching translations",
                               symbol: "text.book.closed",
                               message: query.isEmpty && filter == .all
                               ? "Translations you keep appear here. Nothing is saved during a private session."
                               : "Try a different search or filter.")
                }
            }
            .searchable(text: $query, prompt: "Search original, translation or notes")
            .navigationTitle("Library")
            .navigationDestination(for: UUID.self) { id in
                if let item = store.value.first(where: { $0.id == id }) { HistoryDetail(engine: engine, item: item) }
            }
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? "Done" : "Select") {
                        withAnimation { editMode = selecting ? .inactive : .active }
                        selection = []
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: $filter) { ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) } }
                    } label: { Image(systemName: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") }
                        .accessibilityLabel("Filter: \(filter.rawValue)")
                    Menu {
                        Button("Export as text") { Sharer.shareFile(text: exportItems.map { "\($0.original)\n→ \($0.translated)" }.joined(separator: "\n\n"), name: "screenlingo-history.txt") }
                        Button("Export as CSV") { Sharer.shareFile(text: engine.historyCSV(exportItems), name: "screenlingo-history.csv") }
                        Button("Export as JSON backup") { Sharer.shareFile(text: engine.historyJSON(exportItems), name: "screenlingo-history.json") }
                        Divider()
                        Button("Restore from backup…") { importing = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("More: export or restore")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if selecting {
                        Button("Delete\(selection.isEmpty ? "" : " (\(selection.count))")", role: .destructive) { confirmDelete = true }
                            .disabled(selection.isEmpty)
                        Spacer()
                        Button(selection.count == items.count ? "Clear selection" : "Select all") {
                            selection = selection.count == items.count ? [] : Set(items.map(\.id))
                        }
                    }
                }
            }
            .confirmDestructive("Delete \(selection.count) selected translation\(selection.count == 1 ? "" : "s")?",
                                message: "You can undo right after.", isPresented: $confirmDelete) {
                delete(selection); selection = []
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let ok = engine.importHistory(try Data(contentsOf: url))
                    feedback.show(ok ? "Library restored" : "This is not a valid ScreenLingo backup", severity: ok ? .success : .error)
                } catch { feedback.show("Could not open the backup file", severity: .error) }
            }
        }
    }

    private func delete(_ ids: Set<UUID>) {
        engine.deleteHistory(ids: ids)
        feedback.show("Deleted \(ids.count) translation\(ids.count == 1 ? "" : "s")", actionTitle: "Undo") { engine.undoHistoryDeletion() }
    }

    /// Translation first, original second, metadata third.
    private func row(_ item: HistoryItem) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .top) {
                Text(item.translated).font(.body.weight(.medium)).lineLimit(3)
                Spacer()
                if item.starred { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Saved") }
            }
            Text(item.original).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text(item.date.formatted(date: .omitted, time: .shortened))
                if let from = item.sourceLanguage, let to = item.targetLanguage { Text("· \(from.uppercased()) → \(to.uppercased())") }
            }.font(.caption).foregroundStyle(.tertiary)
        }.padding(.vertical, Space.xs)
    }
}

struct HistoryDetail: View {
    let engine: TranslatorEngine
    let item: HistoryItem
    @StateObject private var store: EngineSlice<[HistoryItem]>
    @State private var note: String

    init(engine: TranslatorEngine, item: HistoryItem) {
        self.engine = engine
        self.item = item
        _note = State(initialValue: item.note ?? "")
        _store = StateObject(wrappedValue: EngineSlice(engine) { $0.history })
    }
    private var current: HistoryItem { store.value.first { $0.id == item.id } ?? item }

    var body: some View {
        ScreenScaffold {
            Text(current.translated).font(.title2.weight(.medium)).textSelection(.enabled)
            Text(current.original).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
            HStack(spacing: Space.s) {
                SecondaryButton(title: current.starred ? "Saved" : "Save", symbol: current.starred ? "star.fill" : "star") { engine.toggleStar(item.id) }
                SecondaryButton(title: "Listen", symbol: "speaker.wave.2") { engine.speak(current.translated) }
                SecondaryButton(title: "Copy", symbol: "doc.on.doc") { UIPasteboard.general.string = current.translated }
            }
            ShareLink(item: current.translated) { Label("Share text", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44) }
                .buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader(title: "Personal note")
                TextField("Add context or vocabulary…", text: $note, axis: .vertical).lineLimit(3...8)
            }.infoCard()
            SecondaryButton(title: "Share as picture", symbol: "photo") { Sharer.shareImage(engine.image(for: current)) }
            Text(current.date.formatted()).font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("Translation").navigationBarTitleDisplayMode(.inline)
        .onChange(of: note) { _, value in
            if let index = engine.history.firstIndex(where: { $0.id == item.id }) { engine.history[index].note = String(value.prefix(2000)) }
        }
    }
}
