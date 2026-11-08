// ScreenLingo – App
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
                          "rapidTextTracking": true, "joinAdjacentText": true, "activeTextFocus": true,
                          "clearHold": 2.0, "minDisplay": 0.0, "showOriginal": true], builtIn: true),
        Preset(id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!, name: "Movie", symbol: "film", colorIndex: 0,
               settings: ["mode": "movie", "area": "smart", "speed": "balanced", "stability": 2,
                          "rapidTextTracking": true, "joinAdjacentText": true, "activeTextFocus": true,
                          "clearHold": 1.0, "minDisplay": 0.0], builtIn: true),
        Preset(id: UUID(uuidString: "11111111-0000-0000-0000-000000000002")!, name: "Game", symbol: "gamecontroller", colorIndex: 4,
               settings: ["mode": "game", "area": "full", "speed": "fast", "stability": 1,
                          "rapidTextTracking": false, "joinAdjacentText": false, "activeTextFocus": false,
                          "clearHold": 0.5, "minDisplay": 0.0], builtIn: true),
        Preset(id: UUID(uuidString: "11111111-0000-0000-0000-000000000003")!, name: "Comic", symbol: "book", colorIndex: 3,
               settings: ["mode": "comic", "area": "full", "speed": "sharp", "stability": 2,
                          "rapidTextTracking": false, "joinAdjacentText": false, "activeTextFocus": false,
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
        let legacyOptions = PresetRecognitionPolicy.legacyDefaults(
            for: p.settings["mode"] as? String ?? ud.string(forKey: "mode") ?? "movie")
        for k in TranslatorEngine.presetKeys {
            if p.builtIn && p.settings[k] == nil { continue }
            if (k == "source" || k == "target") && p.settings[k] == nil { continue }
            let cur = ud.object(forKey: k) ?? TranslatorEngine.defaults[k]
            let want = p.settings[k] ?? legacyOptions[k] ?? TranslatorEngine.defaults[k]
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
        // Old custom profiles predate these switches. Preserve their exact
        // prior Movie/Game/Comic behavior on import or reapplication.
        let legacyOptions = PresetRecognitionPolicy.legacyDefaults(
            for: p.settings["mode"] as? String ?? ud.string(forKey: "mode") ?? "movie")
        for k in TranslatorEngine.presetKeys {
            let isLanguage = (k == "source" || k == "target")
            if let v = p.settings[k] {
                ud.set(v, forKey: k)
            } else if let inherited = legacyOptions[k] {
                ud.set(inherited, forKey: k)
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

/// The two language codes the editor mentions. Equatable, so the editor redraws only when the pair changes.
struct PresetLanguageFacts: Equatable {
    var source: String
    var target: String
    @MainActor static func read(_ e: TranslatorEngine) -> PresetLanguageFacts { PresetLanguageFacts(source: e.sourceCode, target: e.targetCode) }
}

struct PresetEditor: View {
    @EngineHandle private var engine
    @EngineFacts(PresetLanguageFacts.read) private var pair
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
                    VStack(spacing: KitSpace.row) {
                        // The chip exactly as it will appear on Translate, updating while you choose.
                        HStack(spacing: KitSpace.unit + 2) {
                            Image(systemName: symbol)
                            Text(name.isEmpty ? "Scene" : name).lineLimit(1)
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, KitSpace.row)
                        .frame(minHeight: 44)
                        .foregroundStyle(.white)
                        .background(PresetStore.palette[colorIndex], in: Capsule())
                        .accessibilityLabel("Preview of the scene chip")
                        CaptionPreview()
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section("Name") {
                    TextField("Scene name", text: $name).frame(minHeight: 44)
                }
                Section("Icon") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: KitSpace.tight) {
                            ForEach(PresetStore.symbols, id: \.self) { s in
                                Button { symbol = s } label: {
                                    Image(systemName: s)
                                        .font(.title3)
                                        .frame(width: 44, height: 44)
                                        .foregroundStyle(symbol == s ? Color.white : Color.secondary)
                                        .background(symbol == s ? PresetStore.palette[colorIndex] : Color.clear, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(s.replacingOccurrences(of: ".", with: " "))
                                .accessibilityAddTraits(symbol == s ? .isSelected : [])
                            }
                        }
                    }
                }
                Section("Colour") {
                    HStack(spacing: KitSpace.tight) {
                        ForEach(0..<PresetStore.palette.count, id: \.self) { i in
                            Button { colorIndex = i } label: {
                                Image(systemName: colorIndex == i ? "checkmark.circle.fill" : "circle.fill")
                                    .font(.title)
                                    .foregroundStyle(PresetStore.palette[i])
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Colour \(i + 1)")
                            .accessibilityAddTraits(colorIndex == i ? .isSelected : [])
                        }
                    }
                }
                Section {
                    Toggle("Remember languages", isOn: $includeLanguages)
                } footer: {
                    Text(editingID == nil
                         ? "Saves your current reading, rules, floating-window look and other behaviour settings. With languages on, it also switches to \(pair.source.uppercased()) → \(pair.target.uppercased())."
                         : "With languages on, applying this scene switches to \(pair.source.uppercased()) → \(pair.target.uppercased()).")
                }
            }
            .kitPage()
            .navigationTitle(editingID == nil ? "New scene" : "Edit scene")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let id = editingID {
                            store.edit(id, name: name, symbol: symbol, colorIndex: colorIndex, includeLanguages: includeLanguages)
                            engine.toast("Scene updated")
                        } else {
                            store.add(name: name, symbol: symbol, colorIndex: colorIndex, includeLanguages: includeLanguages)
                            engine.toast("Scene saved")
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                switch mode {
                case .new:
                    name = "My scene \(store.custom.count + 1)"
                case .edit(let p):
                    name = p.name; symbol = p.symbol; colorIndex = p.colorIndex; includeLanguages = p.includesLanguages
                }
            }
        }
    }
}

// MARK: - Manager page
struct PresetManagerView: View {
    @EngineHandle private var engine
    @ObservedObject var store: PresetStore
    @State private var editor: PresetEditorMode?
    @State private var pendingDelete: Preset?

    var body: some View {
        List {
            Section {
                Button { editor = .new } label: { Label("Save current settings as a scene", systemImage: "plus.circle.fill") }
                    .frame(minHeight: 44)
            } footer: {
                Text("Tap a scene to apply it. Press and hold for Edit, Duplicate, Use at start-up and Delete.")
            }
            Section("Built-in") { ForEach(PresetStore.builtIns) { row($0) } }
            Section("Yours") {
                if store.custom.isEmpty {
                    Text("Set things up the way you like, then save them as a scene.").foregroundStyle(.secondary)
                }
                ForEach(store.custom) { row($0) }
            }
            Section {
                Picker("Apply when the app opens", selection: Binding(get: { store.startupID }, set: { store.startupID = $0 })) {
                    Text("Nothing").tag(String?.none)
                    ForEach(store.all) { Text($0.name).tag(Optional($0.id.uuidString)) }
                }
            } header: { Text("Start-up") }
            Section {
                Button { Sharer.shareFile(text: store.exportJSON(), name: "screen-translator-presets.json") } label: {
                    Label("Share scenes", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = store.exportJSON()
                    engine.toast("Scenes copied")
                } label: { Label("Copy as text", systemImage: "doc.on.doc") }
                Button {
                    let n = store.importJSON(UIPasteboard.general.string ?? "")
                    engine.toast(n > 0 ? "Imported \(n) scene\(n == 1 ? "" : "s")" : "The clipboard has no exported scenes")
                } label: { Label("Import from clipboard", systemImage: "square.and.arrow.down") }
            } header: { Text("Share and backup") } footer: {
                Text("Use this to move scenes to another phone or keep them after reinstalling.")
            }
        }
        .kitPage()
        .navigationTitle("Scenes")
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $editor) { PresetEditor(store: store, mode: $0).environmentObject(engine) }
        .confirmationDialog("Delete this scene?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { scene in
            Button("Delete \(scene.name)", role: .destructive) { store.delete(scene.id) }
        }
    }

    private func row(_ p: Preset) -> some View {
        let isActive = store.activeID == p.id.uuidString
        return Button {
            store.apply(p)
            engine.tap()
            engine.toast("\(p.name) applied")
        } label: {
            HStack(spacing: KitSpace.row) {
                Image(systemName: p.symbol)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(p.color, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: KitSpace.unit) {
                        Text(p.name).font(.headline)
                        if store.startupID == p.id.uuidString {
                            Image(systemName: "power").font(.footnote).foregroundStyle(.secondary).accessibilityLabel("Used at start-up")
                        }
                    }
                    Text(isActive ? (store.isModified ? "Active · changed" : "Active") : PresetStore.summary(p))
                        .font(.footnote)
                        .foregroundStyle(isActive ? (store.isModified ? Color.orange : Color.accentColor) : Color.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: KitSpace.tight)
                CaptionPreview(themeOverride: p.settings["theme"] as? String, compact: true)
                    .frame(width: 72)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .contextMenu {
            if !p.builtIn {
                Button { editor = .edit(p) } label: { Label("Edit…", systemImage: "pencil") }
            }
            Button { _ = store.duplicate(p) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button {
                store.startupID = (store.startupID == p.id.uuidString) ? nil : p.id.uuidString
            } label: {
                Label(store.startupID == p.id.uuidString ? "Don't use at start-up" : "Use at start-up", systemImage: "power")
            }
            if !p.builtIn {
                Button(role: .destructive) { pendingDelete = p } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .accessibilityHint("Applies this scene")
    }
}
