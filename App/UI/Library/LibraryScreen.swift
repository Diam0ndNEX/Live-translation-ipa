// ScreenLingo – App – Library tab (2.1.0, spec §13.5.3; 2.7.0 list and detail side by side on iPad)
// Two segments, Saved and Recent (people think of them separately). One "•••" menu for select, export, restore.
import SwiftUI
import UniformTypeIdentifiers

extension HistoryItem: Equatable {
    static func == (a: HistoryItem, b: HistoryItem) -> Bool {
        a.id == b.id && a.original == b.original && a.translated == b.translated && a.date == b.date
            && a.starred == b.starred && a.sourceLanguage == b.sourceLanguage
            && a.targetLanguage == b.targetLanguage && a.note == b.note
    }
}

private enum LibrarySegment: String, CaseIterable, Identifiable {
    case recent = "Recent", saved = "Saved"
    var id: String { rawValue }
}

struct LibraryScreen: View {
    let engine: TranslatorEngine
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var feedback: FeedbackCenter
    @StateObject private var store: EngineSlice<[HistoryItem]>
    @State private var query = ""
    @State private var segment = LibrarySegment.recent
    @State private var selection: Set<UUID> = []
    @State private var editMode = EditMode.inactive
    @State private var confirmDelete = false
    @State private var importing = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(engine: TranslatorEngine) {
        self.engine = engine
        _store = StateObject(wrappedValue: EngineSlice(engine) { $0.history })
    }

    private var history: [HistoryItem] {
        #if SCREENLINGO_FIXTURES
        if let fixture = UIFixture.libraryFixture { return fixture }
        #endif
        return store.value
    }
    private var items: [HistoryItem] {
        history.filter { h in
            (segment == .recent || h.starred)
                && (query.isEmpty || h.original.localizedCaseInsensitiveContains(query)
                    || h.translated.localizedCaseInsensitiveContains(query)
                    || (h.note ?? "").localizedCaseInsensitiveContains(query))
        }
    }
    private var groups: [(day: Date, items: [HistoryItem])] {
        Dictionary(grouping: items, by: { Calendar.current.startOfDay(for: $0.date) })
            .map { (day: $0.key, items: $0.value) }.sorted { $0.day > $1.day }
    }
    /// 2.7.0: export takes the checked rows only while selecting. On iPad a single row is selected just to read it,
    /// and that must not shrink an export to one item.
    private var exportItems: [HistoryItem] { selecting && !selection.isEmpty ? items.filter { selection.contains($0.id) } : items }
    private var selecting: Bool { editMode.isEditing }

    var body: some View {
        Group {
            if sizeClass == .regular { splitLayout } else { stackLayout }
        }
        .onAppear { takeFocus() }
        .onChange(of: router.libraryFocus) { _, _ in takeFocus() }
    }

    /// iPhone and narrow iPad windows: one stack, rows push the detail.
    private var stackLayout: some View {
        NavigationStack(path: $router.libraryPath) {
            libraryList(linking: true)
                .modifier(ReadableColumn())
                .navigationDestination(for: UUID.self) { id in
                    if let item = history.first(where: { $0.id == id }) { LibraryDetail(engine: engine, item: item) }
                }
        }
    }

    /// 2.7.0, iPad: the list on the left, the selected translation on the right.
    private var splitLayout: some View {
        NavigationSplitView {
            libraryList(linking: false)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
        } detail: {
            NavigationStack { splitDetail }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder private var splitDetail: some View {
        if !selecting, selection.count == 1, let id = selection.first, let item = history.first(where: { $0.id == id }) {
            LibraryDetail(engine: engine, item: item).id(id)   // a new detail per item, so the note field never shows the previous one
        } else if selecting {
            ContentUnavailableView("\(selection.count) selected", systemImage: "checkmark.circle",
                                   description: Text("Export or delete them with the buttons under the list."))
        } else {
            ContentUnavailableView("Choose a translation", systemImage: "text.book.closed",
                                   description: Text("Pick one on the left to read it, add a note or share it."))
        }
    }

    /// A Recent row on Translate asked for this item.
    private func takeFocus() {
        guard let id = router.libraryFocus else { return }
        router.libraryFocus = nil
        guard sizeClass == .regular else { return }   // the stack already has it on its path
        query = ""
        if let item = history.first(where: { $0.id == id }), !item.starred { segment = .recent }
        editMode = .inactive
        selection = [id]
    }

    @ViewBuilder private func row(_ item: HistoryItem, linking: Bool) -> some View {
        if linking {
            NavigationLink(value: item.id) { LibraryRow(item: item) }
        } else {
            LibraryRow(item: item)
        }
    }

    private func libraryList(linking: Bool) -> some View {
        List(selection: $selection) {
                Section {
                    Picker("Show", selection: $segment) { ForEach(LibrarySegment.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                        .listRowInsets(EdgeInsets(top: KitSpace.tight, leading: 0, bottom: KitSpace.tight, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                // 2.2.2: the empty state is a row under the switch. As an overlay centred on the list it was drawn over
                // the Recent/Saved switch once the text got large.
                if items.isEmpty {
                    Section {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                    }
                }
                ForEach(groups, id: \.day) { group in
                    Section(Self.dayTitle(group.day)) {
                        ForEach(group.items) { item in
                            row(item, linking: linking)
                                .tag(item.id)
                                .swipeActions(edge: .leading) {
                                    Button { engine.toggleStar(item.id) } label: {
                                        Label(item.starred ? "Unsave" : "Save", systemImage: item.starred ? "star.slash" : "star")
                                    }
                                    .tint(.yellow)
                                }
                                .swipeActions {
                                    Button(role: .destructive) { delete([item.id]) } label: { Label("Delete", systemImage: "trash") }
                                }
                                // 2.7.0: long press (or right click on iPad) offers the same actions as the detail page.
                                .contextMenu {
                                    Button { engine.toggleStar(item.id) } label: {
                                        Label(item.starred ? "Unsave" : "Save", systemImage: item.starred ? "star.slash" : "star")
                                    }
                                    Button {
                                        UIPasteboard.general.string = item.translated
                                        feedback.show("Copied", severity: .success)
                                    } label: { Label("Copy translation", systemImage: "doc.on.doc") }
                                    Button { engine.speak(item.translated) } label: { Label("Listen", systemImage: "speaker.wave.2") }
                                    ShareLink(item: item.translated) { Label("Share", systemImage: "square.and.arrow.up") }
                                    Button(role: .destructive) { delete([item.id]) } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .kitPage()
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Search translations and notes")
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if selecting {
                        Button("Done") { withAnimation { editMode = .inactive }; selection = [] }.bold()
                    } else {
                        Menu {
                            Button { withAnimation { selection = []; editMode = .active } } label: { Label("Select", systemImage: "checkmark.circle") }
                                .disabled(items.isEmpty)
                            Section("Export") {
                                Button { Sharer.shareFile(text: exportText, name: "screenlingo-history.txt") } label: { Label("Text", systemImage: "doc.plaintext") }
                                Button { Sharer.shareFile(text: engine.historyCSV(exportItems), name: "screenlingo-history.csv") } label: { Label("CSV", systemImage: "tablecells") }
                                Button { Sharer.shareFile(text: engine.historyJSON(exportItems), name: "screenlingo-history.json") } label: { Label("JSON backup", systemImage: "curlybraces") }
                            }
                            Button { importing = true } label: { Label("Restore from backup…", systemImage: "arrow.counterclockwise") }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if selecting {
                        Button(selection.count == items.count ? "Deselect all" : "Select all") {
                            selection = selection.count == items.count ? [] : Set(items.map(\.id))
                        }
                        Spacer()
                        Menu("Export") {
                            Button("Text") { Sharer.shareFile(text: exportText, name: "screenlingo-history.txt") }
                            Button("CSV") { Sharer.shareFile(text: engine.historyCSV(exportItems), name: "screenlingo-history.csv") }
                            Button("JSON backup") { Sharer.shareFile(text: engine.historyJSON(exportItems), name: "screenlingo-history.json") }
                        }
                        .disabled(selection.isEmpty)
                        Spacer()
                        Button("Delete", role: .destructive) { confirmDelete = true }.disabled(selection.isEmpty)
                    }
                }
            }
            .confirmationDialog("Delete \(selection.count) translation\(selection.count == 1 ? "" : "s")?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete(selection); selection = []; editMode = .inactive }
            } message: { Text("You can undo right after.") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let ok = engine.importHistory(try Data(contentsOf: url))
                    feedback.show(ok ? "Library restored" : "This is not a valid ScreenLingo backup", severity: ok ? .success : .error)
                } catch { feedback.show("Could not open the backup file", severity: .error) }
            }
    }

    static func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private var exportText: String {
        exportItems.map { "\($0.original)\n→ \($0.translated)" }.joined(separator: "\n\n")
    }

    @ViewBuilder private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if segment == .saved {
            ContentUnavailableView("Nothing saved yet", systemImage: "star",
                                   description: Text("Swipe right on a translation to save it."))
        } else {
            ContentUnavailableView {
                Label("No translations yet", systemImage: "text.book.closed")
            } description: {
                Text("Translations appear here. Nothing is kept during a private session.")
            } actions: {
                Button("Start capture") { router.go(.translate) }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func delete(_ ids: Set<UUID>) {
        selection.subtract(ids)   // 2.7.0: the iPad detail must not keep showing a deleted item
        engine.deleteHistory(ids: ids)
        feedback.show("Deleted \(ids.count) translation\(ids.count == 1 ? "" : "s")", actionTitle: "Undo") { [engine] in
            engine.undoHistoryDeletion()
        }
    }
}

/// Translation (2 lines), original (1 line), trailing time; the pair is a small footnote.
private struct LibraryRow: View {
    let item: HistoryItem
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        // 2.2.2: at accessibility sizes the time, pair and star go under the text instead of squeezing it to "Hello, how a…".
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: KitSpace.unit) {
                Text(item.translated).font(.body.weight(.medium)).lineLimit(4)
                Text(item.original).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: KitSpace.tight) {
                    Text(item.date.formatted(date: .omitted, time: .shortened)).font(.footnote).foregroundStyle(.secondary)
                    if let from = item.sourceLanguage, let to = item.targetLanguage {
                        Text("\(from.uppercased())→\(to.uppercased())").font(.caption).foregroundStyle(.tertiary)
                    }
                    if item.starred { Image(systemName: "star.fill").font(.footnote).foregroundStyle(.yellow).accessibilityLabel("Saved") }
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            compactRow
        }
    }

    private var compactRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: KitSpace.tight) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.translated).font(.body.weight(.medium)).lineLimit(2)
                Text(item.original).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: KitSpace.tight)
            VStack(alignment: .trailing, spacing: KitSpace.unit) {
                Text(item.date.formatted(date: .omitted, time: .shortened)).font(.footnote).foregroundStyle(.secondary)
                if let from = item.sourceLanguage, let to = item.targetLanguage {
                    Text("\(from.uppercased())→\(to.uppercased())").font(.caption).foregroundStyle(.tertiary)
                }
                if item.starred { Image(systemName: "star.fill").font(.footnote).foregroundStyle(.yellow).accessibilityLabel("Saved") }
            }
        }
        .padding(.vertical, 0)
        .accessibilityElement(children: .combine)
    }
}

/// Translation large, original secondary, note, actions in a bottom toolbar.
struct LibraryDetail: View {
    let engine: TranslatorEngine
    let item: HistoryItem
    @EnvironmentObject private var feedback: FeedbackCenter
    @StateObject private var store: EngineSlice<[HistoryItem]>
    @State private var note: String
    @State private var noteSave: Task<Void, Never>?

    init(engine: TranslatorEngine, item: HistoryItem) {
        self.engine = engine
        self.item = item
        _note = State(initialValue: item.note ?? "")
        _store = StateObject(wrappedValue: EngineSlice(engine) { $0.history })
    }
    private var current: HistoryItem { store.value.first { $0.id == item.id } ?? item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KitSpace.group) {
                VStack(alignment: .leading, spacing: KitSpace.row) {
                    Text(current.translated).font(.title.weight(.semibold)).textSelection(.enabled)
                    Divider()
                    Text(current.original).font(.title3).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .kitSurface(padding: KitSpace.margin)
                VStack(alignment: .leading, spacing: KitSpace.tight) {
                    Text("Note").font(.headline)
                    TextField("Add context or vocabulary…", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                }
                .kitSurface()
                Text(footer).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(KitSpace.margin)
        }
        .ambientGlow()
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Translation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { engine.toggleStar(item.id) } label: {
                    Label(current.starred ? "Saved" : "Save", systemImage: current.starred ? "star.fill" : "star")
                }
                Spacer()
                Button { engine.speak(current.translated) } label: { Label("Listen", systemImage: "speaker.wave.2") }
                Spacer()
                Button {
                    UIPasteboard.general.string = current.translated
                    feedback.show("Copied", severity: .success)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                Spacer()
                ShareLink(item: current.translated) { Label("Share", systemImage: "square.and.arrow.up") }
                Spacer()
                Button { Sharer.shareImage(engine.image(for: current)) } label: { Label("Picture", systemImage: "photo") }
            }
        }
        // 2.2.0: every keystroke used to rewrite the whole saved history (up to 1,000 items) on the main thread.
        // The note is now saved 0.6 s after typing stops, and immediately when the screen closes.
        .onChange(of: note) { _, value in
            noteSave?.cancel()
            noteSave = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                commitNote(value)
            }
        }
        .onDisappear { noteSave?.cancel(); commitNote(note) }
    }

    private func commitNote(_ value: String) {
        let trimmed = String(value.prefix(2000))
        guard let index = engine.history.firstIndex(where: { $0.id == item.id }),
              (engine.history[index].note ?? "") != trimmed else { return }
        engine.history[index].note = trimmed
    }

    private var footer: String {
        var parts = [current.date.formatted(date: .abbreviated, time: .shortened)]
        if let from = current.sourceLanguage, let to = current.targetLanguage { parts.append("\(from.uppercased()) → \(to.uppercased())") }
        return parts.joined(separator: " · ")
    }
}
