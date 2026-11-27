// ScreenLingo – App – Settings (2.1.2: colour-tile rows in rounded groups, one hero summary, native pages; 2.7.0 iPad split view)
import SwiftUI
import Combine

extension View {
    /// Every settings page is a native grouped list with a large title; no header card (R9).
    func settingsPage(_ title: String) -> some View {
        self.listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 44)
            .listSectionSpacing(.compact)
            .headerProminence(.increased)
            .listRowBackground(Color(.secondarySystemGroupedBackground).opacity(0.92))
            .scrollContentBackground(.hidden)
            .ambientGlow()
            .background(Color(.systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
    }
}

struct ResetSection: View {
    @EngineHandle private var engine
    @EnvironmentObject private var feedback: FeedbackCenter
    let keys: [String]
    @State private var confirm = false
    var body: some View {
        Section {
            // The dialog belongs to the button that opens it, not to the Section.
            Button(role: .destructive) { confirm = true } label: {
                Label("Reset this page", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(PressableStyle())
                .confirmDestructive("Reset every setting on this page?", message: "Only this page's settings return to their defaults.",
                                    isPresented: $confirm, button: "Reset") {
                    engine.resetKeys(keys); feedback.show("Page reset to defaults", severity: .success)
                }
        }
    }
}

private struct PresetsLinkRow: View {
    @ObservedObject var store: PresetStore
    /// 2.7.0: set on iPad, where the page opens in the detail column instead of being pushed.
    var open: (() -> Void)? = nil
    var selected = false
    var body: some View {
        if let open {
            Button(action: open) { label.settingsSelection(selected) }
                .buttonStyle(PressableStyle())
        } else {
            NavigationLink { PresetManagerView(store: store) } label: { label }
                .buttonStyle(PressableStyle())
        }
    }
    private var label: some View {
        SettingsRow(title: "Scenes", value: store.active.map { store.isModified ? "\($0.name) · changed" : $0.name } ?? "\(store.all.count)",
                    symbol: "square.stack.3d.up", tint: .indigo)
    }
}

/// 2.7.0: the page shown in the iPad detail column.
private struct SettingsDetail: Identifiable {
    let id: String
    let view: AnyView
}

/// 2.7.0: what the Settings summary shows. The screen used to observe the whole engine and redraw on every caption
/// while capture ran, because every tab stays alive in the tab view.
struct SettingsSummaryFacts: Equatable {
    var source: String
    var target: String
    var system: String
    var memoryCount: Int
    @MainActor static func read(_ e: TranslatorEngine) -> SettingsSummaryFacts {
        SettingsSummaryFacts(source: e.sourceCode, target: e.targetCode, system: e.pendingTranslationSystem.shortName,
                             memoryCount: e.memoryCount)
    }
}

extension View {
    /// The selected row in the iPad Settings sidebar.
    func settingsSelection(_ selected: Bool) -> some View {
        background(selected ? Color.accentColor.opacity(0.16) : Color.clear,
                   in: RoundedRectangle(cornerRadius: KitRadius.small, style: .continuous))
    }
}

/// One searchable entry of the Settings list.
private struct SettingsEntry: Identifiable {
    let title: String
    let symbol: String
    let keywords: String
    var id: String { title }
}

/// One grouped list in five groups (§13.5.5). Search finds a row by its title or by plain words for what it holds.
struct SettingsView: View {
    @EngineHandle private var engine
    @EngineFacts(SettingsSummaryFacts.read) private var summary
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var advanced: AdvancedMode
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var query = ""
    @State private var detail: SettingsDetail?
    /// Content style, speed and area live in UserDefaults; this redraws the summary when they change.
    @State private var defaultsTick = 0
    private var split: Bool { sizeClass == .regular }
    /// Read-only: each key keeps its one owner page (scripts/test_experimental_settings.py).
    private var areaTitle: String { (OCRArea(rawValue: UserDefaults.standard.string(forKey: "area") ?? "") ?? .smart).title }

    private func shows(_ title: String, _ keywords: String) -> Bool {
        query.isEmpty || (title + " " + keywords).localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        if split {
            // 2.7.0, iPad: the list on the left, the page on the right. Each page gets its own stack, so links inside a
            // page (Window > Style, Memory > ...) push in the right column.
            NavigationSplitView {
                list.navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
            } detail: {
                NavigationStack {
                    if let detail {
                        detail.view
                    } else {
                        ContentUnavailableView("Choose a setting", systemImage: "gearshape",
                                               description: Text("Pick a page on the left. Search finds a single setting."))
                    }
                }
                .id(detail?.id ?? "none")
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack { list }
        }
    }

    private var list: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: KitSpace.group) {
                    if query.isEmpty { hero }
                    settingResults
                    translation
                    reading
                    caption
                    look
                    care
                    advancedGroup
                    if query.isEmpty {
                        SettingsGroup {
                            link("About ScreenLingo", "info.circle", .gray, value: AppVersion.full, destination: AboutSettings())
                        }
                    }
                }
                .padding(.horizontal, KitSpace.margin)
                .padding(.top, KitSpace.tight)
                .padding(.bottom, KitSpace.group)
                .modifier(ReadableColumn())
                .animation(KitMotion.spring, value: query.isEmpty)
            }
            .scrollDismissesKeyboard(.interactively)
            .ambientGlow()
            .background(Color(.systemGroupedBackground))
            .searchable(text: $query, prompt: "Search settings")
            .navigationTitle("Settings")
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)) { _ in defaultsTick &+= 1 }
            #if SCREENLINGO_FIXTURES
            .navigationDestination(isPresented: .constant(UIFixture.current == .settingsCaption)) { CaptionAppearanceSettings() }
            .navigationDestination(isPresented: .constant(UIFixture.current == .settingsInterface)) { InterfaceSettings() }
            #endif
    }

    /// One row that opens a page. The press feedback comes from the style, not from a big button shape.
    @ViewBuilder private func link<D: View>(_ title: String, _ symbol: String, _ tint: Color, value: String = "",
                                            destination: @autoclosure @escaping () -> D) -> some View {
        if split {
            Button { show(title, destination()) } label: {
                SettingsRow(title: title, value: value, symbol: symbol, tint: tint).settingsSelection(detail?.id == title)
            }
            .buttonStyle(PressableStyle())
        } else {
            NavigationLink { destination() } label: { SettingsRow(title: title, value: value, symbol: symbol, tint: tint) }
                .buttonStyle(PressableStyle())
        }
    }

    /// iPad: shows a page in the detail column.
    private func show<D: View>(_ id: String, _ page: D) {
        detail = SettingsDetail(id: id, view: AnyView(page))
    }

    /// What is set up right now, at a glance. The one hero object on this screen.
    private var hero: some View {
        let defaults = UserDefaults.standard
        let _ = defaultsTick
        let content = TranslateMode(rawValue: defaults.string(forKey: "mode") ?? "")?.title ?? TranslateMode.movie.title
        let speed = SpeedPreset(rawValue: defaults.string(forKey: "speed") ?? "")?.title ?? SpeedPreset.balanced.title
        let source = summary.source == "auto" ? "Auto" : summary.source.uppercased()
        return HStack(spacing: KitSpace.row) {
            IconTile(symbol: "character.bubble.fill", tint: .accentColor).scaleEffect(1.35).padding(KitSpace.unit)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(source) → \(summary.target.uppercased())").font(.title3.weight(.semibold))
                Text("\(summary.system) · \(content) · \(speed)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .kitSurface()
        .accessibilityElement(children: .combine)
    }

    /// Search finds the setting itself, then opens the page that holds it (§13.5.5).
    @ViewBuilder private var settingResults: some View {
        let found = SettingsSearchIndex.matches(query)
        if !found.isEmpty {
            SettingsGroup(title: "Settings") {
                ForEach(found.prefix(30)) { entry in
                    resultLink(entry) {
                        HStack(spacing: KitSpace.row) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.label).font(.body)
                                Text(entry.pageTitle).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: KitSpace.tight)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, KitSpace.row)
                        .padding(.vertical, 9)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                }
            }
        }
    }

    /// A search result opens its page: pushed on iPhone, in the detail column on iPad.
    @ViewBuilder private func resultLink<L: View>(_ entry: SettingsSearchEntry, @ViewBuilder label: () -> L) -> some View {
        if split {
            Button { show("search:" + entry.id, page(entry.page)) } label: { label().settingsSelection(detail?.id == "search:" + entry.id) }
                .buttonStyle(PressableStyle())
        } else {
            NavigationLink(destination: page(entry.page)) { label() }
                .buttonStyle(PressableStyle())
        }
    }

    @ViewBuilder private func page(_ page: SettingsPage) -> some View {
        switch page {
        case .reading: ReadingSettings()
        case .textRules: IntelligenceSettings()
        case .timing: ResponsivenessSettings()
        case .window: WindowSettings()
        case .style: CaptionAppearanceSettings()
        case .appearance: InterfaceSettings()
        case .feedback: FeedbackStorageSettings()
        case .reader: ReaderWorkspaceSettings()
        case .performance: PerformanceSettings()
        case .privacy: PrivacySettings()
        case .history: HistoryStorageSettings()
        case .backup: BackupSettings()
        case .system: TranslationSettings()
        case .diagnostics: DiagnosticsSettings()
        case .experimental: ExperimentalFeaturesView()
        }
    }

    @ViewBuilder private var translation: some View {
        SettingsGroup(title: "Translation") {
            if shows("System", "legacy low latency mode translate ahead speculation model warm memory") {
                link("System", "cpu", .blue, value: summary.system, destination: TranslationSettings())
            }
            if shows("Language packs", "languages download offline pair source target") {
                link("Language packs", "globe", .teal, destination: LanguageSheet(engine: engine, inSheet: false))
            }
            if shows("Scenes", "presets profiles saved configurations") {
                let openScenes: (() -> Void)? = split ? { show("Scenes", PresetManagerView(store: engine.presets)) } : nil
                PresetsLinkRow(store: engine.presets, open: openScenes, selected: detail?.id == "Scenes")
            }
            if shows("Memory", "translation memory remembered cache database") {
                link("Memory", "externaldrive", .purple, value: "\(summary.memoryCount.formatted()) remembered", destination: MemoryManagementView())
            }
        }
    }

    @ViewBuilder private var reading: some View {
        SettingsGroup(title: "Reading") {
            if shows("Area, recognition and speed", "capture movie subtitles frames ocr recognition tracking confirmation speed") {
                link("Area and recognition", "viewfinder", .green, value: areaTitle, destination: ReadingSettings())
            }
            if shows("Text rules and names", "understanding glossary slang protect names source fixes language detection recovery") {
                link("Text rules and names", "character.book.closed", .pink, destination: IntelligenceSettings())
            }
            if shows("Timing", "min display clear heartbeat steady captions handoff subtitle timing") {
                link("Timing", "timer", .orange, destination: ResponsivenessSettings())
            }
        }
    }

    @ViewBuilder private var caption: some View {
        SettingsGroup(title: "Floating caption",
                      footer: query.isEmpty ? "Both pages show a live preview of the floating caption." : nil) {
            if shows("Window", "floating window picture in picture pip size theme position") {
                link("Window", "pip", .cyan, destination: WindowSettings())
            }
            if shows("Style", "font size weight alignment spacing padding original caption layout") {
                link("Style", "textformat.size", .indigo, destination: CaptionAppearanceSettings())
            }
        }
    }

    @ViewBuilder private var look: some View {
        SettingsGroup(title: "Look and feel") {
            if shows("Appearance", "interface accent color dark light system theme") {
                link("Appearance", "paintpalette", .purple, value: theme.appearance.title, destination: InterfaceSettings())
            }
            if shows("Haptics and feedback", "vibration speak copy clipboard voice sharing") {
                link("Haptics and feedback", "hand.tap", .red, destination: FeedbackStorageSettings())
            }
            if shows("Reader and photos", "focus reader photo ocr reading layout") {
                link("Reader and photos", "text.book.closed", .teal, destination: ReaderWorkspaceSettings())
            }
        }
    }

    @ViewBuilder private var care: some View {
        SettingsGroup(title: "Device and data") {
            if shows("Performance and battery", "speed cool power thermal idle awake energy heat") {
                link("Performance and battery", "bolt.fill", .green, destination: PerformanceSettings())
            }
            if shows("Privacy", "private session diagnostic text speaker") {
                link("Privacy", "hand.raised.fill", .blue, destination: PrivacySettings())
            }
            if shows("History and storage", "saved translations retention limit delete library") {
                link("History and storage", "clock.arrow.circlepath", .gray, destination: HistoryStorageSettings())
            }
            if shows("Backup", "export import reset settings restore") {
                link("Backup and reset", "externaldrive.badge.timemachine", .gray, destination: BackupSettings())
            }
        }
    }

    /// Collapsed until the switch is on; the switch is the last row of the list. Search always finds these rows.
    @ViewBuilder private var advancedGroup: some View {
        let open = advanced.on || !query.isEmpty
        if open {
            SettingsGroup(title: "Advanced") {
                if shows("Diagnostics settings", "metrics benchmark export test runs fresh translation temporary memory") {
                    link("Diagnostics settings", "waveform.path.ecg", .red, destination: DiagnosticsSettings())
                }
                if shows("Experimental features", "beta experiments smart pipeline lyrics incremental pip rotation") {
                    link("Experimental features", "flask", .orange, destination: ExperimentalFeaturesView())
                }
                if shows("Pipeline simulator", "simulate test pipeline") {
                    link("Pipeline simulator", "point.3.connected.trianglepath.dotted", .indigo, destination: PipelineSimulatorView())
                }
                if shows("Test runs", "compare modes legacy low latency") {
                    Button { router.present(.testRuns) } label: { SettingsRow(title: "Test runs", symbol: "checklist", tint: .teal) }
                        .buttonStyle(PressableStyle())
                }
            }
        }
        if query.isEmpty {
            SettingsGroup(footer: "Diagnostics, experiments and the simulator. Hidden settings keep their values.") {
                HStack(spacing: KitSpace.row) {
                    IconTile(symbol: "slider.horizontal.3", tint: .gray)
                    Toggle("Show advanced settings", isOn: $advanced.on).sensoryFeedback(.selection, trigger: advanced.on)
                }
                .padding(.horizontal, KitSpace.row)
                .padding(.vertical, 9)
                .frame(minHeight: 48)
            }
        }
    }
}

// MARK: - Area and recognition


// MARK: - Backup & reset


/// Collection is independent of which diagnostics page happens to be visible.
struct DiagnosticsCollectionControls: View {
    @EngineHandle private var engine
    @AppStorage("diagnosticsEnabled") private var enabled = true
    @AppStorage("detailedCollection") private var detailed = false
    @State private var pendingCollection: PendingCollectionChange?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Simple diagnostics", isOn: $enabled.guardedByActiveRun(engine.diag, pending: $pendingCollection))
            Toggle("Detailed diagnostics", isOn: $detailed.guardedByActiveRun(engine.diag, pending: $pendingCollection)).disabled(!enabled)
            Text(enabled ? (detailed ? "Records summary counters, graphs, device samples and events." : "Summary counters only. Graph sampling, device polling and event history are off.") : "Diagnostic collection is off. Capture and translation continue.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Changing collection starts a fresh diagnostic session. Detailed collection requires Simple diagnostics.")
                .font(.caption).foregroundStyle(.secondary)
        }
        // 2.2.1 (D2): the root handlers in ScreenTranslatorApp apply the change once.
        .confirmCollectionChange($pendingCollection)
    }
}
