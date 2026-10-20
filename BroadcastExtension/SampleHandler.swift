// Screen Translator – Broadcast extension – v0.2.0
import ReplayKit
import Vision
import ImageIO
import Network

class SampleHandler: RPBroadcastSampleHandler {
    private var conn: NWConnection?
    private var frames = 0
    private var lastRun = Date.distantPast
    private var lastPing = Date.distantPast
    private var lastText = ""
    private let interval: TimeInterval = 0.8
    // If the broadcast dies from memory pressure (~50 MB limit), change to .fast
    private let level: VNRequestTextRecognitionLevel = .accurate

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

    private func recognize(_ pb: CVPixelBuffer, _ orientation: CGImagePropertyOrientation) {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        req.minimumTextHeight = 0.012

        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation)
        guard (try? handler.perform([req])) != nil, let results = req.results else { return }

        var lines: [OCRLine] = results.compactMap { obs in
            guard obs.boundingBox.midY < 0.95,
                  let c = obs.topCandidates(1).first, c.confidence >= 0.4, c.string.count >= 2 else { return nil }
            let b = obs.boundingBox
            return OCRLine(t: c.string, x: b.midX, y: b.midY, h: b.height)
        }
        lines.sort {
            abs($0.y - $1.y) > 0.015 ? $0.y > $1.y : $0.x < $1.x
        }
        let key = lines.map(\.t).joined(separator: "|")
        guard !lines.isEmpty, key != lastText else { return }
        lastText = key
        send(kind: "ocr", lines: Array(lines.prefix(80)))
    }

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
