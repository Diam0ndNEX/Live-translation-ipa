import ReplayKit
import Vision
import ImageIO

/// Runs inside the broadcast extension: grabs frames, OCRs them, hands text to the main app.
class SampleHandler: RPBroadcastSampleHandler {
    private var lastRun = Date.distantPast
    private var lastText = ""
    private let interval: TimeInterval = 0.8          // seconds between OCR passes
    // If the broadcast dies from memory pressure (~50 MB limit), change to .fast
    private let level: VNRequestTextRecognitionLevel = .accurate

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRun) >= interval,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastRun = now

        var orientation = CGImagePropertyOrientation.up
        if let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                   attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: n.uint32Value) {
            orientation = o
        }
        recognize(pb, orientation)
    }

    private func recognize(_ pb: CVPixelBuffer, _ orientation: CGImagePropertyOrientation) {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        req.minimumTextHeight = 0.012

        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation)
        guard (try? handler.perform([req])) != nil, let results = req.results else { return }

        let sorted = results
            .filter { $0.boundingBox.midY < 0.95 }            // skip status bar
            .sorted {
                abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.015
                    ? $0.boundingBox.midY > $1.boundingBox.midY
                    : $0.boundingBox.minX < $1.boundingBox.minX
            }
        let lines = sorted.compactMap { obs -> String? in
            guard let c = obs.topCandidates(1).first, c.confidence >= 0.5, c.string.count >= 2 else { return nil }
            return c.string
        }
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty, text != lastText else { return }
        lastText = text

        guard let url = Shared.fileURL,
              let data = try? JSONEncoder().encode(OCRPayload(text: text, stamp: Date().timeIntervalSince1970))
        else { return }
        try? data.write(to: url, options: .atomic)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(Shared.notifyName as CFString),
                                             nil, nil, true)
    }
}
