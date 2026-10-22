// Screen Translator – App – v0.8.0
import AVKit
import UIKit
import SwiftUI

enum PiPTheme: String, CaseIterable, Identifiable {
    case dark, light, yellow, blue, sepia, contrast
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: "Dark"; case .light: "Light"; case .yellow: "Yellow subtitles"
        case .blue: "Midnight blue"; case .sepia: "Sepia"; case .contrast: "High contrast"
        }
    }
}
enum PiPTextSize: String, CaseIterable, Identifiable {
    case auto, large, huge
    var id: String { rawValue }
    var title: String {
        switch self { case .auto: "Auto"; case .large: "Large"; case .huge: "Huge" }
    }
}
enum PiPFont: String, CaseIterable, Identifiable {
    case standard, rounded, serif, mono
    var id: String { rawValue }
    var title: String {
        switch self { case .standard: "Standard"; case .rounded: "Rounded"; case .serif: "Serif"; case .mono: "Monospaced" }
    }
    var design: UIFontDescriptor.SystemDesign {
        switch self { case .standard: .default; case .rounded: .rounded; case .serif: .serif; case .mono: .monospaced }
    }
}
struct PiPStyle {
    var bg: UIColor
    var fg: UIColor
    var secondary: UIColor
    var hi: CGFloat
    var lo: CGFloat
    var design: UIFontDescriptor.SystemDesign
    var accent = UIColor(red: 0.35, green: 0.85, blue: 1, alpha: 1)   // speaker names
    var highlightNames = true

    static func make(theme: PiPTheme, size: PiPTextSize, font: PiPFont = .standard) -> PiPStyle {
        let hi: CGFloat, lo: CGFloat
        switch size {
        case .auto: hi = 44; lo = 16
        case .large: hi = 56; lo = 24
        case .huge: hi = 72; lo = 32
        }
        let d = font.design
        var st: PiPStyle
        switch theme {
        case .dark:
            st = PiPStyle(bg: UIColor(white: 0.05, alpha: 1), fg: .white, secondary: .lightGray, hi: hi, lo: lo, design: d)
        case .light:
            st = PiPStyle(bg: UIColor(white: 0.97, alpha: 1), fg: .black, secondary: .darkGray, hi: hi, lo: lo, design: d)
            st.accent = UIColor(red: 0.1, green: 0.35, blue: 0.9, alpha: 1)
        case .yellow:
            st = PiPStyle(bg: .black, fg: UIColor(red: 1, green: 0.92, blue: 0.2, alpha: 1), secondary: .lightGray, hi: hi, lo: lo, design: d)
            st.accent = .white
        case .blue:
            st = PiPStyle(bg: UIColor(red: 0.04, green: 0.09, blue: 0.22, alpha: 1), fg: .white,
                          secondary: UIColor(red: 0.7, green: 0.8, blue: 1, alpha: 1), hi: hi, lo: lo, design: d)
        case .sepia:
            st = PiPStyle(bg: UIColor(red: 0.96, green: 0.92, blue: 0.82, alpha: 1),
                          fg: UIColor(red: 0.25, green: 0.17, blue: 0.08, alpha: 1),
                          secondary: UIColor(red: 0.45, green: 0.35, blue: 0.25, alpha: 1), hi: hi, lo: lo, design: d)
            st.accent = UIColor(red: 0.7, green: 0.3, blue: 0.1, alpha: 1)
        case .contrast:
            st = PiPStyle(bg: .black, fg: .white, secondary: .white, hi: hi, lo: lo, design: d)
            st.accent = .yellow
        }
        return st
    }
}

/// Draws translated text into frames and feeds them to a system Picture-in-Picture window.
final class PiPRenderer: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var pip: AVPictureInPictureController?
    private var size = CGSize(width: 720, height: 360)
    private var lastFrame: CGImage?
    private var heartbeat: Timer?
    private var lastOriginal = "", lastTranslated = "Waiting for screen text…"
    private var lastShowOriginal = true
    private static let labelRegex = try? NSRegularExpression(pattern: #"^([\p{L}][^\n:]{0,23}:)"#, options: [.anchorsMatchLines])
    var style = PiPStyle.make(theme: .dark, size: .auto)
    var onStatus: ((String) -> Void)?
    var onActiveChange: ((Bool) -> Void)?
    var isActive: Bool { pip?.isPictureInPictureActive ?? false }

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect

        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                        sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        if let tb {
            CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(tb, rate: 1)
            displayLayer.controlTimebase = tb
        }

        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                                playbackDelegate: self)
        pip = AVPictureInPictureController(contentSource: source)
        pip?.delegate = self
        pip?.requiresLinearPlayback = true
        pip?.canStartPictureInPictureAutomaticallyFromInline = true

        render(original: "", translated: lastTranslated, showOriginal: false)
        // PiP needs a steady stream of frames or it shows a spinner / stalls.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let f = self.lastFrame else { return }
            self.enqueue(f)
        }
    }

    @discardableResult
    func start() -> Bool {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            onStatus?("PiP isn't supported on this device"); return false
        }
        guard let pip, pip.isPictureInPicturePossible else { return false }
        pip.startPictureInPicture()
        return true
    }
    func stop() { pip?.stopPictureInPicture() }

    func setSize(_ s: CGSize) {
        guard s != size else { return }
        size = s
        render(original: lastOriginal, translated: lastTranslated, showOriginal: lastShowOriginal)
    }

    func rerender() { render(original: lastOriginal, translated: lastTranslated, showOriginal: lastShowOriginal) }

    // MARK: Rendering
    func render(original: String, translated: String, showOriginal: Bool) {
        lastOriginal = original; lastTranslated = translated; lastShowOriginal = showOriginal
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1; fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            style.bg.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let w = size.width - 48
            var y: CGFloat = 16
            if showOriginal && !original.isEmpty {
                let r = CGRect(x: 24, y: y, width: w, height: size.height * 0.27)
                let f = fittingFont(original, rect: r, weight: .regular, hi: 22, lo: 12)
                NSAttributedString(string: original, attributes: [.font: f, .foregroundColor: style.secondary])
                    .draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
                y = r.maxY + 10
            }
            let r2 = CGRect(x: 24, y: y, width: w, height: size.height - y - 16)
            let f2 = fittingFont(translated, rect: r2, weight: .bold, hi: style.hi, lo: style.lo)
            let att = NSMutableAttributedString(string: translated, attributes: [.font: f2, .foregroundColor: style.fg])
            if style.highlightNames, let rx = PiPRenderer.labelRegex {
                for m in rx.matches(in: translated, range: NSRange(location: 0, length: (translated as NSString).length)) {
                    att.addAttribute(.foregroundColor, value: style.accent, range: m.range(at: 1))
                }
            }
            att.draw(with: r2, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
        guard let cg = img.cgImage else { return }
        lastFrame = cg
        enqueue(cg)
    }

    private func fittingFont(_ text: String, rect: CGRect, weight: UIFont.Weight, hi: CGFloat, lo: CGFloat) -> UIFont {
        var fs = hi
        while fs > lo {
            let f = makeFont(fs, weight)
            let b = (text as NSString).boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                                    options: .usesLineFragmentOrigin,
                                                    attributes: [.font: f], context: nil)
            if b.height <= rect.height { return f }
            fs -= 2
        }
        return makeFont(lo, weight)
    }

    private func makeFont(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(style.design) { return UIFont(descriptor: d, size: size) }
        return base
    }

    private func enqueue(_ cg: CGImage) {
        guard let sb = makeSampleBuffer(cg) else { return }
        let r = displayLayer.sampleBufferRenderer
        if r.status == .failed { r.flush() }
        r.enqueue(sb)
    }

    private func makeSampleBuffer(_ cg: CGImage) -> CMSampleBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                     kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, cg.width, cg.height, kCVPixelFormatType_32BGRA, attrs, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))

        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let fmt else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        if let sb,
           let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary] {
            arr.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sb
    }

    // MARK: AVPictureInPictureControllerDelegate
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { onActiveChange?(true) }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { onActiveChange?(false) }
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        onStatus?("PiP failed: \(error.localizedDescription)")
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize s: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval i: CMTime,
                                    completion: @escaping () -> Void) { completion() }
}

/// The display layer must live in a visible view hierarchy for PiP to be possible.
struct PiPPreview: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeUIView(context: Context) -> LayerHostView { let v = LayerHostView(); v.host(layer); return v }
    func updateUIView(_ uiView: LayerHostView, context: Context) {}
}
final class LayerHostView: UIView {
    private var hosted: CALayer?
    func host(_ l: CALayer) { layer.addSublayer(l); hosted = l }
    override func layoutSubviews() { super.layoutSubviews(); hosted?.frame = bounds }
}
