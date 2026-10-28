// Screen Translator – Broadcast extension – v0.11.0
import ReplayKit
import Vision
import ImageIO
import CoreImage
import Network
import os

class SampleHandler: RPBroadcastSampleHandler {
    private var conn: NWConnection?
    private let recognitionLock = NSLock()
    private var frames = 0
    private var passes = 0
    private var skipped = 0
    private var lastRun = Date.distantPast
    private var readStartedAt = 0.0
    private var candidateStartedAt = 0.0
    private var lastPing = Date.distantPast
    private var candidateKey = ""
    private var sentKey = ""
    private var candidateCount = 0
    private var specKey = ""
    private var lastOCRConfig: Config?
    private var emptyReads = OCREmptyReadStreak()
    private var lastOcrMs: Double = 0
    // Recognition callbacks are serialized by recognitionLock. Reuse only the
    // request configuration; Vision replaces results on every perform call.
    private var cachedRequest: VNRecognizeTextRequest?
    private var cachedRequestKey = ""
    private var lastUsefulText = Date()
    private var ocrSig: [UInt8] = []
    private let perf = OSSignposter(subsystem: "com.diam0ndnex.screenlingo", category: "capture")
    private var tracker = SubtitleTracker()
    private let captureID = UUID().uuidString
    private var candidateID: String?
    private var recognitionReason = "fixed preset"
    private var confirmationReason = "fixed reads"
    private var unchangedSkipped = 0, cadenceSkipped = 0, pausedSkipped = 0, retryCount = 0
    private var visualChanges = 0, totalEmptyOCRPasses = 0
    private var lastVisualChangeAt = Date.distantPast
    private var effectiveOCRIntervalMs = 0.0
    private var feedback = RecognitionFeedback()
    private var lastChanged = Date()
    private var lastRecognizedKey = ""
    private var info = (bw: 0, bh: 0, orient: 1, cw: 0, ch: 0)

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
        c.start(queue: .global(qos: .userInitiated))
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
        guard type == .video, recognitionLock.try() else { return }
        defer { recognitionLock.unlock() }
        frames += 1
        let now = Date()
        if now.timeIntervalSince(lastPing) > 2 { lastPing = now; send(kind: "ping", lines: []) }

        let cfg = config
        if cfg.resetsRecognition(comparedTo: lastOCRConfig) {
            candidateKey = ""; sentKey = ""; specKey = ""; candidateCount = 0
            ocrSig = []; emptyReads.reset()
            tracker.reset(); candidateID = nil
        }
        lastOCRConfig = cfg
        feedback.unchangedSeconds = now.timeIntervalSince(lastChanged)
        let plan = AdaptiveRecognition.plan(baseEdge: cfg.maxEdge, interval: cfg.interval,
            enabled: cfg.adaptiveOCR ?? false, cool: cfg.smartCool ?? false,
            pressure: cfg.pressure ?? false, feedback: feedback, ceiling: cfg.detailCeiling ?? 2400)
        recognitionReason = plan.reason
        let idleFactor = SubtitleAcquisitionPolicy.idleMultiplier(movie: cfg.movieMode ?? false,
            enabled: cfg.idleBackoff ?? true, secondsSinceText: now.timeIntervalSince(lastUsefulText))
        let interval = SubtitlePerformancePolicy.confirmationInterval(
            planned: plan.interval * idleFactor, pending: candidateCount > 0,
            movie: cfg.movieMode ?? false,
            pressure: cfg.confirmationBurst == false || (cfg.pressure ?? false) || (cfg.smartCool ?? false) ||
                ProcessInfo.processInfo.isLowPowerModeEnabled ||
                ProcessInfo.processInfo.thermalState != .nominal,
            processingMs: lastOcrMs)
        effectiveOCRIntervalMs = interval * 1000
        guard !cfg.paused else { pausedSkipped += 1; return }
        guard CaptureCadence.remaining(startedAt: lastRun.timeIntervalSince1970, now: now.timeIntervalSince1970,
                                       interval: interval) <= 0 else { cadenceSkipped += 1; return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var orientation = CGImagePropertyOrientation.up
        if let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                   attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: n.uint32Value) {
            orientation = o
        }
        // When diagnostics are enabled, sample lightweight *numeric* visual change
        // even if frame skipping is off; only the counters/timestamp leave the extension.
        // This is NOT a subtitle-presence oracle: moving scenes also trigger it.
        if (cfg.skipUnchanged ?? true) || (cfg.captureDiagnostics ?? false) {
            let sig = signature(pb, config: cfg, oriented: orientation)
            let comparable = !sig.isEmpty && sig.count == ocrSig.count
            let changed = comparable && SubtitleAcquisitionPolicy.changed(previous: ocrSig, current: sig)
            if comparable { feedback.motion = meanDiff(sig, ocrSig) }
            if changed { visualChanges += 1; lastVisualChangeAt = now }
            if (cfg.skipUnchanged ?? true), candidateCount == 0,
               comparable, now.timeIntervalSince(lastRun) <
                    SubtitleAcquisitionPolicy.maximumUnchangedDelay(movie: cfg.movieMode ?? false),
               !changed {
                skipped += 1; unchangedSkipped += 1
                return
            }
            if !sig.isEmpty { ocrSig = sig }
        }

        info.bw = CVPixelBufferGetWidth(pb)
        info.bh = CVPixelBufferGetHeight(pb)
        info.orient = Int(orientation.rawValue)
        // Count the interval from the start of OCR, not after OCR has already finished.
        // The lock also prevents overlapping callbacks from mutating confirmation state.
        lastRun = now
        readStartedAt = now.timeIntervalSince1970
        autoreleasepool { recognize(pb, orientation, cfg, edge: plan.edge) }
    }

    // MARK: Cheap change detection
    private func signature(_ pb: CVPixelBuffer, config cfg: Config, oriented: CGImagePropertyOrientation) -> [UInt8] {
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

    private func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
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
        let key = "\(cfg.lang)|\(cfg.correction ?? true)|\(span)"
        if key == cachedRequestKey, let request = cachedRequest { return request }
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .accurate
        r.usesLanguageCorrection = cfg.correction ?? true
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
    private func ocr(_ img: CIImage, _ cfg: Config, _ y0: Double, _ y1: Double) -> [OCRLine] {
        let span = y1 - y0
        let req = makeRequest(cfg, span: span)
        let handler = VNImageRequestHandler(ciImage: img, options: [:])
        guard (try? handler.perform([req])) != nil, let results = req.results else { return [] }

        var lines = results.compactMap { obs -> OCRLine? in
            guard let c = obs.topCandidates(1).first, c.confidence >= Float(min(0.95, max(0.1, cfg.confidence ?? 0.3))), c.string.count >= 2,
                  c.string.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            let b = obs.boundingBox
            let y = y0 + Double(b.midY) * span
            guard y < 0.96 else { return nil }
            return OCRLine(t: c.string, x: Double(b.midX), y: y, h: Double(b.height) * span, w: Double(b.width), confidence: Double(c.confidence))
        }
        lines.sort { $0.y != $1.y ? $0.y > $1.y : $0.x < $1.x }
        return lines
    }

    private func freeMB() -> Double { Double(os_proc_available_memory()) / 1_048_576 }

    private func enhanced(_ i: CIImage) -> CIImage {
        i.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.8])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.8])
    }

    private func recognize(_ pb: CVPixelBuffer, _ orientation: CGImagePropertyOrientation, _ cfg: Config, edge plannedEdge: Double) {
        let state = perf.beginInterval("OCRFrame")
        defer { perf.endInterval("OCRFrame", state) }
        let t0 = CFAbsoluteTimeGetCurrent()
        passes += 1

        // Only read the chosen area, at reduced size: this is the big speed-up.
        let margin = 0.03
        let y0 = max(0, cfg.y0 - margin), y1 = min(1, cfg.y1 + margin)
        var edge = plannedEdge
        if freeMB() < 15 { edge = min(edge, 800) }          // memory getting tight

        // iOS's orientation hint first, then the app's extra quarter-turns (fixes upside-down frames)
        let extra = [CGImagePropertyOrientation.up, .right, .down, .left][(cfg.rot ?? 0) & 3]
        let base = CIImage(cvPixelBuffer: pb).oriented(orientation).oriented(extra)
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
        info.cw = Int(img.extent.width)
        info.ch = Int(img.extent.height)

        let boost = cfg.boost ?? 1
        var lines = ocr(boost == 2 ? enhanced(img) : img, cfg, y0, y1)
        if lines.isEmpty {
            emptyReads.primaryEmpty()
            totalEmptyOCRPasses += 1
            // Fallback for hard text (thin, outlined, low contrast): boost contrast and retry
            if boost == 1 && emptyReads.needsContrastRetry && freeMB() > 20 {
                retryCount += 1
                lines = ocr(enhanced(img), cfg, y0, y1)
            }
        }
        // A successful contrast retry is a successful read too. Otherwise the
        // old empty streak could clear the caption after just one later miss.
        emptyReads.finish(foundText: !lines.isEmpty)
        if !lines.isEmpty {
            lastUsefulText = Date()
        }
        lastOcrMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        feedback.processingMs = lastOcrMs
        feedback.failures = lines.isEmpty ? feedback.failures + 1 : 0
        feedback.confidence = lines.map { $0.confidence ?? 0 }.min() ?? 0
        let heights = lines.map(\.h).sorted()
        feedback.textHeight = heights.isEmpty ? 0 : heights[min(heights.count-1, Int(Double(heights.count-1)*0.8))]
        let recognizedKey = lines.map(\.t).joined(separator: "\n")
        if recognizedKey != lastRecognizedKey { lastChanged = Date(); lastRecognizedKey = recognizedKey }

        if lines.isEmpty {
            if emptyReads.mayClear {
                if !sentKey.isEmpty { send(kind: "clear", lines: [], revision: cfg.rev) }
                sentKey = ""; candidateKey = ""; candidateCount = 0; tracker.reset(); candidateID = nil
            }
            return
        }

        // Stability: send once the same text was read N times in a row (skips half-faded text).
        let need = max(1, cfg.stability ?? 2)
        let key = lines.map(\.t).joined(separator: "\n")
        if cfg.subtitleTracking == true || cfg.adaptiveConfirmation == true {
            let decision = tracker.observe(lines, at: readStartedAt, required: need,
                adaptive: cfg.adaptiveConfirmation ?? false, spatial: cfg.subtitleTracking ?? false,
                deadline: cfg.confirmationDeadline ?? 0.6, minimumConfidence: cfg.confidence ?? 0.3)
            candidateID = "\(captureID):\(cfg.rev ?? 0):\(decision.id)"
            confirmationReason = decision.reason
            candidateStartedAt = decision.firstSeen
            candidateCount = decision.ready || decision.duplicate ? 0 : 1
            guard !decision.duplicate else { return }
            if decision.ready {
                sentKey = key
                send(kind: "ocr", lines: Array(lines.prefix(60)), stable: true, revision: cfg.rev)
            } else if key != specKey {
                specKey = key
                // Candidate notice is always sent, even when selective speculation later declines it.
                send(kind: "ocr", lines: Array(lines.prefix(60)), stable: false, revision: cfg.rev)
            }
            return
        }
        candidateID = nil
        confirmationReason = "fixed reads"
        if PipelineSafety.isDuplicate(key.components(separatedBy: "\n"), previous: sentKey.components(separatedBy: "\n")) { candidateKey = key; candidateCount = 0; return }
        // A new confirmation run can resemble the previous subtitle. Reset timing
        // when the count restarts, even if the fuzzy comparison still matches.
        if candidateCount == 0 { candidateStartedAt = readStartedAt }
        if TextSim.similar(key, candidateKey) { candidateCount += 1 }
        else { candidateKey = key; candidateCount = 1; candidateStartedAt = readStartedAt }
        if candidateCount >= need {
            sentKey = key
            candidateCount = 0
            send(kind: "ocr", lines: Array(lines.prefix(60)), stable: true, revision: cfg.rev)
        } else if candidateCount == 1, need > 1, cfg.speculate ?? true, !TextSim.similar(key, specKey) {
            // First sighting: the app starts translating right away but only shows it once the text is confirmed.
            specKey = key
            send(kind: "ocr", lines: Array(lines.prefix(60)), stable: false, revision: cfg.rev)
        }
    }

    // MARK: Send
    private func send(kind: String, lines: [OCRLine], stable: Bool? = nil, revision: Int? = nil) {
        func encode(_ l: [OCRLine]) -> Data? {
            try? JSONEncoder().encode(Packet(kind: kind, version: AppVersion.version, frames: frames, lines: l,
                                             ocrMs: lastOcrMs, memFreeMB: freeMB(),
                                             ts: Date().timeIntervalSince1970, rev: revision ?? config.rev,
                                             bufW: info.bw, bufH: info.bh, orient: info.orient,
                                             cropW: info.cw, cropH: info.ch, passes: passes, skipped: skipped,
                                             stable: stable, firstSeenAt: kind == "ocr" ? candidateStartedAt : nil,
                                             readStartedAt: kind == "ocr" ? readStartedAt : nil,
                                             candidateID: kind == "ocr" ? candidateID : nil,
                                             recognitionReason: recognitionReason, confirmationReason: confirmationReason,
                                             unchangedSkipped: unchangedSkipped, cadenceSkipped: cadenceSkipped, pausedSkipped: pausedSkipped,
                                             emptyReads: feedback.failures, retryCount: retryCount,
                                             visualChanges: visualChanges,
                                             totalEmptyOCRPasses: totalEmptyOCRPasses,
                                             lastVisualChangeAt: lastVisualChangeAt == .distantPast ?
                                                nil : lastVisualChangeAt.timeIntervalSince1970,
                                             effectiveOCRIntervalMs: effectiveOCRIntervalMs))
        }
        var data = encode(lines)
        if let d = data, d.count > 60000 { data = encode(Array(lines.prefix(30))) }
        guard let d = data else { return }
        conn?.send(content: d, completion: .contentProcessed { _ in })
    }
}

