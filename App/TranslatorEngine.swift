import SwiftUI
import Translation
import NaturalLanguage
import AVFoundation

@MainActor
final class TranslatorEngine: ObservableObject {
    @Published var targetCode: String {
        didSet { UserDefaults.standard.set(targetCode, forKey: "target"); lastHandled = "" }
    }
    @Published var original = ""
    @Published var translated = ""
    @Published var status = "Idle"
    @Published var legacyConfig: TranslationSession.Configuration?   // iOS 18 path

    let pip = PiPRenderer()

    private var lastHandled = ""
    private var queued: String?
    private var busy = false
    private var pendingText = ""
    private var legacyContinuation: CheckedContinuation<String?, Never>?

    init() {
        targetCode = UserDefaults.standard.string(forKey: "target") ?? "en"
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<TranslatorEngine>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in me.handleNewOCR() }
            },
            Shared.notifyName as CFString, nil, .deliverImmediately)
    }

    func startPiP() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? s.setActive(true)
        pip.start()
    }

    // MARK: Pipeline
    func handleNewOCR() {
        guard let url = Shared.fileURL,
              let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(OCRPayload.self, from: data),
              p.text != lastHandled else { return }
        lastHandled = p.text
        queued = p.text
        if !busy { Task { await drain() } }
    }

    private func drain() async {
        busy = true
        defer { busy = false }
        while let t = queued { queued = nil; await process(t) }
    }

    private func process(_ text: String) async {
        let target = Locale.Language(identifier: targetCode)
        let rec = NLLanguageRecognizer()
        rec.processString(text)
        guard let dom = rec.dominantLanguage else { return }
        let source = Locale.Language(identifier: dom.rawValue)
        // Already in target language (also stops the PiP window being re-translated if captured)
        if source.languageCode == target.languageCode { return }

        let availability = await LanguageAvailability().status(from: source, to: target)
        if availability == .unsupported { status = "\(dom.rawValue) → \(targetCode) not supported"; return }

        var result: String?
        if #available(iOS 26.0, *), availability == .installed {
            let session = TranslationSession(installedSource: source, target: target)
            result = try? await session.translate(text).targetText
        } else {
            result = await translateLegacy(text, source: source, target: target)
        }
        guard let result else { status = "Translation failed – is the language pack downloaded?"; return }
        original = text; translated = result
        status = "\(dom.rawValue) → \(targetCode)"
        pip.render(original: text, translated: result)
    }

    // MARK: iOS 18 path (needs the hosted .translationTask view)
    private func translateLegacy(_ text: String, source: Locale.Language, target: Locale.Language) async -> String? {
        await withCheckedContinuation { cont in
            legacyContinuation = cont
            pendingText = text
            if var c = legacyConfig, c.source == source, c.target == target {
                c.invalidate(); legacyConfig = c
            } else {
                legacyConfig = .init(source: source, target: target)
            }
            Task { try? await Task.sleep(for: .seconds(10)); finishLegacy(nil) }
        }
    }
    func runLegacy(_ session: TranslationSession) async {
        do { finishLegacy(try await session.translate(pendingText).targetText) }
        catch { finishLegacy(nil) }
    }
    private func finishLegacy(_ s: String?) {
        legacyContinuation?.resume(returning: s)
        legacyContinuation = nil
    }
}

enum Languages {
    static let all: [(code: String, name: String)] = [
        ("en","English"),("es","Spanish"),("fr","French"),("de","German"),("it","Italian"),
        ("pt","Portuguese"),("ru","Russian"),("ja","Japanese"),("ko","Korean"),
        ("zh-Hans","Chinese (Simplified)"),("zh-Hant","Chinese (Traditional)"),("ar","Arabic"),
        ("tr","Turkish"),("hi","Hindi"),("id","Indonesian"),("nl","Dutch"),("pl","Polish"),
        ("th","Thai"),("vi","Vietnamese"),("uk","Ukrainian")
    ]
}
