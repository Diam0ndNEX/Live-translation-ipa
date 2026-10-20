// Screen Translator – Broadcast extension – v0.4.0
import ReplayKit
import Vision
import ImageIO
import CoreImage
import Network

class SampleHandler: RPBroadcastSampleHandler {
    private var conn: NWConnection?
    private var frames = 0
    private var lastRun = Date.distantPast
    private var lastPing = Date.distantPast
    private var candidateKey = ""
    private var sentKey = ""
    private var emptyPasses = 0
    private let interval: TimeInterval = 0.5
    // If the broadcast dies from memory pressure (~50 MB limit), change to .fast
    private let level: VNRequestTextRecognitionLevel = .accurate

    private lazy var recognitionLanguages: [String] = {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .accurate
        return (try? r.supportedRecognitionLanguages()) ?? []
    }()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let c = NWConnection(host: NWEndpoint.Host("127.0.0.1"),
                             port: NWEndpoint.Port(rawValue: Loopback.port)!, using: .udp)
        c.start(queue: .global(qos: .utility))
        conn = c
        send(kind: "ping", lines: [])
    }

    override func broadcastFinished() { conn?.cancel() }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }
        frames += 1
        let now = Date()
        if now.timeIntervalSince(lastPing) > 2 { lastPing = now; send(kind: "ping", lines: []) }
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

    // MARK: OCR
    private func makeRequest() -> VNRecognizeTextRequest {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = level
        r.usesLanguageCorrection = true
        r.automaticallyDetectsLanguage = true
        r.minimumTextHeight = 0.01
        if !recognitionLanguages.isEmpty { r.recognitionLanguages = recognitionLanguages }
        return r
    }

    private func ocr(_ handler: VNImageRequestHandler) -> [OCRLine] {
        let req = makeRequest()
        guard (try? handler.perform([req])) != nil, let results = req.results else { return [] }
        var lines = results.compactMap { obs -> OCRLine? in
            guard obs.boundingBox.midY < 0.96,
                  let c = obs.topCandidates(1).first, c.confidence >= 0.3, c.string.count >= 2,
                  c.string.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            let b = obs.boundingBox
            return OCRLine(t: c.string, x: b.midX, y: b.midY, h: b.height)
        }
        lines.sort { abs($0.y - $1.y) > 0.015 ? $0.y > $1.y : $0.x < $1.x }
        return lines
    }

    private func recognize(_ pb: CVPixelBuffer, _ orientation: CGImagePropertyOrientation) {
        var lines = ocr(VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation))

        if lines.isEmpty {
            emptyPasses += 1
            // Fallback for hard text (thin, outlined, low contrast): boost contrast and try again
            if emptyPasses % 3 == 0 {
                let boosted = CIImage(cvPixelBuffer: pb)
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.8])
                    .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.8])
                lines = ocr(VNImageRequestHandler(ciImage: boosted, orientation: orientation))
            }
        } else {
            emptyPasses = 0
        }
        if lines.isEmpty {
            if emptyPasses >= 3 { sentKey = ""; candidateKey = "" }
            return
        }

        // Stability check: only send once the same text has been read twice in a row,
        // so fading / typing-in text isn't translated half-finished.
        let key = lines.map(\.t).joined(separator: " ")
        if similar(key, sentKey) { candidateKey = key; return }
        if similar(key, candidateKey) {
            sentKey = key
            send(kind: "ocr", lines: Array(lines.prefix(80)))
        } else {
            candidateKey = key
        }
    }

    private func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.isEmpty || b.isEmpty { return false }
        func grams(_ s: String) -> Set<String> {
            let c = Array(s.lowercased().filter { $0.isLetter || $0.isNumber })
            guard c.count > 1 else { return [String(c)] }
            return Set((0..<(c.count - 1)).map { String(c[$0...($0 + 1)]) })
        }
        let x = grams(a), y = grams(b)
        let uni = x.union(y).count
        return uni > 0 && Double(x.intersection(y).count) / Double(uni) >= 0.85
    }

    // MARK: Send
    private func send(kind: String, lines: [OCRLine]) {
        var l = lines
        var data = try? JSONEncoder().encode(Packet(kind: kind, version: AppVersion.version, frames: frames, lines: l))
        if let d = data, d.count > 60000 {
            l = Array(l.prefix(30))
            data = try? JSONEncoder().encode(Packet(kind: kind, version: AppVersion.version, frames: frames, lines: l))
        }
        guard let d = data else { return }
        conn?.send(content: d, completion: .contentProcessed { _ in })
    }
}
