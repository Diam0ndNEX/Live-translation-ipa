import ReplayKit
import Vision
import ImageIO
import CoreImage
import Network
import os
import os.signpost

extension SampleHandler {
    /// Fingerprints the text boxes of a first read on the frame that was read.
    func preparePixelConfirmation(_ pb: CVPixelBuffer, _ orientation: CGImagePropertyOrientation,
                                          _ cfg: Config, lines: [OCRLine]) {
        let boxes = lines.map { (x: $0.x, y: $0.y, w: $0.w ?? 0, h: $0.h) }
        guard let points = PixelConfirmation.samplePoints(lines: boxes),
              let luma = sampleLuma(pb, orientation: orientation, rot: cfg.rot ?? 0, points: points),
              let fingerprint = PixelConfirmation.fingerprint(luma) else {
            pendingPixelRead = nil
            return
        }
        pendingPixelRead = PendingPixelRead(lines: lines, points: points, fingerprint: fingerprint,
            readStart: readStartedMonotonic, context: pixelContext(orientation, cfg))
    }

    private func pixelContext(_ orientation: CGImagePropertyOrientation, _ cfg: Config) -> String {
        "\(orientation.rawValue)|\(cfg.rot ?? 0)|\(cfg.rev ?? 0)|\(cfg.lang)|\(cfg.y0)|\(cfg.y1)"
    }

    /// Returns true when this frame was used (confirmed, or kept pending for a
    /// stricter stability setting), so no OCR pass is needed on it.
    func pixelConfirm(_ sampleBuffer: CMSampleBuffer, _ cfg: Config, interval: Double) -> Bool {
        guard var pending = pendingPixelRead else { return false }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastPixelCheck >= 0.03 else { return false }
        lastPixelCheck = uptime
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
        var orientation = CGImagePropertyOrientation.up
        if let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                   attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: n.uint32Value) {
            orientation = o
        }
        let frame = pb
        guard pending.context == pixelContext(orientation, cfg),
              let luma = sampleLuma(pb, orientation: orientation, rot: cfg.rot ?? 0, points: pending.points),
              PixelConfirmation.matches(pending.fingerprint, luma) else {
            // Changed or unverifiable: the normal OCR cadence decides.
            pendingPixelRead = nil
            pixelRejections += 1
            confirmPixelRejections += 1
            return false
        }
        guard PixelConfirmation.dwellSatisfied(sinceFirstReadStart: uptime - pending.readStart,
                                               interval: interval) else { return false }
        readStartedAt = Date().timeIntervalSince1970
        readStartedMonotonic = uptime
        switch admit(pending.lines, cfg) {
        case .ready:
            pixelConfirmations += 1
            confirmationReason = "pixel_verified"
            pendingPixelRead = nil
            if cfg.eventDrivenOCR == true { startCaptionWatch(frame, orientation, cfg, lines: pending.lines) }
        case .pending:
            pending.readStart = uptime
            pendingPixelRead = pending
        case .duplicate:
            pendingPixelRead = nil
        }
        return true
    }

    func startCaptionWatch(_ pb: CVPixelBuffer, _ orientation: CGImagePropertyOrientation,
                                   _ cfg: Config, lines: [OCRLine]) {
        let boxes = lines.map { (x: $0.x, y: $0.y, w: $0.w ?? 0, h: $0.h) }
        guard let points = PixelConfirmation.samplePoints(lines: boxes),
              let luma = sampleLuma(pb, orientation: orientation, rot: cfg.rot ?? 0, points: points),
              let fingerprint = PixelConfirmation.fingerprint(luma) else {
            captionWatch = nil
            return
        }
        captionWatch = CaptionWatch(points: points, fingerprint: fingerprint, context: pixelContext(orientation, cfg))
    }

    func watchCaption(_ sampleBuffer: CMSampleBuffer, _ cfg: Config) -> WatchResult {
        guard let watch = captionWatch else { return .notChecked }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastWatchCheck >= 0.03 else { return .notChecked }
        lastWatchCheck = uptime
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return .notChecked }
        var orientation = CGImagePropertyOrientation.up
        if let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                   attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: n.uint32Value) {
            orientation = o
        }
        guard watch.context == pixelContext(orientation, cfg),
              let luma = sampleLuma(pb, orientation: orientation, rot: cfg.rot ?? 0, points: watch.points),
              PixelConfirmation.matches(watch.fingerprint, luma) else {
            captionWatch = nil
            return .changed
        }
        return .unchanged
    }

    /// Luminance at normalized points of the oriented (OCR) image, read from
    /// the raw buffer through the inverse of the same orientation transforms.
    private func sampleLuma(_ pb: CVPixelBuffer, orientation: CGImagePropertyOrientation, rot: Int,
                            points: [(x: Double, y: Double)]) -> [UInt8]? {
        let raw = CIImage(cvPixelBuffer: pb)
        let extra = [CGImagePropertyOrientation.up, .right, .down, .left][rot & 3]
        let first = raw.orientationTransform(for: orientation)
        let middle = raw.transformed(by: first)
        let second = middle.orientationTransform(for: extra)
        let transform = first.concatenating(second)
        let extent = raw.extent.applying(transform)
        let inverse = transform.inverted()
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pb)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        let bgra = !planar && CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA
        guard planar || bgra, w > 8, h > 8, extent.width > 0, extent.height > 0 else { return nil }
        // Raw CI coordinates are in plane-0 pixels for 4:2:0 and BGRA buffers.
        let scaleX = Double(w) / Double(raw.extent.width), scaleY = Double(h) / Double(raw.extent.height)
        var out = [UInt8]()
        out.reserveCapacity(points.count)
        for point in points {
            let oriented = CGPoint(x: extent.minX + point.x * extent.width, y: extent.minY + point.y * extent.height)
            let source = oriented.applying(inverse)
            let column = min(w - 1, max(0, Int((Double(source.x) - Double(raw.extent.minX)) * scaleX)))
            let rowFromBottom = min(h - 1, max(0, Int((Double(source.y) - Double(raw.extent.minY)) * scaleY)))
            let row = base.advanced(by: (h - 1 - rowFromBottom) * stride)
            if bgra {
                let offset = column * 4
                let blue = Int(row.load(fromByteOffset: offset, as: UInt8.self))
                let green = Int(row.load(fromByteOffset: offset + 1, as: UInt8.self))
                let red = Int(row.load(fromByteOffset: offset + 2, as: UInt8.self))
                out.append(UInt8((red * 77 + green * 150 + blue * 29) >> 8))
            } else {
                out.append(row.load(fromByteOffset: column, as: UInt8.self))
            }
        }
        return out
    }
}
