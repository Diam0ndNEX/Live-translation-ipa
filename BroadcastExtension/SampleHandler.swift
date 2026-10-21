// Screen Translator – Broadcast extension – v0.5.0
import ReplayKit
import Vision
import ImageIO
import CoreImage
import Network
import os

class SampleHandler: RPBroadcastSampleHandler {
    private var conn: NWConnection?
    private var frames = 0
    private var lastRun = Date.distantPast
    private var lastPing = Date.distantPast
    private var candidateKey = ""
    private var sentKey = ""
    private var emptyPasses = 0
    private var lastOcrMs: Double = 0

    private let cfgLock = NSLock()
    private var _config = Config(lang: "auto", y0: 0, y1: 1, maxEdge: 1400, interval: 0.25, paused: false)
    private var config: Config {
        get { cfgLock.lock(); defer { cfgLock.unlock() }; return _config }
        set { cfgLock.lock(); _config = newValue; cfgLock.unlock() }
    }

    private lazy var recognitionLanguages: [String] = {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .accurate
        return (try? r.supportedRecognitionLanguages()) ?? []
    }()

    // MARK: Lifecycle
    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let c = NWConnection(host: NWEndpoint.Host("127.0.0.1"),
                             port: NWEndpoint.Port(rawValue: Loopback.port)!, using: .udp)
        c.start(queue: .global(qos: .utility))
        conn = c
        listen()
        send(kind: "ping", lines: [])
    }

    override func broadcastFinished() { conn?.cancel() }

    /// The app sends settings back over the same link.
    private func listen() {
        conn?.receiveMessage { [weak self] data, _, _, error in
            if let data, let cfg = try? JSONDecoder().decode(Config.self, from: data) { self?.config = cfg }
            if error == nil { self?.listen() }
        }
    }

    // MARK: Frames
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }
        frames += 1
        let now = Date()
        if now.timeIntervalSince(lastPing) > 2 { lastPing = now; send(kind: "ping", lines: []) }

        let cfg = config
        guard !cfg.paused, now.timeIntervalSince(lastRun) >= cfg.interval,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var orientation = CGImagePropertyOrientation.up
        if let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                   attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: n.uint32Value) {
            orientation = o
        }
        autoreleasepool { recognize(pb, orientation, cfg) }
        lastRun = Date()
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
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .accurate
        r.usesLanguageCorrection = true
        r.minimumTextHeight = Float(min(0.1, 0.01 / max(0.1, span)))
        if let langs = visionLanguages(for: cfg.lang) {
            r.automaticallyDetectsLanguage = false
            r.recognitionLanguages = langs
        } else {
            r.automaticallyDetectsLanguage = true
            if !recognitionLanguages.isEmpty { r.recognitionLanguages = recognitionLanguages }
        }
        return r
    }

    /// `y0`/`y1` = the part of the full frame this (cropped) image covers.
    private func ocr(_ img: CIImage, _ cfg: Config, _ y0: Double, _ y1: Double) -> [OCRLine] {
        let span = y1 - y0
        let req = makeRequest(cfg, span: span)
        let handler = VNImageRequestHandler(ciImage: img, options: [:])
        guard (try? handler.perform([req])) != nil, let results = req.results else { return [] }

        var lines = results.compactMap { obs -> OCRLine? in
            guard let c = obs.topCandidates(1).first, c.confidence >= 0.3, c.string.count >= 2,
                  c.string.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            let b = obs.boundingBox
            let y = y0 + Double(b.midY) * span
            guard y < 0.96 else { return nil }
            return OCRLine(t: c.string, x: Double(b.midX), y: y, h: Double(b.height) * span, w: Double(b.width))
        }
        lines.sort { abs($0.y - $1.y) > 0.015 ? $0.y > $1.y : $0.x < $1.x }
        return lines
    }

    private func freeMB() -> Double { Double(os_proc_available_memory()) / 1_048_576 }

    private func recognize(_ pb: CVPixelBuffer, _ orientation: CGImagePropertyOrientation, _ cfg: Config) {
        let t0 = CFAbsoluteTimeGetCurrent()

        // Only read the chosen area, at reduced size: this is the big speed-up.
        let margin = 0.03
        let y0 = max(0, cfg.y0 - margin), y1 = min(1, cfg.y1 + margin)
        var edge = cfg.maxEdge
        if freeMB() < 15 { edge = min(edge, 800) }          // memory getting tight

        let base = CIImage(cvPixelBuffer: pb).oriented(orientation)
        let ext = base.extent
        let crop = CGRect(x: ext.minX, y: ext.minY + ext.height * y0,
                          width: ext.width, height: ext.height * (y1 - y0))
        var img = base.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let longEdge = max(crop.width, crop.height)
        if longEdge > edge {
            let s = edge / longEdge
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }

        var lines = ocr(img, cfg, y0, y1)
        if lines.isEmpty {
            emptyPasses += 1
            // Fallback for hard text (thin, outlined, low contrast): boost contrast and retry
            if emptyPasses % 3 == 0 && freeMB() > 20 {
                let boosted = img
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.8])
                    .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.8])
                lines = ocr(boosted, cfg, y0, y1)
            }
        } else {
            emptyPasses = 0
        }
        lastOcrMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        if lines.isEmpty {
            if emptyPasses >= 4 {
                if !sentKey.isEmpty { send(kind: "clear", lines: []) }
                sentKey = ""; candidateKey = ""
            }
            return
        }

        // Stability: send once the same text was read twice in a row (skips half-faded text).
        let key = lines.map(\.t).joined(separator: " ")
        if TextSim.similar(key, sentKey) { candidateKey = key; return }
        if TextSim.similar(key, candidateKey) {
            sentKey = key
            send(kind: "ocr", lines: Array(lines.prefix(60)))
        } else {
            candidateKey = key
        }
    }

    // MARK: Send
    private func send(kind: String, lines: [OCRLine]) {
        func encode(_ l: [OCRLine]) -> Data? {
            try? JSONEncoder().encode(Packet(kind: kind, version: AppVersion.version, frames: frames, lines: l,
                                             ocrMs: lastOcrMs, memFreeMB: freeMB()))
        }
        var data = encode(lines)
        if let d = data, d.count > 60000 { data = encode(Array(lines.prefix(30))) }
        guard let d = data else { return }
        conn?.send(content: d, completion: .contentProcessed { _ in })
    }
}
