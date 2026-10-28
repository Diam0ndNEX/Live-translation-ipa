// Screen Translator – App – v0.9.0
import AVKit
import UIKit
import SwiftUI
import os
import os.signpost

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
    case small, auto, large, huge
    var id: String { rawValue }
    var title: String {
        switch self { case .small: "Small"; case .auto: "Auto"; case .large: "Large"; case .huge: "Huge" }
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
    var weight: UIFont.Weight = .bold
    var alignment: NSTextAlignment = .left
    var lineSpacing: CGFloat = 0
    var padding: CGFloat = 24
    var originalFraction: CGFloat = 0.27

    static func make(theme: PiPTheme, size: PiPTextSize, font: PiPFont = .standard) -> PiPStyle {
        let hi: CGFloat, lo: CGFloat
        switch size {
        case .small: hi = 32; lo = 12
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
        let settings = UserDefaults.standard
        let scale = max(0.75, min(1.5, (settings.object(forKey: "pipScale") as? Double) ?? 1))
        st.hi *= CGFloat(scale); st.lo *= CGFloat(scale)
        switch settings.string(forKey: "pipWeight") ?? "bold" {
        case "regular": st.weight = .regular
        case "medium": st.weight = .medium
        default: st.weight = .bold
        }
        switch settings.string(forKey: "pipAlignment") ?? "left" {
        case "center": st.alignment = .center
        case "right": st.alignment = .right
        default: st.alignment = .left
        }
        st.lineSpacing = CGFloat(max(0, min(16, (settings.object(forKey: "pipLineSpacing") as? Double) ?? 0)))
        st.padding = CGFloat(max(12, min(48, (settings.object(forKey: "pipPadding") as? Double) ?? 24)))
        st.originalFraction = CGFloat(max(0.15, min(0.4, (settings.object(forKey: "originalFraction") as? Double) ?? 0.27)))
        switch settings.string(forKey: "speakerAccent") ?? "blue" {
        case "mint": st.accent = .systemMint
        case "purple": st.accent = .systemPurple
        case "amber": st.accent = .systemOrange
        default: break
        }
        return st
    }
}

/// Draws translated text into frames and feeds them to a system Picture-in-Picture window.
final class PiPRenderer: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var pip: AVPictureInPictureController?
    private var size = CGSize(width: 720, height: 360)
    private let perf = OSSignposter(subsystem: "com.diam0ndnex.screenlingo", category: "presentation")
    private var frameBuffer: CVPixelBuffer?
    private var frameFormat: CMVideoFormatDescription?
    private var framePool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
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
        configureHeartbeat()
    }

    func configureHeartbeat() {
        heartbeat?.invalidate()
        let interval = max(0.5, min(2, (UserDefaults.standard.object(forKey: "heartbeatInterval") as? Double) ?? 1))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.enqueueCurrentFrame(heartbeat: true) }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
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

    func rerender(showOriginal: Bool? = nil) {
        render(original: lastOriginal, translated: lastTranslated, showOriginal: showOriginal ?? lastShowOriginal)
    }

    // MARK: Rendering
    @discardableResult
    func render(original: String, translated: String, showOriginal: Bool,
                size newSize: CGSize? = nil) -> Bool {
        if let newSize { size = newSize }
        let marker = perf.beginInterval("PiPFrame")
        defer { perf.endInterval("PiPFrame", marker) }
        let prepared: Bool
        if UserDefaults.standard.bool(forKey: "directPiPBuffer") {
            prepared = prepareDirectFrame(original: original, translated: translated, showOriginal: showOriginal)
        } else {
            let img = PiPRenderer.image(original: original, translated: translated, showOriginal: showOriginal,
                                        size: size, style: style)
            prepared = img.cgImage.map { prepareFrame($0) } ?? false
        }
        guard prepared, enqueueCurrentFrame() else { return false }
        lastOriginal = original; lastTranslated = translated; lastShowOriginal = showOriginal
        return true
    }

    /// Draws the floating-window picture. Also used for settings previews and "share as image".
    static func image(original: String, translated: String, showOriginal: Bool,
                      size: CGSize, style: PiPStyle) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1; fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            draw(original: original, translated: translated, showOriginal: showOriginal,
                 size: size, style: style, context: ctx.cgContext)
        }
    }

    private static func draw(original: String, translated: String, showOriginal: Bool,
                             size: CGSize, style: PiPStyle, context: CGContext) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        style.bg.setFill()
        context.fill(CGRect(origin: .zero, size: size))
            let w = size.width - style.padding * 2
            var y: CGFloat = 16
            if showOriginal && !original.isEmpty {
                let r = CGRect(x: style.padding, y: y, width: w, height: size.height * style.originalFraction)
                let f = fittingFont(original, rect: r, weight: .regular, hi: 22, lo: 12, style: style)
                NSAttributedString(string: original, attributes: [.font: f, .foregroundColor: style.secondary, .paragraphStyle: paragraphStyle(style)])
                    .draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
                y = r.maxY + 10
            }
            let r2 = CGRect(x: style.padding, y: y, width: w, height: size.height - y - 16)
            let f2 = fittingFont(translated, rect: r2, weight: style.weight, hi: style.hi, lo: style.lo, style: style)
            let att = NSMutableAttributedString(string: translated, attributes: [.font: f2, .foregroundColor: style.fg, .paragraphStyle: paragraphStyle(style)])
            if style.highlightNames, let rx = PiPRenderer.labelRegex {
                for m in rx.matches(in: translated, range: NSRange(location: 0, length: (translated as NSString).length)) {
                    att.addAttribute(.foregroundColor, value: style.accent, range: m.range(at: 1))
                }
            }
            att.draw(with: r2, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private static func fittingFont(_ text: String, rect: CGRect, weight: UIFont.Weight,
                                    hi: CGFloat, lo: CGFloat, style: PiPStyle) -> UIFont {
        let paragraph = paragraphStyle(style)
        let size = FontSearch.size(high: Double(hi), low: Double(lo)) { value in
            let font = makeFont(CGFloat(value), weight, style)
            let bounds = (text as NSString).boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                                       options: .usesLineFragmentOrigin, attributes: [.font: font, .paragraphStyle: paragraph], context: nil)
            return bounds.height <= rect.height
        }
        return makeFont(CGFloat(size), weight, style)
    }

    private static func paragraphStyle(_ style: PiPStyle) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment
        paragraph.lineSpacing = style.lineSpacing
        return paragraph
    }

    private static func makeFont(_ size: CGFloat, _ weight: UIFont.Weight, _ style: PiPStyle) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(style.design) { return UIFont(descriptor: d, size: size) }
        return base
    }

    /// Experimental direct render: reuse the pixel-buffer pool, avoid UIImage
    /// creation and its subsequent CGContext copy. The default UIImage path
    /// remains available as an immediate fallback in settings.
    private func prepareDirectFrame(original: String, translated: String, showOriginal: Bool) -> Bool {
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        let dimensions = CGSize(width: w, height: h)
        if framePool == nil || poolSize != dimensions {
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            framePool = pool
            poolSize = dimensions
            frameFormat = nil
        }
        var pb: CVPixelBuffer?
        if let pool = framePool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        }
        if pb == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]]
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                attrs as CFDictionary, &pb)
        }
        guard let pb else { return false }
        CVPixelBufferLockBaseAddress(pb, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                    CGBitmapInfo.byteOrder32Little.rawValue)
        if let context {
            // Match UIKit's top-left coordinate system.
            context.translateBy(x: 0, y: CGFloat(h))
            context.scaleBy(x: 1, y: -1)
            Self.draw(original: original, translated: translated, showOriginal: showOriginal,
                      size: dimensions, style: style, context: context)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        guard context != nil else { return false }
        var fmt = frameFormat
        if let previous = frameBuffer,
           CVPixelBufferGetWidth(previous) != w || CVPixelBufferGetHeight(previous) != h {
            fmt = nil
        }
        if fmt == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
        }
        guard let fmt else { return false }
        frameBuffer = pb
        frameFormat = fmt
        return true
    }

    @discardableResult
    private func enqueueCurrentFrame(heartbeat: Bool = false) -> Bool {
        let r = displayLayer.sampleBufferRenderer
        if r.status == .failed { r.flush() }
        // Only avoid redundant heartbeat frames when the display queue is full.
        // Newly translated subtitles must still be enqueued immediately.
        if heartbeat && !r.isReadyForMoreMediaData { return true }
        guard let sb = makeSampleBuffer() else { return false }
        r.enqueue(sb)
        return r.status != .failed
    }

    private func prepareFrame(_ cg: CGImage) -> Bool {
        var pb: CVPixelBuffer?
        let dimensions = CGSize(width: cg.width, height: cg.height)
        if framePool == nil || poolSize != dimensions {
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: cg.width, kCVPixelBufferHeightKey: cg.height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            framePool = pool; poolSize = dimensions
        }
        if let framePool { CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, framePool, &pb) }
        // An allocation failure must not turn a scheduling optimization into a
        // reliability regression. Buffers already enqueued are never redrawn.
        if pb == nil {
            let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                         kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                         kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            CVPixelBufferCreate(kCFAllocatorDefault, cg.width, cg.height, kCVPixelFormatType_32BGRA, attrs, &pb)
        }
        guard let pb else { return false }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))

        var fmt = frameFormat
        if let previous = frameBuffer,
           CVPixelBufferGetWidth(previous) != cg.width || CVPixelBufferGetHeight(previous) != cg.height {
            fmt = nil
        }
        if fmt == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
        }
        guard let fmt else { return false }
        frameBuffer = pb
        frameFormat = fmt
        return true
    }

    private func makeSampleBuffer() -> CMSampleBuffer? {
        guard let pb = frameBuffer, let fmt = frameFormat else { return nil }
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

