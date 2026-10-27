// Screen Translator – App – v0.9.0
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Languages
struct LanguagesView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @State private var query = ""

    private func name(_ code: String) -> String {
        code == "auto" ? "Auto-detect" : (engine.languages.first { $0.code == code }?.name ?? code)
    }
    private var filtered: [LangItem] {
        engine.languages.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var ready: [LangItem] { filtered.filter { engine.langStatus[$0.code] == .installed } }
    private var available: [LangItem] { filtered.filter { engine.langStatus[$0.code] == .supported } }

    private var pairStatus: (text: String, color: Color) {
        if engine.sourceCode == "auto" { return ("Auto-detect identifies the source; its translation pair needs downloaded packs", .secondary) }
        switch engine.langStatus[engine.sourceCode] {
        case .installed: return ("Ready – works offline", .green)
        case .supported: return ("Needs a download", .orange)
        case .unsupported: return ("This pair isn't supported", .red)
        default: return ("Checking…", .secondary)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Text(name(engine.sourceCode)).font(.headline).frame(maxWidth: .infinity)
                            Button { engine.swapLanguages(); engine.tap() } label: {
                                Image(systemName: "arrow.left.arrow.right")
                                    .frame(width: 36, height: 36)
                                    .background(Theme.cardStrong, in: Circle())
                            }
                            .buttonStyle(.plain)
                            Text(name(engine.targetCode)).font(.headline).frame(maxWidth: .infinity)
                        }
                        Text(pairStatus.text).font(.footnote).foregroundStyle(pairStatus.color)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Current pair")
                } footer: {
                    Text("Tap a language to translate from it. Press and hold for more options.")
                }

                if engine.langStatus.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                if !ready.isEmpty {
                    Section("Ready · works offline (\(ready.count))") {
                        ForEach(ready) { l in row(l, ready: true) }
                    }
                }
                if !available.isEmpty {
                    Section("Available to download (\(available.count))") {
                        ForEach(available) { l in row(l, ready: false) }
                    }
                }
                if !engine.downloadMessage.isEmpty {
                    Section("Download status") { Text(engine.downloadMessage).font(.footnote) }
                }
                Section {
                    Text("Translation runs fully on your phone with Apple's language packs. The packs are stored by iOS, not by this app, and are shared with the Translate app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .searchable(text: $query, prompt: "Search languages")
            .navigationTitle("Languages")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await engine.refreshStatus() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh")
                }
            }
        }
    }

    private func row(_ l: LangItem, ready: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(l.name)
                HStack(spacing: 6) {
                    if l.code == engine.sourceCode { badge("FROM") }
                    if l.code == engine.targetCode { badge("TO") }
                }
            }
            Spacer()
            if ready {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Get") { engine.download(l.code); engine.tap() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            engine.sourceCode = l.code
            engine.tap()
            engine.toast("Translating from \(l.name)")
        }
        .contextMenu {
            Button { engine.sourceCode = l.code; engine.toast("Translating from \(l.name)") } label: {
                Label("Translate from \(l.name)", systemImage: "arrow.right.circle")
            }
            Button { engine.targetCode = l.code; engine.toast("Translating into \(l.name)") } label: {
                Label("Translate into \(l.name)", systemImage: "arrow.left.circle")
            }
            if !ready {
                Button { engine.download(l.code) } label: { Label("Download pack", systemImage: "arrow.down.circle") }
            }
        }
    }

    private func badge(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 9, weight: .heavy))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.accent.start.opacity(0.3), in: Capsule())
    }
}

// MARK: - History
struct HistoryView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @State private var query = ""
    @State private var onlyStarred = false
    @State private var selection: Set<UUID> = []
    @State private var confirmDelete = false
    @State private var importing = false
    @State private var lastSevenDays = false

    private var items: [HistoryItem] {
        engine.history.filter { h in
            (!onlyStarred || h.starred)
                && (!lastSevenDays || h.date >= Date().addingTimeInterval(-7 * 86400))
                && (query.isEmpty || h.original.localizedCaseInsensitiveContains(query)
                    || h.translated.localizedCaseInsensitiveContains(query)
                    || (h.note ?? "").localizedCaseInsensitiveContains(query))
        }
    }
    private var exportItems: [HistoryItem] { selection.isEmpty ? items : items.filter { selection.contains($0.id) } }
    private var groups: [(day: Date, items: [HistoryItem])] {
        Dictionary(grouping: items, by: { Calendar.current.startOfDay(for: $0.date) })
            .map { (day: $0.key, items: $0.value) }.sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                if !engine.history.isEmpty {
                    Section {
                        HStack {
                            Label("\(items.count) translations", systemImage: "text.bubble")
                            Spacer()
                            Text("\(engine.history.filter(\.starred).count) saved").foregroundStyle(.secondary)
                        }.font(.subheadline)
                    }
                }
                ForEach(groups, id: \.day) { group in
                    Section(group.day.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(group.items) { item in
                            NavigationLink { HistoryDetail(item: item).environmentObject(engine) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .top) {
                                        Text(item.translated).font(.body.weight(.medium)).lineLimit(3)
                                        Spacer()
                                        if item.starred { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                                    }
                                    Text(item.original).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    HStack {
                                        Text(item.date.formatted(date: .omitted, time: .shortened))
                                        if let from = item.sourceLanguage, let to = item.targetLanguage { Text("· \(from.uppercased()) → \(to.uppercased())") }
                                    }.font(.caption2).foregroundStyle(.tertiary)
                                }.padding(.vertical, 5)
                            }.tag(item.id)
                            .swipeActions(edge: .leading) {
                                Button { engine.toggleStar(item.id) } label: { Label("Save", systemImage: item.starred ? "star.slash" : "star") }.tint(.yellow)
                            }
                            .swipeActions {
                                Button(role: .destructive) { engine.deleteHistory(ids: [item.id]) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .overlay { if items.isEmpty { ContentUnavailableView(query.isEmpty ? "Your translation library" : "No matching translations", systemImage: "text.book.closed", description: Text("Translations appear here unless a private session is enabled.")) } }
            .scrollContentBackground(.hidden).background(Theme.bg.ignoresSafeArea())
            .searchable(text: $query, prompt: "Search original, translation or notes")
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Export text") { Sharer.shareFile(text: exportItems.map { "\($0.original)\n→ \($0.translated)" }.joined(separator: "\n\n"), name: "screenlingo-history.txt") }
                        Button("Export CSV") { Sharer.shareFile(text: engine.historyCSV(exportItems), name: "screenlingo-history.csv") }
                        Button("Export JSON backup") { Sharer.shareFile(text: engine.historyJSON(exportItems), name: "screenlingo-history.json") }
                        Button("Restore JSON backup") { importing = true }
                    } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Export or restore library")
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Only saved", isOn: $onlyStarred)
                        Toggle("Last 7 days", isOn: $lastSevenDays)
                        Button("Undo last deletion") { engine.undoHistoryDeletion() }
                        Button(selection.isEmpty ? "Delete visible unstarred entries" : "Delete selected entries", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "line.3.horizontal.decrease") }.accessibilityLabel("Library filters and actions")
                }
            }
            .confirmationDialog("Delete these translations? You can undo the last deletion during this app session.", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    let ids = selection.isEmpty ? Set(items.filter { !$0.starred }.map(\.id)) : selection
                    engine.deleteHistory(ids: ids); selection = []
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let success = engine.importHistory(try Data(contentsOf: url))
                    engine.toast(success ? "Library restored" : "This is not a valid ScreenLingo backup")
                } catch { engine.toast("Could not open backup") }
            }
        }
    }
}

struct HistoryDetail: View {
    @EnvironmentObject private var engine: TranslatorEngine
    let item: HistoryItem
    @State private var note: String
    init(item: HistoryItem) { self.item = item; _note = State(initialValue: item.note ?? "") }
    private var current: HistoryItem { engine.history.first { $0.id == item.id } ?? item }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(current.translated).font(.title2.weight(.medium)).textSelection(.enabled)
                Divider()
                Text(current.original).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button { engine.toggleStar(item.id) } label: { Label(current.starred ? "Saved" : "Save", systemImage: current.starred ? "star.fill" : "star") }
                    Button { engine.speak(current.translated) } label: { Label("Listen", systemImage: "speaker.wave.2") }
                    ShareLink(item: current.translated) { Image(systemName: "square.and.arrow.up") }
                }.buttonStyle(.bordered)
                VStack(alignment: .leading) {
                    Text("Personal note").font(.headline)
                    TextField("Add context or vocabulary…", text: $note, axis: .vertical).lineLimit(3...8)
                }.card()
                Button("Share translation card") { Sharer.shareImage(engine.image(for: current)) }.buttonStyle(.bordered)
                Text(current.date.formatted()).font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.background(Theme.bg.ignoresSafeArea()).navigationTitle("Translation").navigationBarTitleDisplayMode(.inline)
            .onChange(of: note) { _, value in
                if let index = engine.history.firstIndex(where: { $0.id == item.id }) { engine.history[index].note = String(value.prefix(2000)) }
            }
    }
}
