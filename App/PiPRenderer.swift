import AVKit
import UIKit
import SwiftUI

/// Draws translated text into frames and feeds them to a system Picture-in-Picture window.
final class PiPRenderer: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var pip: AVPictureInPictureController?
    private let size = CGSize(width: 720, height: 360)
    private var lastFrame: CGImage?
    private var heartbeat: Timer?

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
        pip?.requiresLinearPlayback = true
        pip?.canStartPictureInPictureAutomaticallyFromInline = true

        render(original: "", translated: "Waiting for screen text…")
        // PiP needs a steady stream of frames or it shows a spinner / stalls.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let f = self.lastFrame else { return }
            self.enqueue(f)
        }
    }

    func start() { if let pip, pip.isPictureInPicturePossible { pip.startPictureInPicture() } }
    func stop() { pip?.stopPictureInPicture() }

    // MARK: Rendering
    func render(original: String, translated: String) {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1; fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor(white: 0.05, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let w = size.width - 48
            NSAttributedString(string: original, attributes: [
                .font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.lightGray
            ]).draw(with: CGRect(x: 24, y: 16, width: w, height: 90),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            let n = translated.count
            let fs: CGFloat = n > 160 ? 24 : (n > 80 ? 30 : 38)
            NSAttributedString(string: translated, attributes: [
                .font: UIFont.systemFont(ofSize: fs, weight: .bold), .foregroundColor: UIColor.white
            ]).draw(with: CGRect(x: 24, y: 120, width: w, height: 224),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
        guard let cg = img.cgImage else { return }
        lastFrame = cg
        enqueue(cg)
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
