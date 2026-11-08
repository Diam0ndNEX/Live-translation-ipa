// ScreenLingo – App – Platform bridges (2.1.4)
import SwiftUI
import ReplayKit

// MARK: - Broadcast picker (real system button, so one genuine tap starts capture)
/// The system picker keeps its inner button at its first size; this makes the button fill the whole view,
/// so a tap anywhere on a larger circle reaches ReplayKit.
final class FullSizeBroadcastPicker: RPSystemBroadcastPickerView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for sub in subviews { sub.frame = bounds }
    }
}

struct BroadcastPicker: UIViewRepresentable {
    var onTap: () -> Void = {}
    /// True when a custom glyph is drawn underneath and the system one must not show.
    var hidesGlyph = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = FullSizeBroadcastPicker(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        v.preferredExtension = Self.extensionID()
        v.showsMicrophoneButton = false
        v.tintColor = hidesGlyph ? .clear : .white
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

