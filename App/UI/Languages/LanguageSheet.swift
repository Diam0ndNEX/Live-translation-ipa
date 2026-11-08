// ScreenLingo – App – Languages (2.1.0, spec §13.5.2; replaces the Languages tab)
// One implementation, used as the sheet from the pair title and as Settings > Language packs.
// The side being edited is always visible (From | Into); one tap sets it, with Undo instead of a dialog.
import SwiftUI
import Translation

struct LanguageSheet: View {
    let engine: TranslatorEngine
    /// True when shown as a sheet (adds its own navigation bar and Done).
    var inSheet = true
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var feedback: FeedbackCenter
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pair: EngineSlice<PairSnapshot>
    @State private var query = ""
    @State private var side: LanguageSide = .target
    @State private var showDownloaded = false
    @State private var showUnsupported = false

    init(engine: TranslatorEngine, inSheet: Bool = true) {
        self.engine = engine
        self.inSheet = inSheet
        _pair = StateObject(wrappedValue: EngineSlice(engine) { PairSnapshot.read($0) })
    }

    private var p: PairSnapshot { pair.value }
    private func name(_ code: String) -> String { LanguageNames.name(code, in: p.languages) }
    private func status(_ code: String) -> LanguageAvailability.Status? { p.statuses[code] }
    private var current: String { side == .source ? p.source : p.target }

    private var matching: [LangItem] {
        p.languages.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.code.hasPrefix(query.lowercased()) }
    }
    /// Languages in the current pair and recent pairs, in that order.
    private var frequent: [LangItem] {
        var codes: [String] = [p.source, p.target]
        for pairCode in p.recent { codes += pairCode.split(separator: ">").map(String.init) }
        var seen = Set<String>()
        let ordered = codes.filter { $0 != "auto" && seen.insert($0).inserted }
        return ordered.compactMap { code in matching.first { $0.code == code } }.prefix(6).map { $0 }
    }

    var body: some View {
        if inSheet {
            NavigationStack {
                list
                    .navigationTitle("Languages")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
            .onAppear { side = router.languageSide }
        } else {
            list.navigationTitle("Language packs")
        }
    }

    private var list: some View {
        List {
            Section {
                Picker("Choosing", selection: $side) {
                    Text("From  \(name(p.source))").tag(LanguageSide.source)
                    Text("Into  \(name(p.target))").tag(LanguageSide.target)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .accessibilityLabel("Language side to choose")
            }
            if !p.recent.isEmpty && query.isEmpty {
                Section("Recent pairs") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: KitSpace.tight) {
                            ForEach(p.recent, id: \.self) { recent in
                                Button(LanguageNames.pairLabel(recent)) { engine.applyPair(recent) }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                    .font(.subheadline.weight(.medium))
                                    .frame(minHeight: 44)
                            }
                        }
                    }
                }
            }
            if side == .source && query.isEmpty {
                Section { row(LangItem(code: "auto", name: "Auto-detect"), subtitle: "Works out the language as it reads") }
            }
            if !frequent.isEmpty {
                Section("Frequently used") { ForEach(frequent) { row($0) } }
            }
            if !p.downloadMessage.isEmpty {
                Section {
                    Label(p.downloadMessage, systemImage: p.downloadRetryCode == nil ? "arrow.down.circle" : "exclamationmark.triangle")
                        .font(.subheadline)
                    if let retry = p.downloadRetryCode {
                        Button("Try again") { engine.download(retry) }.frame(minHeight: 44)
                    }
                }
            }
            if p.statuses.isEmpty {
                Section { HStack(spacing: KitSpace.tight) { ProgressView(); Text("Checking installed packs…").foregroundStyle(.secondary) } }
            }
            let ready = matching.filter { status($0.code) == .installed }
            let available = matching.filter { status($0.code) == .supported }
            let unsupported = matching.filter { status($0.code) == .unsupported }
            if !available.isEmpty {
                Section("Available to download (\(available.count))") { ForEach(available) { row($0) } }
            }
            if !ready.isEmpty {
                Section {
                    if showDownloaded || !query.isEmpty { ForEach(ready) { row($0) } }
                } header: {
                    disclosureHeader("Downloaded (\(ready.count))", expanded: $showDownloaded, forced: !query.isEmpty)
                }
            }
            if !unsupported.isEmpty {
                Section {
                    if showUnsupported || !query.isEmpty { ForEach(unsupported) { row($0) } }
                } header: {
                    disclosureHeader("Not supported on this device (\(unsupported.count))", expanded: $showUnsupported, forced: !query.isEmpty)
                } footer: {
                    Text("Translation runs on your phone with Apple's language packs. iOS stores them and shares them with the Translate app.")
                }
            }
        }
        .kitPage()
        .animation(KitMotion.spring, value: current)
        .searchable(text: $query, prompt: "Search languages")
        .refreshable { await engine.refreshStatus() }
    }

    private func disclosureHeader(_ title: String, expanded: Binding<Bool>, forced: Bool) -> some View {
        Button { withAnimation(KitMotion.spring) { expanded.wrappedValue.toggle() } } label: {
            HStack {
                Text(title)
                Spacer()
                if !forced {
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded.wrappedValue ? 0 : -90))
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(forced)
        .accessibilityValue(expanded.wrappedValue || forced ? "Expanded" : "Collapsed")
    }

    /// 48 pt row: name, optional subtitle, a check on the chosen one, and the pack action.
    private func row(_ item: LangItem, subtitle: String? = nil) -> some View {
        HStack(spacing: KitSpace.row) {
            Button { choose(item) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.body).foregroundStyle(.primary)
                        if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: KitSpace.tight)
                    if item.code == current {
                        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
                            .symbolEffect(.bounce, value: current)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityLabel("Selected")
                    }
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .sensoryFeedback(.selection, trigger: current)
            .accessibilityHint(side == .source ? "Translate from this language" : "Translate into this language")
            if item.code != "auto" { packControl(item) }
        }
    }

    @ViewBuilder private func packControl(_ item: LangItem) -> some View {
        switch status(item.code) {
        case .supported:
            if p.downloadInFlight == item.code {
                ProgressView().accessibilityLabel("Downloading")
            } else {
                Button("Get") { engine.download(item.code) }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityLabel("Download \(item.name)")
            }
        case .unsupported:
            Image(systemName: "nosign").foregroundStyle(.secondary).accessibilityLabel("Not supported")
        default:
            EmptyView()
        }
    }

    private func choose(_ item: LangItem) {
        let previousSource = p.source, previousTarget = p.target
        // 2.2.1 (U7): choosing the language that is already on the other side swaps the two sides, as Apple Translate does.
        let other = side == .source ? previousTarget : previousSource
        if item.code == other, item.code != "auto" {
            let newSource = side == .source ? item.code : previousTarget
            let newTarget = side == .source ? previousSource : item.code
            guard newTarget != "auto" else {
                feedback.show("From and Into must be different languages", severity: .warning)
                return
            }
            engine.sourceCode = newSource
            engine.targetCode = newTarget
            feedback.show("Swapped: from \(name(newSource)) into \(name(newTarget))", severity: .success, actionTitle: "Undo") { [engine] in
                engine.sourceCode = previousSource
                engine.targetCode = previousTarget
            }
            return
        }
        if side == .source { engine.sourceCode = item.code } else { engine.targetCode = item.code }
        let verb = side == .source ? "Translating from" : "Translating into"
        feedback.show("\(verb) \(item.name)", severity: .success, actionTitle: "Undo") { [engine] in
            engine.sourceCode = previousSource
            engine.targetCode = previousTarget
        }
        if inSheet && side == .source { withAnimation(KitMotion.spring) { side = .target } }
    }
}
