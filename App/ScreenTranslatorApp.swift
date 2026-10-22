// ScreenLingo – App UI – v0.7.0
import SwiftUI
import ReplayKit
import Translation
import UniformTypeIdentifiers


/// Small UTF-8 document used by the native Files export sheet.
struct HistoryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .commaSeparatedText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = value
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

@main
struct ScreenLingoApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}

// MARK: - Theme
enum Theme {
    static let bg = Color(red: 0.025, green: 0.035, blue: 0.065)
    static let card = Color.white.opacity(0.07)
    static let gradient = LinearGradient(
        colors: [Color(red: 0.12, green: 0.82, blue: 0.72), Color(red: 0.22, green: 0.48, blue: 1)],
        startPoint: .leading, endPoint: .trailing)
}

extension View {
    func card() -> some View {
        self.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Root
struct RootView: View {
    @StateObject private var engine = TranslatorEngine()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }
            LanguagesView().tabItem { Label("Languages", systemImage: "globe") }
            HistoryView().tabItem { Label("History", systemImage: "clock") }
            DiagnosticsView().tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .environmentObject(engine)
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.12, green: 0.82, blue: 0.72))
        .translationTask(engine.legacyConfig) { session in await engine.runLegacy(session) }
        .translationTask(engine.downloadConfig) { session in await engine.runDownload(session) }
        .task { await engine.loadLanguages() }
        .onChange(of: phase) { _, p in if p == .active { engine.server.start() } }
    }
}

// MARK: - Broadcast picker
struct BroadcastPicker: UIViewRepresentable {
    var onTap: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        v.preferredExtension = Self.extensionID()
        v.showsMicrophoneButton = false
        v.tintColor = .white
        context.coordinator.onTap = onTap
        context.coordinator.attach(to: v)
        return v
    }
    func updateUIView(_ v: RPSystemBroadcastPickerView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.attach(to: v)
    }

    /// Also listens to the picker's real button, so one genuine tap starts both PiP and capture.
    final class Coordinator: NSObject {
        var onTap: () -> Void = {}
        private weak var attached: UIControl?

        func attach(to v: UIView) {
            guard let c = Self.findControl(in: v), c !== attached else { return }
            c.addTarget(self, action: #selector(tapped), for: .touchUpInside)
            attached = c
        }
        @objc private func tapped() { onTap() }
        private static func findControl(in v: UIView) -> UIControl? {
            for s in v.subviews {
                if let c = s as? UIControl { return c }
                if let c = findControl(in: s) { return c }
            }
            return nil
        }
    }

    /// Finds the bundled .appex so it works even if a sideloader renames bundle IDs.
    static func extensionID() -> String? {
        guard let dir = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        for u in items where u.pathExtension == "appex" {
            if let id = Bundle(url: u)?.bundleIdentifier { return id }
        }
        return nil
    }
}

// MARK: - Components
struct LangMenu: View {
    @Binding var code: String
    let items: [LangItem]
    var allowAuto = false

    var label: String {
        code == "auto" ? "Auto-detect" : (items.first { $0.code == code }?.name ?? code)
    }
    var body: some View {
        Menu {
            if allowAuto { Button("Auto-detect") { code = "auto" } }
            ForEach(items) { i in Button(i.name) { code = i.code } }
        } label: {
            HStack(spacing: 4) {
                Text(label).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

struct SettingRow<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(title).font(.subheadline)
            Spacer(minLength: 8)
            content()
        }
    }
}

// MARK: - Home
struct HomeView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @AppStorage("mode") private var mode = TranslateMode.movie.rawValue
    @AppStorage("area") private var area = OCRArea.smart.rawValue
    @AppStorage("winSize") private var winSize = WindowSize.normal.rawValue
    @AppStorage("showOriginal") private var showOriginal = false
    @AppStorage("speed") private var speed = SpeedPreset.balanced.rawValue
    @AppStorage("autoClear") private var autoClear = true

    private var previewRatio: CGFloat {
        let s = (WindowSize(rawValue: winSize) ?? .normal).size
        return s.width / s.height
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                languageBar
                presetRow
                preview
                settings
                startButton
                checklist
                statusCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .onChange(of: speed) { _, _ in engine.syncConfig() }
        .onChange(of: area) { _, _ in engine.syncConfig() }
        .onChange(of: mode) { _, _ in engine.syncConfig() }
        .background(Theme.bg.ignoresSafeArea())
    }

    private var packReady: Bool {
        if engine.sourceCode == "auto" {
            return engine.languages.contains { engine.langStatus[$0.code] == .installed }
        }
        return engine.langStatus[engine.sourceCode] == .installed
    }

    private func checkRow(_ title: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(title).font(.footnote)
            Spacer()
        }
    }

    @ViewBuilder private var checklist: some View {
        if !(packReady && engine.pipActive && engine.captureAlive) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Setup").font(.caption.bold()).foregroundStyle(.secondary)
                checkRow("Language pack downloaded (Languages tab)", ok: packReady)
                checkRow("Floating window open", ok: engine.pipActive)
                checkRow("Screen capture running", ok: engine.captureAlive)
            }
            .card()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ScreenLingo").font(.title.bold())
                Text("Offline · \(AppVersion.full)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(engine.captureAlive ? Color.green : Color.gray).frame(width: 8, height: 8)
                Text(engine.captureAlive ? "Capturing" : "Idle").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.card, in: Capsule())
        }
        .padding(.top, 8)
    }

    private var languageBar: some View {
        HStack(spacing: 8) {
            LangMenu(code: $engine.sourceCode, items: engine.languages, allowAuto: true)
            Button { engine.swapLanguages() } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Theme.card, in: Circle())
            }
            .foregroundStyle(.white)
            LangMenu(code: $engine.targetCode, items: engine.languages)
        }
    }

    /// Doubles as a live preview AND keeps the PiP layer on screen (required for PiP to start).
    /// One-tap presets make the current reading setup easy to understand and restore.
    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick setup")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach([("movie", "film", "Movie"), ("game", "gamecontroller", "Game"), ("comic", "book", "Comic")], id: \\.0) { item in
                    Button {
                        engine.applyPreset(item.0)
                    } label: {
                        Label(item.2, systemImage: item.1)
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(mode == item.0 ? Theme.gradient : Theme.card,
                                        in: Capsule())
                    }
                    .foregroundStyle(.white)
                    .accessibilityLabel("\\(item.2) preset")
                }
            }
        }
    }

    private var preview: some View {
        VStack(spacing: 6) {
            PiPPreview(layer: engine.pip.displayLayer)
                .aspectRatio(previewRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08)))
            Text("Live preview of the floating window").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var settings: some View {
        VStack(spacing: 12) {
            SettingRow(icon: "film", tint: .blue, title: "Mode") {
                Picker("", selection: $mode) {
                    ForEach(TranslateMode.allCases) { item in
                            let title: String = item.title
                            let value: String = item.rawValue
                            Text(title).tag(value)
                        }
                }.pickerStyle(.menu).labelsHidden().tint(.secondary)
            }
            Divider().overlay(Color.white.opacity(0.06))
            SettingRow(icon: "viewfinder", tint: .purple, title: "OCR area") {
                Picker("", selection: $area) {
                    ForEach(OCRArea.allCases) { item in
                            let title: String = item.title
                            let value: String = item.rawValue
                            Text(title).tag(value)
                        }
                }.pickerStyle(.menu).labelsHidden().tint(.secondary)
            }
            Divider().overlay(Color.white.opacity(0.06))
            SettingRow(icon: "rectangle.expand.vertical", tint: .orange, title: "Window size") {
                Picker("", selection: $winSize) {
                    ForEach(WindowSize.allCases) { item in
                            let title: String = item.title
                            let value: String = item.rawValue
                            Text(title).tag(value)
                        }
                }
                .pickerStyle(.menu).labelsHidden().tint(.secondary)
                .onChange(of: winSize) { _, _ in engine.applyWindowSize() }
            }
            Divider().overlay(Color.white.opacity(0.06))
            SettingRow(icon: "speedometer", tint: .green, title: "Speed") {
                Picker("", selection: $speed) {
                    ForEach(SpeedPreset.allCases) { item in
                            let title: String = item.title
                            let value: String = item.rawValue
                            Text(title).tag(value)
                        }
                }.pickerStyle(.menu).labelsHidden().tint(.secondary)
            }
            Divider().overlay(Color.white.opacity(0.06))
            SettingRow(icon: "text.quote", tint: .teal, title: "Show original text") {
                Toggle("", isOn: $showOriginal).labelsHidden()
            }
            Divider().overlay(Color.white.opacity(0.06))
            SettingRow(icon: "eraser", tint: .pink, title: "Clear when text ends") {
                Toggle("", isOn: $autoClear).labelsHidden()
            }
        }
        .card()
    }

    private var startButton: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { engine.startPiP() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "rectangle.on.rectangle").font(.title2)
                        Text("Floating window").font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                VStack(spacing: 2) {
                    // Do not launch PiP on the broadcast-picker tap. iOS must first
                    // present its broadcast sheet and start the extension; starting PiP
                    // at the same moment can compete with/interrupt that transition.
                    // TranslatorEngine starts PiP after it receives the extension's first packet.
                    BroadcastPicker().frame(width: 60, height: 60)
                    Text("Start capture").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 96)
                .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if engine.pipActive {
                Button("Close floating window") { engine.pip.stop() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            } else {
                Text("Tap the broadcast icon, choose Translator Capture, then Start Broadcast. The floating window opens with it.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.captureAlive ? "Capture connected" : "Capture not connected")
                        .font(.subheadline.weight(.semibold))
                    if engine.captureAlive {
                        Text("\(engine.frames) frames · \(engine.ocrCount) text updates")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            Text(engine.status).font(.footnote).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                Button {
                    UIPasteboard.general.string = engine.translated
                    engine.status = "Translation copied"
                } label: {
                    Label("Copy translation", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(engine.translated.isEmpty)

                Button {
                    UIPasteboard.general.string = engine.original
                    engine.status = "Original text copied"
                } label: {
                    Label("Copy original", systemImage: "text.quote")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(engine.original.isEmpty)

                if !engine.translated.isEmpty {
                    ShareLink(item: engine.translated) {
                        Label("Share translation", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    engine.retranslateLast()
                } label: {
                    Label("Re-translate", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(engine.original.isEmpty)

                Button {
                    engine.retranslateLastFresh()
                } label: {
                    Label("Retry fresh", systemImage: "arrow.trianglehead.2.clockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(engine.original.isEmpty)

                Button {
                    engine.clearCurrentTranslation()
                } label: {
                    Label("Clear output", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(engine.translated.isEmpty)
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)
            Toggle("Pause translating", isOn: $engine.paused).font(.footnote)
            if engine.captureAlive {
                Text("OCR \(Int(engine.ocrMs)) ms · translate \(Int(engine.translateMs)) ms · extension memory left \(Int(engine.extFreeMB)) MB")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !engine.lastRaw.isEmpty {
                Text("OCR sees: \(engine.lastRaw)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Button {
                    UIPasteboard.general.string = engine.lastRaw
                    engine.status = "Raw OCR text copied"
                } label: {
                    Label("Copy raw OCR", systemImage: "doc.text")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if engine.lastOutputQuality.hasPrefix("Review") || engine.lastOutputQuality.hasPrefix("Suspicious") {
                Label(engine.lastOutputQuality, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if engine.extensionVersion != "–" && engine.extensionVersion != AppVersion.version {
                Text("⚠️ Capture extension is v\(engine.extensionVersion), app is v\(AppVersion.version). Reinstall the IPA.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Button { engine.runTest() } label: {
                Label("Test translation", systemImage: "checkmark.seal")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .card()
    }
}

// MARK: - Languages
struct LanguagesView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @State private var query = ""

    private var filtered: [LangItem] {
        engine.languages.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var ready: [LangItem] { filtered.filter { engine.langStatus[$0.code] == .installed } }
    private var available: [LangItem] { filtered.filter { engine.langStatus[$0.code] == .supported } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Translation runs fully on your phone using Apple's language packs. Packs are stored by iOS (not in this app). Status is shown for translating into your target language.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if engine.langStatus.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                if !ready.isEmpty {
                    Section("Ready · works offline") {
                        ForEach(ready) { l in
                            HStack {
                                Text(l.name)
                                Spacer()
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                }
                if !available.isEmpty {
                    Section("Available to download") {
                        ForEach(available) { l in
                            HStack {
                                Text(l.name)
                                Spacer()
                                Button("Get") { engine.download(l.code) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .searchable(text: $query, prompt: "Search languages")
            .navigationTitle("Languages")
            .toolbar { Button("Refresh") { Task { await engine.refreshStatus() } } }
        }
    }
}

// MARK: - History
struct HistoryView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @State private var query = ""
    @State private var onlyStarred = false
    @State private var showingClearConfirmation = false
    @State private var showingExporter = false
    @State private var exportDocument: HistoryExportDocument?
    @State private var exportContentType: UTType = .plainText
    @State private var exportFilename = "ScreenLingo-History.txt"

    private var filteredHistory: [HistoryItem] {
        engine.history.filter { item in
            (!onlyStarred || item.starred) &&
            (query.isEmpty || item.original.localizedCaseInsensitiveContains(query) ||
             item.translated.localizedCaseInsensitiveContains(query))
        }
    }

    private var exportText: String {
        engine.history.map {
            "[\($0.date.formatted(date: .abbreviated, time: .shortened))]\nOriginal: \($0.original)\nTranslation: \($0.translated)"
        }.joined(separator: "\n\n──────────\n\n")
    }

    private func csvCell(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n") + "\""
    }

    private var exportCSV: String {
        let rows = engine.history.map { item in
            [item.date.ISO8601Format(), item.starred ? "true" : "false", item.original, item.translated]
                .map(csvCell).joined(separator: ",")
        }
        return (["date,starred,original,translation"] + rows).joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Tap a translation to copy it. Swipe right to star or unstar entries. Search either language and export your history.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !engine.history.isEmpty {
                        Text("\(filteredHistory.count) of \(engine.history.count) entries")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(filteredHistory) { h in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(h.translated).font(.body.weight(.semibold)).textSelection(.enabled)
                        Text(h.original).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Text(h.date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Button {
                                engine.toggleStar(h.id)
                            } label: {
                                Label(h.starred ? "Unstar" : "Star", systemImage: h.starred ? "star.slash.fill" : "star.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(h.starred ? "Remove from favourites" : "Add to favourites")
                            Button {
                                UIPasteboard.general.string = h.translated
                            } label: { Label("Translation", systemImage: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            Button {
                                UIPasteboard.general.string = h.original
                            } label: { Label("Original", systemImage: "text.quote") }
                            .buttonStyle(.borderless)
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { UIPasteboard.general.string = h.translated }
                    .swipeActions(edge: .leading) {
                        Button { engine.toggleStar(h.id) } label: {
                            Label(h.starred ? "Unstar" : "Star", systemImage: h.starred ? "star.slash" : "star")
                        }
                        .tint(.yellow)
                    }
                    .overlay(alignment: .topTrailing) {
                        if h.starred { Image(systemName: "star.fill").foregroundStyle(.yellow).padding(.top, 2) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .searchable(text: $query, prompt: "Search original or translation")
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { prepareExport(exportText, type: .plainText, filename: "ScreenLingo-History.txt") } label: {
                            Label("Export as text file", systemImage: "doc.text")
                        }
                        Button { prepareExport(exportCSV, type: .commaSeparatedText, filename: "ScreenLingo-History.csv") } label: {
                            Label("Export as CSV file", systemImage: "tablecells")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(engine.history.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Only starred", isOn: $onlyStarred)
                        Button("Clear unstarred", role: .destructive) {
                            engine.history.removeAll { !$0.starred }
                        }
                        Button("Clear all history", role: .destructive) { showingClearConfirmation = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(engine.history.isEmpty)
                }
            }
            .confirmationDialog("Delete all translation history?", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
                Button("Delete all history", role: .destructive) { engine.history.removeAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
            .fileExporter(isPresented: $showingExporter,
                          document: exportDocument,
                          contentType: exportContentType,
                          defaultFilename: exportFilename) { result in
                switch result {
                case .success:
                    engine.status = "History export saved"
                case .failure(let error):
                    engine.status = "History export failed: \(error.localizedDescription)"
                }
                exportDocument = nil
            }
            .overlay {
                if engine.history.isEmpty {
                    ContentUnavailableView("No translations yet",
                                           systemImage: "text.bubble",
                                           description: Text("Start screen capture and your recent translations will appear here."))
                } else if filteredHistory.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    private func prepareExport(_ text: String, type: UTType, filename: String) {
        exportDocument = HistoryExportDocument(text: text)
        exportContentType = type
        exportFilename = filename
        showingExporter = true
    }
}
