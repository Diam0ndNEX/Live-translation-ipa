import ReplayKit
import Vision
import ImageIO
import CoreImage
import Network
import os
import os.signpost

extension SampleHandler {
    // MARK: Cheap change detection
    func signature(_ pb: CVPixelBuffer, config cfg: Config, oriented: CGImagePropertyOrientation) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pb)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb) else { return [] }
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        let bpp = planar ? 1 : 4
        guard w > 8, h > 8 else { return [] }
        // The ROI uses bottom-origin screen coordinates. Use full-frame
        // sampling for rotated captures to avoid an incorrect region.
        let focused = cfg.subtitleAwareChangeDetection == true &&
            oriented == .up && (cfg.rot ?? 0) == 0
        let low = focused ? max(0, min(0.95, 1 - cfg.y1 - 0.03)) : 0
        let high = focused ? max(low + 0.05, min(1, 1 - cfg.y0 + 0.03)) : 1
        let firstY = Int(Double(h - 1) * low)
        let lastY = Int(Double(h - 1) * high)
        let cols = focused ? 48 : 24
        var out: [UInt8] = []
        out.reserveCapacity(cols * 24)
        let bgra = !planar && CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA
        for gy in 0..<24 {
            let row = base.advanced(by: (firstY + (gy * (lastY - firstY)) / 23) * stride)
            for gx in 0..<cols {
                let offset = ((gx * (w - 1)) / (cols - 1)) * bpp
                if bgra {
                    let blue = Int(row.load(fromByteOffset: offset, as: UInt8.self))
                    let green = Int(row.load(fromByteOffset: offset + 1, as: UInt8.self))
                    let red = Int(row.load(fromByteOffset: offset + 2, as: UInt8.self))
                    out.append(UInt8((red * 77 + green * 150 + blue * 29) >> 8))
                } else {
                    out.append(row.load(fromByteOffset: offset, as: UInt8.self))
                }
            }
        }
        return out
    }

    func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var d = 0
        for i in 0..<a.count { d += abs(Int(a[i]) - Int(b[i])) }
        return Double(d) / Double(max(1, a.count))
    }

    // MARK: OCR
    /// Maps an app language code (pt, zh-Hans, ja…) to a Vision recognition language.
    private func visionLanguages(for code: String) -> [String]? {
        guard code != "auto", !recognitionLanguages.isEmpty else { return nil }
        let lc = code.lowercased()
        let base = lc.split(separator: "-").first.map(String.init) ?? lc
        let match = recognitionLanguages.first { $0.lowercased() == lc }
            ?? recognitionLanguages.first { $0.lowercased() == base || $0.lowercased().hasPrefix(base + "-") }
        guard let m = match else { return nil }
        return m.lowercased().hasPrefix("en") ? [m] : [m, "en-US"]
    }

    private func makeRequest(_ cfg: Config, span: Double) -> VNRecognizeTextRequest {
        let fast = cfg.fastOCR == true
        let key = "\(cfg.lang)|\(cfg.correction ?? true)|\(span)|\(fast)"
        if key == cachedRequestKey, let request = cachedRequest { return request }
        let r = VNRecognizeTextRequest()
        // v2.0.0 G3 experiment: .fast without language correction. A report
        // on Apple's forums describes an iOS 27 .accurate regression; .fast
        // was unaffected there. Accuracy for each language is unverified.
        r.recognitionLevel = fast ? .fast : .accurate
        r.usesLanguageCorrection = fast ? false : (cfg.correction ?? true)
        r.minimumTextHeight = Float(min(0.1, 0.01 / max(0.1, span)))
        if let langs = visionLanguages(for: cfg.lang) {
            r.automaticallyDetectsLanguage = false
            r.recognitionLanguages = langs
        } else {
            r.automaticallyDetectsLanguage = true
            if !recognitionLanguages.isEmpty { r.recognitionLanguages = recognitionLanguages }
        }
        cachedRequest = r
        cachedRequestKey = key
        return r
    }

    /// `y0`/`y1` = the part of the full frame this (cropped) image covers.
    func ocr(_ img: CIImage, _ cfg: Config, _ y0: Double, _ y1: Double) -> [OCRLine] {
        let span = y1 - y0
        let req = makeRequest(cfg, span: span)
        let handler = VNImageRequestHandler(ciImage: img, options: [:])
        guard (try? handler.perform([req])) != nil, let results = req.results else { return [] }

        var lines = results.compactMap { obs -> OCRLine? in
            guard let c = obs.topCandidates(1).first, c.confidence >= Float(min(0.95, max(0.1, cfg.confidence ?? 0.3))),
                  c.string.count >= 2 || (cfg.cjkSingleCharacters == true && CJKText.isSingleCJKWord(c.string)),
                  c.string.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            let b = obs.boundingBox
            let y = y0 + Double(b.midY) * span
            guard y < 0.96 else { return nil }
            return OCRLine(t: c.string, x: Double(b.midX), y: y, h: Double(b.height) * span, w: Double(b.width), confidence: Double(c.confidence))
        }
        lines.sort { $0.y != $1.y ? $0.y > $1.y : $0.x < $1.x }
        return lines
    }

    /// 2.5.0 (item F): a quick read of the image the normal read is about to use. Nil when the fast recognizer does
    /// not support the selected language. Same confidence and length rules as `ocr`; no language correction.
    func fastPass(_ img: CIImage, _ cfg: Config, _ y0: Double, _ y1: Double) -> [OCRLine]? {
        let span = y1 - y0
        var languages: [String]?
        if cfg.lang != "auto" {
            let lc = cfg.lang.lowercased()
            let base = lc.split(separator: "-").first.map(String.init) ?? lc
            guard let match = fastRecognitionLanguages.first(where: { $0.lowercased() == lc })
                ?? fastRecognitionLanguages.first(where: { $0.lowercased() == base || $0.lowercased().hasPrefix(base + "-") })
            else { return nil }
            languages = [match]
        }
        let key = "\(cfg.lang)|\(span)"
        let request: VNRecognizeTextRequest
        if key == cachedFastRequestKey, let cached = cachedFastRequest {
            request = cached
        } else {
            let created = VNRecognizeTextRequest()
            created.recognitionLevel = .fast
            created.usesLanguageCorrection = false
            created.minimumTextHeight = Float(min(0.1, 0.01 / max(0.1, span)))
            if let languages { created.recognitionLanguages = languages }
            cachedFastRequest = created
            cachedFastRequestKey = key
            request = created
        }
        let handler = VNImageRequestHandler(ciImage: img, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        let minimum = Float(min(0.95, max(0.1, cfg.confidence ?? 0.3)))
        var lines: [OCRLine] = []
        for observation in results {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= minimum else { continue }
            let text = candidate.string
            guard text.count >= 2 || (cfg.cjkSingleCharacters == true && CJKText.isSingleCJKWord(text)),
                  text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            let box = observation.boundingBox
            let y = y0 + Double(box.midY) * span
            guard y < 0.96 else { continue }
            lines.append(OCRLine(t: text, x: Double(box.midX), y: y, h: Double(box.height) * span,
                                 w: Double(box.width), confidence: Double(candidate.confidence)))
        }
        lines.sort { $0.y != $1.y ? $0.y > $1.y : $0.x < $1.x }
        return lines
    }

    func freeMB() -> Double { Double(os_proc_available_memory()) / 1_048_576 }

    func enhanced(_ i: CIImage) -> CIImage {
        i.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.8])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.8])
    }
}
