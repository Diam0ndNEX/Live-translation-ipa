// Screen Translator – App – v0.11.0
import SwiftUI
import ReplayKit

// MARK: - Theme
enum AccentChoice: String, CaseIterable, Identifiable {
    case blue, purple, teal, orange, pink, green
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var start: Color {
        switch self {
        case .blue: Color(red: 0.25, green: 0.52, blue: 1)
        case .purple: Color(red: 0.55, green: 0.38, blue: 0.95)
        case .teal: Color(red: 0.1, green: 0.7, blue: 0.82)
        case .orange: Color(red: 1, green: 0.6, blue: 0.2)
        case .pink: Color(red: 0.95, green: 0.38, blue: 0.62)
        case .green: Color(red: 0.2, green: 0.75, blue: 0.45)
        }
    }
    var end: Color {
        switch self {
        case .blue: Color(red: 0.45, green: 0.42, blue: 0.98)
        case .purple: Color(red: 0.85, green: 0.38, blue: 0.9)
        case .teal: Color(red: 0.2, green: 0.5, blue: 0.95)
        case .orange: Color(red: 0.95, green: 0.3, blue: 0.4)
        case .pink: Color(red: 0.7, green: 0.3, blue: 0.95)
        case .green: Color(red: 0.1, green: 0.6, blue: 0.75)
        }
    }
}

enum Theme {
    static let bg = Color(red: 0.04, green: 0.05, blue: 0.09)
    static let card = Color.white.opacity(0.07)
    static let cardStrong = Color.white.opacity(0.12)
    static var accent: AccentChoice { AccentChoice(rawValue: UserDefaults.standard.string(forKey: "accent") ?? "") ?? .blue }
    static var gradient: LinearGradient {
        LinearGradient(colors: [accent.start, accent.end], startPoint: .leading, endPoint: .trailing)
    }
}

extension View {
    func card() -> some View {
        self.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Tab switching from anywhere
private struct SelectTabKey: EnvironmentKey {
    static let defaultValue: (Int) -> Void = { _ in }
}
extension EnvironmentValues {
    var selectTab: (Int) -> Void {
        get { self[SelectTabKey.self] }
        set { self[SelectTabKey.self] = newValue }
    }
}

// MARK: - Language menu
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

// MARK: - Broadcast picker (real system button, so one genuine tap starts capture)
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

// MARK: - Share sheet
struct ShareItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Toast
struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.15)))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}

// MARK: - Full-screen reader
struct ReaderView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @Environment(\.dismiss) private var dismiss
    @AppStorage("readerSize") private var size = 28.0
    @AppStorage("readerOriginal") private var showOriginal = true
    @AppStorage("readerAlignment") private var centered = false
    @State private var focus = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: centered ? .center : .leading, spacing: 24) {
                    if engine.translated.isEmpty {
                        ContentUnavailableView("Ready to read", systemImage: "text.book.closed",
                            description: Text("Start capture or translate text from Home."))
                    } else {
                        Text(engine.translated).font(.system(size: size, weight: .medium, design: .rounded))
                            .lineSpacing(8).textSelection(.enabled)
                        if showOriginal, !engine.original.isEmpty {
                            Divider()
                            Text(engine.original).font(.system(size: max(15, size * 0.65)))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                .multilineTextAlignment(centered ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: centered ? .center : .leading).padding(24)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Focus reader").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { engine.toggleFrozenOutput() } label: { Image(systemName: engine.frozen ? "play.fill" : "pause.fill") }
                        .accessibilityLabel(engine.frozen ? "Resume live text" : "Freeze current text")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Show original", isOn: $showOriginal)
                        Toggle("Center text", isOn: $centered)
                        Button("Listen") { engine.speak(engine.translated) }
                        Button("Copy translation") { UIPasteboard.general.string = engine.translated; engine.toast("Copied") }
                        ShareLink(item: engine.translated) { Label("Share text", systemImage: "square.and.arrow.up") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if !focus {
                        HStack {
                            Image(systemName: "textformat.size.smaller")
                            Slider(value: $size, in: 18...56).accessibilityLabel("Reader text size")
                            Image(systemName: "textformat.size.larger")
                        }
                    }
                    Button(focus ? "Show reading controls" : "Hide reading controls") { withAnimation { focus.toggle() } }
                        .font(.caption)
                }.padding().background(.ultraThinMaterial)
            }
        }
    }
}

// MARK: - First-launch welcome
struct OnboardingView: View {
    @EnvironmentObject var engine: TranslatorEngine
    @Binding var done: Bool
    @State private var page = 0

    private func info(_ icon: String, _ title: String, _ text: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(Theme.gradient)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    private var languages: some View {
        VStack(spacing: 18) {
            Image(systemName: "globe").font(.system(size: 64, weight: .semibold)).foregroundStyle(Theme.gradient)
            Text("Pick your languages").font(.title2.bold())
            Text("Translation happens on your phone, so each language needs a one-time download.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                LangMenu(code: $engine.sourceCode, items: engine.languages, allowAuto: true)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                LangMenu(code: $engine.targetCode, items: engine.languages)
            }
            if engine.sourceCode != "auto" {
                Button("Download language pack") { engine.download(engine.sourceCode) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 28)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    Button("Skip") { done = true }.foregroundStyle(.secondary)
                }
                .padding([.horizontal, .top])
                TabView(selection: $page) {
                    info("text.viewfinder", "Translate anything on your screen",
                         "Games, videos, comics, chats. The translation floats on top of whatever you're watching.")
                        .tag(0)
                    languages.tag(1)
                    info("play.rectangle.fill", "Start in two taps",
                         "On the Home tab tap the broadcast button, choose ScreenLingo Capture, then Start Broadcast. The floating window opens by itself.")
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                Button {
                    if page < 2 { withAnimation { page += 1 } } else { done = true }
                } label: {
                    Text(page < 2 ? "Next" : "Get started")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Sharing
/// Shares through a real temporary file, presented straight from UIKit.
/// (Handing the share sheet large raw text or a UIImage inside a SwiftUI sheet can hang on "Loading…".)
enum Sharer {
    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene?.windows.first?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    static func present(_ items: [Any]) {
        guard let top = topController() else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }

    /// Text goes out as a file (.txt, .csv, .json) so it opens instantly and can be saved to Files.
    static func shareFile(text: String, name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            present([url])
        } catch {
            UIPasteboard.general.string = text      // last resort: at least put it on the clipboard
        }
    }

    static func shareImage(_ image: UIImage, name: String = "translation.png") {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if let data = image.pngData(), (try? data.write(to: url)) != nil {
            present([url])
        } else {
            present([image])
        }
    }
}
