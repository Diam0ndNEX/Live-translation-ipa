// Screen Translator – App – v0.9.0
// Custom presets: save the settings you're using, switch with one tap.
import SwiftUI

struct Preset: Identifiable {
    let id: UUID
    var name: String
    var symbol: String
    var colorIndex: Int
    var settings: [String: Any]
    var builtIn: Bool

    init(id: UUID = UUID(), name: String, symbol: String, colorIndex: Int,
         settings: [String: Any], builtIn: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colorIndex = colorIndex
        self.settings = settings
        self.builtIn = builtIn
    }

    init?(dict: [String: Any]) {
        guard let idString = dict["id"] as? String, let id = UUID(uuidString: idString),
              let name = dict["name"] as? String, let settings = dict["settings"] as? [String: Any] else { return nil }
        self.init(id: id, name: name, symbol: dict["symbol"] as? String ?? "star.fill",
                  colorIndex: dict["color"] as? Int ?? 0, settings: settings)
    }

    func toDict() -> [String: Any] {
        ["id": id.uuidString, "name": name, "symbol": symbol, "color": colorIndex, "settings": settings]
    }

    var includesLanguages: Bool { settings["source"] != nil || settings["target"] != nil }
    var color: Color { PresetStore.palette[max(0, min(colorIndex, PresetStore.palette.count - 1))] }
}

@MainActor
final class PresetStore: ObservableObject {
    static let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .red, .indigo]
    static let symbols = ["film", "gamecontroller", "book", "star.fill", "bolt.fill", "moon.fill", "sun.max.fill",
                          "tv", "music.note", "graduationcap.fill", "globe", "heart.fill", "flame.fill", "leaf.fill",
                          "paintpalette.fill", "briefcase.fill", "airplane", "cart.fill"]

    static let builtIns: [Preset] = [
        Preset(id: UUID(uuidString: "11111111-0000-0000-0000-000000000004")!, name: "Lyrics", symbol: "music.note", colorIndex: 1,
               settings: ["mode": "movie", "area": "full", "speed": "balanced", "stability": 2,
                          "clearHold": 2.0, "minDisplay": 0.0, "showOriginal": true], builtIn: true),
        Preset(id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!, name: "Movie", symbol: "film", colorIndex: 0,
               settings: ["mode": "movie", "area": "smart", "speed": "balanced", "stability": 2,
                          "clearHold": 1.0, "minDisplay": 0.0], builtIn: true),
        Preset(id: UUID(uuidString: "11111111-0000-0000-0000-000000000002")!, name: "Game", symbol: "gamecontroller", colorIndex: 4,
               settings: ["mode": "game", "area": "full", "speed": "fast", "stability": 1,
                          "clearHold": 0.5, "minDisplay": 0.0], builtIn: true),
        Preset(id: UUID(uuidString: "11111111-0000-0000-0000-000000000003")!, name: "Comic", symbol: "book", colorIndex: 3,
               settings: ["mode": "comic", "area": "full", "speed": "sharp", "stability": 2,
                          "clearHold": 3.0, "minDisplay": 1.5], builtIn: true)
    ]

    @Published private(set) var custom: [Preset] = []
    @Published var activeID: String? = nil { didSet { UserDefaults.standard.set(activeID, forKey: "activePreset") } }
    @Published var startupID: String? = nil { didSet { UserDefaults.standard.set(startupID, forKey: "startupPreset") } }
    var onApplied: (() -> Void)?
    private var ud: UserDefaults { .standard }
    private var observer: NSObjectProtocol?

    init() {
        activeID = UserDefaults.standard.string(forKey: "activePreset")
        startupID = UserDefaults.standard.string(forKey: "startupPreset")
        load()
        // Settings live in UserDefaults; refresh whenever they change so "modified" stays accurate.
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    var all: [Preset] { Self.builtIns + custom }
    var active: Preset? {
        guard let id = activeID else { return nil }
        return all.first { $0.id.uuidString == id }
    }
    var isModified: Bool {
        guard let a = active else { return false }
        return !matches(a)
    }

    // MARK: Comparing with the current settings
    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a, let b else { return false }
        if let x = a as? NSNumber, let y = b as? NSNumber { return abs(x.doubleValue - y.doubleValue) < 0.0001 }
        return "\(a)" == "\(b)"
    }

    func matches(_ p: Preset) -> Bool {
        for k in TranslatorEngine.presetKeys {
            if p.builtIn && p.settings[k] == nil { continue }
            if (k == "source" || k == "target") && p.settings[k] == nil { continue }
            let cur = ud.object(forKey: k) ?? TranslatorEngine.defaults[k]
            let want = p.settings[k] ?? TranslatorEngine.defaults[k]
            if !Self.same(cur, want) { return false }
        }
        return true
    }

    func snapshot(includeLanguages: Bool) -> [String: Any] {
        var s: [String: Any] = [:]
        for k in TranslatorEngine.presetKeys {
            if k == "source" || k == "target" { continue }
            if let v = ud.object(forKey: k) { s[k] = v }
        }
        if includeLanguages {
            s["source"] = ud.string(forKey: "source") ?? "auto"
            s["target"] = ud.string(forKey: "target") ?? "en"
        }
        return s
    }

    // MARK: Actions
    func apply(_ p: Preset) {
        for k in TranslatorEngine.presetKeys {
            let isLanguage = (k == "source" || k == "target")
            if let v = p.settings[k] {
                ud.set(v, forKey: k)
            } else if !p.builtIn && !isLanguage {
                ud.removeObject(forKey: k)
            }
        }
        if p.settings["displayPolicy"] == nil, let minimum = p.settings["minDisplay"] as? Double {
            ud.set(PresentationSchedule.inferredPolicy(saved: nil, minimum: minimum), forKey: "displayPolicy")
        }
        activeID = p.id.uuidString
        onApplied?()
    }

    func applyStartup() {
        guard let id = startupID, let p = all.first(where: { $0.id.uuidString == id }) else { return }
        apply(p)
    }

    @discardableResult
    func add(name: String, symbol: String, colorIndex: Int, includeLanguages: Bool) -> Preset {
        let n = name.trimmingCharacters(in: .whitespaces)
        let p = Preset(name: n.isEmpty ? "My preset" : n, symbol: symbol, colorIndex: colorIndex,
                       settings: snapshot(includeLanguages: includeLanguages))
        custom.append(p)
        persist()
        activeID = p.id.uuidString
        return p
    }

    /// Overwrites a preset with the settings you're using right now.
    func updateSettings(_ id: UUID) {
        guard let i = custom.firstIndex(where: { $0.id == id }) else { return }
        custom[i].settings = snapshot(includeLanguages: custom[i].includesLanguages)
        persist()
        activeID = id.uuidString
    }

    func edit(_ id: UUID, name: String, symbol: String, colorIndex: Int, includeLanguages: Bool) {
        guard let i = custom.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        custom[i].name = n.isEmpty ? custom[i].name : n
        custom[i].symbol = symbol
        custom[i].colorIndex = colorIndex
        let had = custom[i].includesLanguages
        if includeLanguages && !had {
            custom[i].settings["source"] = ud.string(forKey: "source") ?? "auto"
            custom[i].settings["target"] = ud.string(forKey: "target") ?? "en"
        } else if !includeLanguages && had {
            custom[i].settings["source"] = nil
            custom[i].settings["target"] = nil
        }
        persist()
    }

    @discardableResult
    func duplicate(_ p: Preset) -> Preset {
        var settings = p.builtIn ? snapshot(includeLanguages: false) : p.settings
        if p.builtIn { for (k, v) in p.settings { settings[k] = v } }
        let copy = Preset(name: p.name + " copy", symbol: p.symbol, colorIndex: p.colorIndex, settings: settings)
        custom.append(copy)
        persist()
        return copy
    }

    func delete(_ id: UUID) {
        custom.removeAll { $0.id == id }
        if activeID == id.uuidString { activeID = nil }
        if startupID == id.uuidString { startupID = nil }
        persist()
    }

    func move(from: IndexSet, to: Int) {
        custom.move(fromOffsets: from, toOffset: to)
        persist()
    }

    // MARK: Storage
    private func persist() {
        if let d = try? JSONSerialization.data(withJSONObject: custom.map { $0.toDict() }) { ud.set(d, forKey: "presets") }
    }

    private func load() {
        var list: [Preset] = []
        if let d = ud.data(forKey: "presets"),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            list = arr.compactMap { Preset(dict: $0) }
        }
        // Profiles saved by v0.8 become presets once.
        if ud.object(forKey: "profilesMigrated") == nil {
            if let d = ud.data(forKey: "profiles"),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]] {
                for (name, snap) in o.sorted(by: { $0.key < $1.key }) {
                    list.append(Preset(name: name, symbol: "star.fill", colorIndex: 1,
                                       settings: snap.filter { TranslatorEngine.presetKeys.contains($0.key) }))
                }
            }
            ud.set(true, forKey: "profilesMigrated")
            custom = list
            persist()
        }
        custom = list
    }

    func exportJSON() -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: custom.map { $0.toDict() },
                                                  options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }

    func importJSON(_ text: String) -> Int {
        guard let d = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return 0 }
        var n = 0
        for dict in arr {
            guard let p = Preset(dict: dict) else { continue }
            custom.append(Preset(name: p.name, symbol: p.symbol, colorIndex: p.colorIndex, settings: p.settings))
            n += 1
        }
        persist()
        return n
    }

    static func summary(_ p: Preset) -> String {
        let s = p.settings
        var parts: [String] = []
        if let m = s["mode"] as? String, let v = TranslateMode(rawValue: m) { parts.append(v.title) }
        if let a = s["area"] as? String, let v = OCRArea(rawValue: a) { parts.append(v.title) }
        if let sp = s["speed"] as? String, let v = SpeedPreset(rawValue: sp) { parts.append(v.title) }
        if let src = s["source"] as? String, let tgt = s["target"] as? String { parts.append("\(src.uppercased()) → \(tgt.uppercased())") }
        if let t = s["theme"] as? String, let v = PiPTheme(rawValue: t) { parts.append(v.title) }
        parts.append("\(s.count) settings")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Home carousel
struct PresetChips: View {
    @EnvironmentObject var engine: TranslatorEngine
    @ObservedObject var store: PresetStore
    var onNew: () -> Void
    var onEdit: (Preset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Presets").font(.subheadline.weight(.semibold))
                Spacer()
                NavigationLink { PresetManagerView(store: store) } label: {
                    Text("Manage").font(.caption.weight(.semibold))
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.all) { p in chip(p) }
                    Button(action: onNew) {
                        Label("Save current", systemImage: "plus")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .foregroundStyle(.secondary)
                            .overlay(Capsule().stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                }
            }
            if let a = store.active, store.isModified {
                HStack(spacing: 10) {
                    Text("\(a.name) has unsaved changes").font(.caption2).foregroundStyle(.orange)
                    Spacer()
                    if !a.builtIn {
                        Button("Update") {
                            store.updateSettings(a.id)
                            engine.toast("\(a.name) updated")
                            engine.tap()
                        }
                        .font(.caption2.weight(.bold))
                    }
                    Button("Save as new", action: onNew).font(.caption2.weight(.bold))
                }
            }
        }
    }

    private func chip(_ p: Preset) -> some View {
        let isActive = store.activeID == p.id.uuidString
        return Button {
            store.apply(p)
            engine.tap()
            engine.toast("\(p.name) applied")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: p.symbol).font(.system(size: 13, weight: .semibold))
                Text(p.name).font(.footnote.weight(.semibold)).lineLimit(1)
                if isActive && store.isModified { Circle().fill(Color.orange).frame(width: 7, height: 7) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .foregroundStyle(Color.white)
            .background(isActive ? p.color.opacity(0.85) : Theme.card, in: Capsule())
            .overlay(Capsule().stroke(p.color.opacity(isActive ? 0 : 0.55), lineWidth: 1))
        }
        .contextMenu {
            if !p.builtIn && isActive && store.isModified {
                Button { store.updateSettings(p.id); engine.toast("\(p.name) updated") } label: {
                    Label("Update with current settings", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if !p.builtIn {
                Button { onEdit(p) } label: { Label("Edit…", systemImage: "pencil") }
            }
            Button { store.duplicate(p); engine.toast("Duplicated \(p.name)") } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button {
                store.startupID = (store.startupID == p.id.uuidString) ? nil : p.id.uuidString
            } label: {
                Label(store.startupID == p.id.uuidString ? "Don't use at start-up" : "Use at start-up", systemImage: "power")
            }
            if !p.builtIn {
                Button(role: .destructive) { store.delete(p.id) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }
}

// MARK: - Create / edit
enum PresetEditorMode: Identifiable {
    case new
    case edit(Preset)
    var id: String {
        switch self {
        case .new: "new"
        case .edit(let p): p.id.uuidString
        }
    }
}

struct PresetEditor: View {
    @EnvironmentObject var engine: TranslatorEngine
    @ObservedObject var store: PresetStore
    let mode: PresetEditorMode
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "star.fill"
    @State private var colorIndex = 0
    @State private var includeLanguages = false

    private var editingID: UUID? {
        if case .edit(let p) = mode { return p.id }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: symbol)
                            .font(.title2).foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(PresetStore.palette[colorIndex], in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        TextField("Preset name", text: $name)
                            .font(.title3.weight(.semibold))
                    }
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                        ForEach(PresetStore.symbols, id: \.self) { s in
                            Button { symbol = s } label: {
                                Image(systemName: s)
                                    .font(.system(size: 18))
                                    .frame(width: 40, height: 40)
                                    .foregroundStyle(symbol == s ? Color.white : Color.secondary)
                                    .background(symbol == s ? PresetStore.palette[colorIndex] : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Colour") {
                    HStack(spacing: 12) {
                        ForEach(0..<PresetStore.palette.count, id: \.self) { i in
                            Circle().fill(PresetStore.palette[i])
                                .frame(width: 30, height: 30)
                                .overlay(Circle().stroke(Color.white, lineWidth: colorIndex == i ? 3 : 0))
                                .onTapGesture { colorIndex = i }
                        }
                    }
                }
                Section {
                    Toggle("Remember languages", isOn: $includeLanguages)
                } footer: {
                    Text("When on, applying this preset also switches to \(engine.sourceCode.uppercased()) → \(engine.targetCode.uppercased()).")
                }
                if editingID == nil {
                    Section {
                        Text("Saves your current reading options, rules, floating-window look and every other behaviour setting.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } header: {
                        Text("What gets saved")
                    }
                }
            }
            .navigationTitle(editingID == nil ? "New preset" : "Edit preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        if let id = editingID {
                            store.edit(id, name: name, symbol: symbol, colorIndex: colorIndex, includeLanguages: includeLanguages)
                            engine.toast("Preset updated")
                        } else {
                            store.add(name: name, symbol: symbol, colorIndex: colorIndex, includeLanguages: includeLanguages)
                            engine.toast("Preset saved")
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                switch mode {
                case .new:
                    name = "My preset \(store.custom.count + 1)"
                case .edit(let p):
                    name = p.name; symbol = p.symbol; colorIndex = p.colorIndex; includeLanguages = p.includesLanguages
                }
            }
        }
    }
}

// MARK: - Manager page
struct PresetManagerView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @ObservedObject var store: PresetStore
    @State private var editor: PresetEditorMode?
    @State private var message = ""

    var body: some View {
        List {
            Section {
                Button { editor = .new } label: {
                    Label("Save current settings as a new preset", systemImage: "plus.circle.fill")
                }
            } footer: {
                Text("Tap a preset to apply it. Swipe right to edit, swipe left to duplicate or delete. Drag to reorder with Edit.")
            }

            Section("Built-in") {
                ForEach(PresetStore.builtIns) { p in row(p) }
            }

            Section("Your presets") {
                if store.custom.isEmpty {
                    Text("None yet. Set things up the way you like, then save them above.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(store.custom) { p in row(p) }
                    .onMove { store.move(from: $0, to: $1) }
                    .onDelete { idx in
                        let ids = idx.map { store.custom[$0].id }
                        ids.forEach { store.delete($0) }
                    }
            }

            Section {
                Picker("Apply when the app opens", selection: Binding(get: { store.startupID },
                                                                      set: { store.startupID = $0 })) {
                    Text("Nothing").tag(String?.none)
                    ForEach(store.all) { Text($0.name).tag(Optional($0.id.uuidString)) }
                }
            } header: {
                Text("Start-up")
            }

            Section {
                Button { Sharer.shareFile(text: store.exportJSON(), name: "screen-translator-presets.json") } label: {
                    Label("Share my presets", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = store.exportJSON()
                    message = "Presets copied to the clipboard."
                } label: { Label("Copy my presets", systemImage: "doc.on.doc") }
                Button {
                    let n = store.importJSON(UIPasteboard.general.string ?? "")
                    message = n > 0 ? "Imported \(n) preset\(n == 1 ? "" : "s")." : "The clipboard doesn't contain exported presets."
                } label: { Label("Import presets from clipboard", systemImage: "square.and.arrow.down") }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Share & backup")
            } footer: {
                Text("Export, copy the text, and import it on another phone or after reinstalling.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Presets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(item: $editor) { PresetEditor(store: store, mode: $0).environmentObject(engine) }
    }

    private func row(_ p: Preset) -> some View {
        let isActive = store.activeID == p.id.uuidString
        return HStack(spacing: 12) {
            Image(systemName: p.symbol)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(p.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.name).font(.body.weight(.semibold))
                    if store.startupID == p.id.uuidString {
                        Image(systemName: "power").font(.caption2).foregroundStyle(.secondary)
                    }
                    if isActive {
                        Text(store.isModified ? "ACTIVE · MODIFIED" : "ACTIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(store.isModified ? Color.orange : Color.green)
                    }
                }
                Text(PresetStore.summary(p)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.apply(p)
            engine.tap()
            engine.toast("\(p.name) applied")
        }
        .swipeActions(edge: .trailing) {
            if !p.builtIn {
                Button(role: .destructive) { store.delete(p.id) } label: { Label("Delete", systemImage: "trash") }
            }
            Button { store.duplicate(p) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .tint(.blue)
        }
        .swipeActions(edge: .leading) {
            if !p.builtIn {
                Button { editor = .edit(p) } label: { Label("Edit", systemImage: "pencil") }.tint(.orange)
            }
        }
    }
}
