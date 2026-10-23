// Screen Translator – App – v0.9.0
import SwiftUI

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
        if engine.sourceCode == "auto" { return ("Auto-detect uses any language you've downloaded", .secondary) }
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
    @State private var shareItem: ShareItem?

    private var items: [HistoryItem] {
        engine.history.filter { h in
            (!onlyStarred || h.starred)
                && (query.isEmpty || h.original.localizedCaseInsensitiveContains(query)
                    || h.translated.localizedCaseInsensitiveContains(query))
        }
    }

    private var groups: [(day: Date, items: [HistoryItem])] {
        Dictionary(grouping: items, by: { Calendar.current.startOfDay(for: $0.date) })
            .map { (day: $0.key, items: $0.value) }
            .sorted { $0.day > $1.day }
    }

    private func dayTitle(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.day) { g in
                    Section(dayTitle(g.day)) {
                        ForEach(g.items) { h in row(h) }
                    }
                }
            }
            .overlay {
                if engine.history.isEmpty {
                    ContentUnavailableView("No translations yet", systemImage: "text.bubble",
                                           description: Text("Everything that gets translated shows up here, so you can read it again."))
                } else if items.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .searchable(text: $query, prompt: "Search history")
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: engine.history.map { "\($0.original)\n→ \($0.translated)" }.joined(separator: "\n\n"))
                        .disabled(engine.history.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Only starred", isOn: $onlyStarred)
                        Button("Clear unstarred", role: .destructive) { engine.history.removeAll { !$0.starred } }
                        Button("Clear everything", role: .destructive) { engine.history.removeAll() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(item: $shareItem) { ActivityView(items: [$0.image]) }
        }
    }

    private func row(_ h: HistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Text(h.translated).font(.body.weight(.semibold))
                Spacer(minLength: 8)
                if h.starred { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            }
            Text(h.original).font(.caption).foregroundStyle(.secondary)
            Text(h.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            UIPasteboard.general.string = h.translated
            engine.tap()
            engine.toast("Copied")
        }
        .swipeActions(edge: .leading) {
            Button { engine.toggleStar(h.id) } label: { Label("Star", systemImage: h.starred ? "star.slash" : "star") }
                .tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { engine.history.removeAll { $0.id == h.id } } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button { UIPasteboard.general.string = h.translated; engine.toast("Copied translation") } label: {
                Label("Copy translation", systemImage: "doc.on.doc")
            }
            Button { UIPasteboard.general.string = h.original; engine.toast("Copied original") } label: {
                Label("Copy original", systemImage: "doc.on.doc.fill")
            }
            Button { shareItem = ShareItem(image: engine.image(for: h)) } label: {
                Label("Share as image", systemImage: "photo")
            }
            Button { engine.toggleStar(h.id) } label: {
                Label(h.starred ? "Remove star" : "Star", systemImage: h.starred ? "star.slash" : "star")
            }
            Button(role: .destructive) { engine.history.removeAll { $0.id == h.id } } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
