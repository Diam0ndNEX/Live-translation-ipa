// ScreenLingo – App – Languages tab (2.0.0 build 85)
import SwiftUI
import Translation

/// Pair first. A tap on a language opens an explicit choice; nothing changes silently.
struct LanguagesView: View {
    let engine: TranslatorEngine
    @EnvironmentObject private var feedback: FeedbackCenter
    @StateObject private var pair: EngineSlice<PairSnapshot>
    @State private var query = ""
    @State private var chosen: LangItem?
    @State private var downloading: [String: Date] = [:]

    init(engine: TranslatorEngine) {
        self.engine = engine
        _pair = StateObject(wrappedValue: EngineSlice(engine) { PairSnapshot.read($0) })
    }

    private func name(_ code: String) -> String {
        code == "auto" ? "Auto-detect" : (pair.value.languages.first { $0.code == code }?.name ?? code.uppercased())
    }
    private var filtered: [LangItem] {
        pair.value.languages.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private func state(_ l: LangItem) -> LanguageAvailability.Status? { pair.value.statuses[l.code] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Space.m) {
                        HStack(spacing: Space.s) {
                            Text(name(pair.value.source)).font(.headline).frame(maxWidth: .infinity)
                            IconButton(symbol: "arrow.left.arrow.right", label: "Swap source and target languages", enabled: pair.value.source != "auto") {
                                engine.swapLanguages(); Feedback.tap()
                            }
                            Text(name(pair.value.target)).font(.headline).frame(maxWidth: .infinity)
                        }
                        StatusPill(text: pair.value.packState.title, symbol: pair.value.packState.symbol, severity: pair.value.packState.severity)
                    }.padding(.vertical, Space.xs)
                } header: { Text("Current pair") } footer: { Text("Tap a language to choose what to do with it.") }

                if !pair.value.downloadMessage.isEmpty {
                    Section { Banner(text: pair.value.downloadMessage, severity: .info) }.listRowBackground(Color.clear)
                }
                if pair.value.statuses.isEmpty { Section { ProgressRow(title: "Checking installed language packs…") } }
                group("Ready, works offline", filtered.filter { state($0) == .installed })
                group("Available to download", filtered.filter { state($0) == .supported })
                group("Not supported on this device", filtered.filter { state($0) == .unsupported })
                Section {
                    Text("Translation runs on your phone with Apple's language packs. iOS stores the packs and shares them with the Translate app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background.ignoresSafeArea())
            .searchable(text: $query, prompt: "Search languages")
            .navigationTitle("Languages")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await engine.refreshStatus() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Check language packs again")
                }
            }
            .confirmationDialog(chosen.map { $0.name } ?? "", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }), titleVisibility: .visible, presenting: chosen) { l in
                Button("Translate from \(l.name)") { engine.sourceCode = l.code; feedback.show("Translating from \(l.name)") }
                Button("Translate into \(l.name)") { engine.targetCode = l.code; feedback.show("Translating into \(l.name)") }
                if state(l) == .supported { Button("Download language pack") { startDownload(l) } }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: pair.value.statuses) { _, new in
                downloading = downloading.filter { new[$0.key] != .installed }
            }
        }
    }

    private func startDownload(_ l: LangItem) {
        downloading[l.code] = Date()
        engine.download(l.code)
        Feedback.tap()
    }

    @ViewBuilder private func group(_ title: String, _ items: [LangItem]) -> some View {
        if !items.isEmpty {
            Section("\(title) (\(items.count))") {
                ForEach(items) { l in row(l) }
            }
        }
    }

    private func row(_ l: LangItem) -> some View {
        Button { chosen = l; Feedback.tap() } label: {
            ListRow(title: l.name, subtitle: tags(l)) {
                switch state(l) {
                case .installed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success).accessibilityLabel("Ready")
                case .supported:
                    if downloading[l.code] != nil { ProgressView().accessibilityLabel("Downloading") }
                    else { Image(systemName: "arrow.down.circle").accessibilityLabel("Needs download") }
                case .unsupported: Image(systemName: "nosign").foregroundStyle(.secondary).accessibilityLabel("Not supported")
                default: ProgressView().accessibilityLabel("Checking")
                }
            }
        }.buttonStyle(.plain)
    }

    private func tags(_ l: LangItem) -> String? {
        var t: [String] = []
        if l.code == pair.value.source { t.append("Translating from") }
        if l.code == pair.value.target { t.append("Translating into") }
        return t.isEmpty ? nil : t.joined(separator: " · ")
    }
}
