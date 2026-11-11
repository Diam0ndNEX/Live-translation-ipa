// Screen Translator – Broadcast extension – v0.11.0
import ReplayKit
import Vision
import ImageIO
import CoreImage
import Network
import os
import os.signpost

class SampleHandler: RPBroadcastSampleHandler {
    var conn: NWConnection?
    private let recognitionLock = NSLock()
    // Send completions run on the connection queue; guard the counters.
    private let sendStatsLock = NSLock()
    private var largePacketCount = 0
    private var sendErrorCount = 0
    private var frames = 0
    private var passes = 0
    private var skipped = 0
    private var lastRun = Date.distantPast
    var readStartedAt = 0.0
    var readStartedMonotonic = 0.0
    private var candidateStartedMonotonic: Double?
    private var candidateStartedAt = 0.0
    private var lastPing = Date.distantPast
    // 2.3.2: optional timer heartbeat (Config.independentHeartbeat). Everything it reads is behind `heartbeatLock`.
    // It never takes `recognitionLock`, and sends only when nothing else was sent for a while.
    let heartbeatLock = NSLock()
    var heartbeatTimer: DispatchSourceTimer?
    var heartbeatConn: NWConnection?
    private var heartbeatFrames = 0
    private var lastSendUptime = ProcessInfo.processInfo.systemUptime
    private var candidateKey = ""
    private var sentKey = ""
    private var candidateCount = 0
    private var specKey = ""
    private var lastOCRConfig: Config?
    private var emptyReads = OCREmptyReadStreak()
    private var lastOcrMs: Double = 0
    // Recognition callbacks are serialized by recognitionLock. Reuse only the
    // request configuration; Vision replaces results on every perform call.
    var cachedRequest: VNRecognizeTextRequest?
    var cachedRequestKey = ""
    private var lastUsefulText = Date()
    private var ocrSig: [UInt8] = []
    private let perf = OSSignposter(subsystem: "com.diam0ndnex.screenlingo", category: "capture")
    private var captionFocus = CaptionFocus()
    private var tracker = SubtitleTracker()
    private let captureID = UUID().uuidString
    private var candidateID: String?
    private var recognitionReason = "fixed preset"
    var confirmationReason = "fixed reads"
    private var unchangedSkipped = 0, cadenceSkipped = 0, pausedSkipped = 0, retryCount = 0
    private var visualChanges = 0, totalEmptyOCRPasses = 0
    private var lastVisualChangeAt = Date.distantPast
    private var effectiveOCRIntervalMs = 0.0
    private var visualWakeCount = 0
    private var visualWakeSuppressedCount = 0 // 2.2.1 (D11): early wakes the per-second cap refused
    private var lastVisualWakeProbe = Date.distantPast
    private var visualWakeWindowStart = Date.distantPast
    private var visualWakeWindowCount = 0
    private var feedback = RecognitionFeedback()
    private var lastChanged = Date()
    private var lastRecognizedKey = ""
    /// v2.0.0 G1: a first read waiting for pixel-verified confirmation.
    struct PendingPixelRead {
        let lines: [OCRLine]
        let points: [(x: Double, y: Double)]
        let fingerprint: PixelConfirmation.Fingerprint
        var readStart: Double
        let context: String
    }
    var pendingPixelRead: PendingPixelRead?
    var lastPixelCheck = 0.0
    var pixelConfirmations = 0
    var pixelRejections = 0
    /// v2.0.0 G2: the confirmed caption's text pixels, watched between reads.
    struct CaptionWatch {
        let points: [(x: Double, y: Double)]
        let fingerprint: PixelConfirmation.Fingerprint
        let context: String
    }
    var captionWatch: CaptionWatch?
    var lastWatchCheck = 0.0
    private var watchSkippedOCR = 0
    private var watchTriggeredOCR = 0
    private var info = (bw: 0, bh: 0, orient: 1, cw: 0, ch: 0)
    // 2.4.0. All of this is read and written only while `recognitionLock` is held.
    /// A focused read was thrown away because its text changed: read the whole area on the next frame instead of
    /// waiting for the ordinary cadence. No read is skipped and no text is accepted sooner.
    private var forceBroadRead = false
    private var focusRediscoveries = 0
    private var discardedFocusedReadAt: Double?
    private var rediscoveryLeadMs: Double?
    /// Measurement only: what the current caption needed until it was confirmed.
    private var lastOCREndUptime: Double?
    private var confirmReads = 0
    var confirmPixelRejections = 0
    private var confirmFrameWaitMs = 0.0
    /// Set only around `admit` in `recognize`: whether the read being admitted has its pixel check armed.
    private var sendPixelArmed: Bool?
    /// The scheduling inputs of the current frame, kept so `recognize` can tell whether the pixel check of a first
    /// read can pass on the next frame (short confirmation interval) or only later.
    private var framePlannedInterval = 0.0
    private var frameRapidText = false
    private var framePressure = true

    // 2.5.0. All of this is read and written only while `recognitionLock` is held.
    /// Item E: changed focused reads that were used without reading the whole area again.
    private var trustedBandReads = 0
    /// Item F: the fast first pass of a Legacy read, its score, and the text of the last pass not judged yet.
    private var headStart = HeadStartGovernor()
    private var headStartKey: String?
    private var headStartPrePasses = 0, headStartSent = 0, headStartConfirmed = 0, headStartMissed = 0
    private var headStartPrePassMs: Double?
    private var sendingHeadStart = false
    /// True when this read was started because the screen changed or no caption is being watched.
    private var frameLikelyNewText = false
    var cachedFastRequest: VNRecognizeTextRequest?
    var cachedFastRequestKey = ""
    lazy var fastRecognitionLanguages: [String] = {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .fast
        return (try? r.supportedRecognitionLanguages()) ?? []
    }()
    /// Item C: extra OCR reads of an unconfirmed caption by cause (order of `V250Names.extraReadCounters`), and the
    /// cause the next such read will be booked under. Written by the confirmation part as well.
    var extraReads = [Int](repeating: 0, count: V250Names.extraReadCounters.count)
    var nextReadCause = ExtraReadCause.other

    private let cfgLock = NSLock()
    private var _config = Config(lang: "auto", y0: 0, y1: 1, maxEdge: 1400, interval: 0.25, paused: false)
    var config: Config {
        get { cfgLock.lock(); defer { cfgLock.unlock() }; return _config }
        set { cfgLock.lock(); _config = newValue; cfgLock.unlock() }
    }

    lazy var recognitionLanguages: [String] = {
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
        heartbeatLock.lock(); heartbeatConn = c; heartbeatLock.unlock()
        listen()
        send(kind: "ping", lines: [])
    }

    override func broadcastFinished() {
        stopHeartbeat()
        recognitionLock.lock()
        defer { recognitionLock.unlock() }
        send(kind: "stopped", lines: [], closeConnection: true)
        conn = nil
    }

    // MARK: Heartbeat (2.3.2, off unless the app asks for it)
    func updateHeartbeat(enabled: Bool) {
        heartbeatLock.lock(); defer { heartbeatLock.unlock() }
        if enabled, heartbeatTimer == nil, heartbeatConn != nil {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.sendHeartbeatIfQuiet() }
            heartbeatTimer = timer
            timer.resume()
        } else if !enabled, let timer = heartbeatTimer {
            timer.cancel(); heartbeatTimer = nil
        }
    }

    /// A small ping that reads only values kept behind `heartbeatLock`. If a ping or OCR packet went out in the last
    /// 1.5 s (the normal case) nothing is sent, so with working frames this adds no traffic.
    private func sendHeartbeatIfQuiet() {
        heartbeatLock.lock()
        let connection = heartbeatConn, framesSeen = heartbeatFrames, last = lastSendUptime
        heartbeatLock.unlock()
        let now = ProcessInfo.processInfo.systemUptime
        guard let connection, now - last >= 1.5 else { return }
        let packet = Packet(kind: "ping", version: AppVersion.version, frames: framesSeen, lines: [],
                            memFreeMB: freeMB(), ts: Date().timeIntervalSince1970,
                            captureSessionID: captureID, sentMonotonic: now)
        guard let data = try? JSONEncoder().encode(packet) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: Frames
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, recognitionLock.try() else { return }
        defer { recognitionLock.unlock() }
        frames += 1
        if let ended = lastOCREndUptime {
            lastOCREndUptime = nil
            confirmFrameWaitMs = max(confirmFrameWaitMs, (ProcessInfo.processInfo.systemUptime - ended) * 1000)
        }
        let forcedRead = forceBroadRead
        let now = Date()
        if now.timeIntervalSince(lastPing) > 2 { lastPing = now; send(kind: "ping", lines: []) }

        let cfg = config
        if cfg.resetsRecognition(comparedTo: lastOCRConfig) {
            candidateKey = ""; sentKey = ""; specKey = ""; candidateCount = 0
            ocrSig = []; emptyReads.reset()
            lastVisualWakeProbe = .distantPast
            visualWakeWindowStart = .distantPast
            visualWakeWindowCount = 0
            tracker.reset(); candidateID = nil
            pendingPixelRead = nil
            captionWatch = nil
            forceBroadRead = false; discardedFocusedReadAt = nil
            headStartKey = nil; nextReadCause = .other
        }
        lastOCRConfig = cfg
        feedback.unchangedSeconds = now.timeIntervalSince(lastChanged)
        let plan = AdaptiveRecognition.plan(baseEdge: cfg.maxEdge, interval: cfg.interval,
            enabled: cfg.adaptiveOCR ?? false, cool: cfg.smartCool ?? false,
            pressure: cfg.pressure ?? false, feedback: feedback, ceiling: cfg.detailCeiling ?? 2400)
        recognitionReason = plan.reason
        // Preference comes from the selected preset or the user's overrides,
        // never from the built-in Movie/Game/Comic category.
        let rapidText = cfg.rapidTextTracking ?? cfg.movieMode ?? false
        let idleFactor = SubtitleAcquisitionPolicy.idleMultiplier(rapidTextTracking: rapidText,
            enabled: cfg.idleBackoff ?? true, secondsSinceText: now.timeIntervalSince(lastUsefulText))
        // Evaluated once per frame; used for both the interval and early wake.
        let pressure = cfg.confirmationBurst == false || (cfg.pressure ?? false) ||
            (cfg.smartCool ?? false) || ProcessInfo.processInfo.isLowPowerModeEnabled ||
            ThermalPerformancePolicy.automaticPressure(for: ProcessInfo.processInfo.thermalState)
        let interval = SubtitlePerformancePolicy.confirmationInterval(
            planned: plan.interval * idleFactor, pending: candidateCount > 0,
            rapidTextTracking: rapidText,
            pressure: pressure,
            processingMs: lastOcrMs)
        effectiveOCRIntervalMs = interval * 1000
        framePlannedInterval = plan.interval * idleFactor
        frameRapidText = rapidText
        framePressure = pressure
        guard !cfg.paused && cfg.appInterfaceVisible != true else { pausedSkipped += 1; return }
        // v2.0.0 G1: a pixel-identical frame after the confirmation dwell is
        // the second identical read; it replaces a second OCR pass.
        if cfg.pixelConfirmation == true, pendingPixelRead != nil,
           pixelConfirm(sampleBuffer, cfg, interval: interval) {
            lastRun = now
            return
        }
        // v2.0.0 G2: while the confirmed caption's text pixels are unchanged,
        // OCR is not needed except for a bounded heartbeat; when they change,
        // read now instead of waiting for the next cadence slot.
        var watchTriggered = false
        if cfg.eventDrivenOCR == true, pendingPixelRead == nil, captionWatch != nil, !forcedRead {
            switch watchCaption(sampleBuffer, cfg) {
            case .unchanged:
                if now.timeIntervalSince(lastRun) <
                    SubtitleAcquisitionPolicy.maximumUnchangedDelay(rapidTextTracking: rapidText) {
                    watchSkippedOCR += 1
                    return
                }
            case .changed:
                watchTriggered = true
                watchTriggeredOCR += 1
            case .notChecked:
                break
            }
        }
        let elapsed = now.timeIntervalSince(lastRun)
        let ordinaryDue = CaptureCadence.remaining(startedAt: lastRun.timeIntervalSince1970,
                                                    now: now.timeIntervalSince1970, interval: interval) <= 0
        #if SCREENLINGO_REFERENCE_CAPTURE_CADENCE
        let mayProbeEarly = false
        #else
        let mayProbeEarly = !ordinaryDue && !forcedRead && candidateCount == 0 &&
            SubtitleAcquisitionPolicy.allowsEarlyVisualWake(
                elapsed: elapsed, planned: interval, lastOCRMilliseconds: lastOcrMs,
                rapidTextTracking: rapidText, pressure: pressure) &&
            SubtitleAcquisitionPolicy.mayProbeEarlyInWindow(
                count: visualWakeWindowCount,
                elapsedSeconds: now.timeIntervalSince(visualWakeWindowStart)) &&
            now.timeIntervalSince(lastVisualWakeProbe) >= 0.065
        #endif
        #if !SCREENLINGO_REFERENCE_CAPTURE_CADENCE
        // 2.2.1 (D11): count the wakes the cap suppressed. Measurement only; it changes no decision.
        if !ordinaryDue && !mayProbeEarly && !forcedRead && candidateCount == 0 &&
            now.timeIntervalSince(lastVisualWakeProbe) >= 0.065 &&
            SubtitleAcquisitionPolicy.allowsEarlyVisualWake(
                elapsed: elapsed, planned: interval, lastOCRMilliseconds: lastOcrMs,
                rapidTextTracking: rapidText, pressure: pressure) {
            visualWakeSuppressedCount += 1
        }
        #endif
        guard ordinaryDue || mayProbeEarly || watchTriggered || forcedRead else { cadenceSkipped += 1; return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var orientation = CGImagePropertyOrientation.up
        if let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                   attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: n.uint32Value) {
            orientation = o
        }
        // A pre-cadence probe may ONLY advance a normal OCR pass after a
        // changed signature. A false positive costs bounded extra OCR, never
        // an earlier confirmation or changed confidence/quality threshold.
        // A false negative leaves the normal cadence untouched.
        if (cfg.skipUnchanged ?? true) || (cfg.captureDiagnostics ?? false) ||
            (rapidText && !pressure) {
            // Retain a signature baseline even with skipUnchanged disabled.
            // Early probing never suppresses an ordinarily due OCR read.
            if mayProbeEarly { lastVisualWakeProbe = now }
            let sig = signature(pb, config: cfg, oriented: orientation)
            let comparable = !sig.isEmpty && sig.count == ocrSig.count
            let changed = comparable && SubtitleAcquisitionPolicy.changed(previous: ocrSig, current: sig)
            if mayProbeEarly && !changed { cadenceSkipped += 1; return }
            if mayProbeEarly && changed {
                if now.timeIntervalSince(visualWakeWindowStart) >= 1 {
                    visualWakeWindowStart = now
                    visualWakeWindowCount = 0
                }
                visualWakeWindowCount += 1
                visualWakeCount += 1
            }
            if comparable { feedback.motion = meanDiff(sig, ocrSig) }
            if changed { visualChanges += 1; lastVisualChangeAt = now }
            if (cfg.skipUnchanged ?? true), candidateCount == 0, !forcedRead,
               comparable, now.timeIntervalSince(lastRun) <
                    SubtitleAcquisitionPolicy.maximumUnchangedDelay(rapidTextTracking: rapidText),
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
        forceBroadRead = false
        frameLikelyNewText = watchTriggered || captionWatch == nil
        readStartedAt = now.timeIntervalSince1970
        readStartedMonotonic = ProcessInfo.processInfo.systemUptime
        autoreleasepool { recognize(pb, orientation, cfg, edge: plan.edge) }
    }

    private func recognize(_ pb: CVPixelBuffer, _ orientation: CGImagePropertyOrientation, _ cfg: Config, edge plannedEdge: Double) {
        let state = perf.beginInterval("OCRFrame")
        defer { perf.endInterval("OCRFrame", state) }
        defer { lastOCREndUptime = ProcessInfo.processInfo.systemUptime }
        let t0 = CFAbsoluteTimeGetCurrent()
        passes += 1

        // Only read the chosen area, at reduced size: this is the big speed-up.
        let margin = 0.03
        let broadY0 = max(0, cfg.y0 - margin), broadY1 = min(1, cfg.y1 + margin)
        let focusEnabled = cfg.focusedCaptionOCR == true
        let focus = focusEnabled ? captionFocus.scan(at: readStartedMonotonic, y0: broadY0, y1: broadY1,
            context: "\(orientation.rawValue)|\(cfg.rot ?? 0)|\(cfg.rev ?? 0)|\(cfg.lang)|\(cfg.y0)|\(cfg.y1)",
            useBand: cfg.trustedCaptionBand == true) :
            CaptionFocus.Scan(y0: broadY0, y1: broadY1, broad: true)
        let y0 = focus.y0, y1 = focus.y1
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
        // 2.5.0 (item F): Legacy only. A fast read of the same image may start the translation while the normal
        // read below is still running. It never confirms or shows anything; the normal read and the pixel check
        // decide that exactly as before. See `HeadStartGovernor` for when it is used.
        if cfg.legacyHeadStart == true, !focusEnabled, cfg.fastOCR != true, boost != 2, candidateCount == 0,
           frameLikelyNewText, !framePressure, freeMB() > 20, headStart.shouldRunPrePass() {
            let began = CFAbsoluteTimeGetCurrent()
            if let fast = fastPass(img, cfg, y0, y1) {
                headStartPrePassMs = (CFAbsoluteTimeGetCurrent() - began) * 1000
                headStartPrePasses += 1
                let key = fast.map(\.t).joined(separator: "\n")
                if let waiting = headStartKey, waiting != key {
                    // The text of the last fast pass was replaced before it was confirmed.
                    headStart.record(right: false); headStartMissed += 1
                    headStartKey = nil
                }
                if !key.isEmpty, key != sentKey, headStartKey == nil {
                    headStartKey = key
                    if headStart.maySend {
                        headStartSent += 1
                        sendingHeadStart = true
                        send(kind: "ocr", lines: Array(fast.prefix(60)), stable: false, revision: cfg.rev)
                        sendingHeadStart = false
                    }
                }
            }
        }
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
        let lineBounds = lines.map { (center: $0.y, height: $0.h, confidence: $0.confidence ?? 0) }
        if focusEnabled {
            if cfg.trustedCaptionBand == true, !lines.isEmpty { captionFocus.learnBand(bounds: lineBounds, broad: focus.broad) }
            captionFocus.observe(bounds: lineBounds)
        }
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
        // A new caption may extend beyond the old crop. Rediscover the whole
        // configured area before admitting changed text to source confirmation.
        // 2.5.0 (item E): changed text read inside the trusted caption band is used as it is. Text outside the band is
        // found by the next whole-area read (at most 0.75 s later).
        let trustedChange = focusEnabled && cfg.trustedCaptionBand == true && recognizedKey != lastRecognizedKey &&
            captionFocus.trusts(bounds: lineBounds, scan: focus)
        if trustedChange { trustedBandReads += 1 }
        if focusEnabled, !trustedChange,
           captionFocus.requiresRediscovery(scan: focus, recognized: recognizedKey, previous: lastRecognizedKey) {
            // 2.4.0: read the whole area on the next frame. Before, with no caption pending, that read waited for the
            // ordinary cadence although new text was already known to be on screen.
            focusRediscoveries += 1
            forceBroadRead = true
            discardedFocusedReadAt = readStartedMonotonic
            return
        }
        if recognizedKey != lastRecognizedKey {
            lastChanged = Date(); lastRecognizedKey = recognizedKey
            confirmReads = 1; confirmPixelRejections = 0; confirmFrameWaitMs = 0
            let lead = discardedFocusedReadAt.map { max(0, readStartedMonotonic - $0) * 1000 }
            rediscoveryLeadMs = lead.flatMap { $0 < 1000 ? $0 : nil }
            nextReadCause = .other
        } else {
            confirmReads += 1
            // 2.5.0 (item C): the same text had to be read again before it was confirmed. Book the cause.
            if cfg.extraReadReasons == true, candidateCount > 0 { extraReads[nextReadCause.rawValue] += 1 }
            nextReadCause = .other
        }
        discardedFocusedReadAt = nil

        if lines.isEmpty {
            if emptyReads.mayClear {
                if !sentKey.isEmpty { send(kind: "clear", lines: [], revision: cfg.rev) }
                sentKey = ""; candidateKey = ""; candidateCount = 0; tracker.reset(); candidateID = nil
            }
            pendingPixelRead = nil
            captionWatch = nil
            return
        }

        // v2.0.0 G1: remember the text boxes of an unconfirmed first read so
        // a later pixel-identical frame can confirm it without another OCR pass.
        // 2.4.0: the fingerprint is taken before the packet is sent, so a first-sighting packet can say whether its
        // pixel check is armed (then its confirmation follows on the next frame). The check itself is unchanged.
        if cfg.pixelConfirmation == true {
            preparePixelConfirmation(pb, orientation, cfg, lines: lines)
        } else {
            pendingPixelRead = nil
            nextReadCause = .pixelOff
        }
        // Armed means: one more read is needed, the pixel check is ready, and the wait it needs (the same wait as in
        // `pixelConfirm`) is over about when this OCR pass ends. With a longer wait the app keeps its early start.
        let confirmationWait = max(0.1, SubtitlePerformancePolicy.confirmationInterval(
            planned: framePlannedInterval, pending: true, rapidTextTracking: frameRapidText,
            pressure: framePressure, processingMs: lastOcrMs))
        sendPixelArmed = pendingPixelRead != nil && max(1, cfg.stability ?? 2) == 2 &&
            cfg.adaptiveConfirmation != true && confirmationWait <= lastOcrMs / 1000 + 0.05
        let outcome = admit(lines, cfg)
        sendPixelArmed = nil
        if outcome != .pending { pendingPixelRead = nil }
        if outcome == .pending, pendingPixelRead != nil, max(1, cfg.stability ?? 2) > 2 { nextReadCause = .moreReads }
        switch outcome {
        case .ready, .duplicate:
            if cfg.eventDrivenOCR == true { startCaptionWatch(pb, orientation, cfg, lines: lines) }
        case .pending:
            captionWatch = nil
        }
    }

    enum Admission { case ready, pending, duplicate }

    /// Confirmation decision for one read (OCR or pixel-verified).
    @discardableResult
    func admit(_ lines: [OCRLine], _ cfg: Config) -> Admission {
        // Stability: send once the same text was read N times in a row (skips half-faded text).
        let need = max(1, cfg.stability ?? 2)
        let key = lines.map(\.t).joined(separator: "\n")
        if cfg.subtitleTracking == true || cfg.adaptiveConfirmation == true || cfg.strictCaptionIdentity == true {
            let strict = cfg.strictCaptionIdentity == true
            let decision = tracker.observe(lines, at: strict ? readStartedMonotonic : readStartedAt, required: need,
                adaptive: cfg.adaptiveConfirmation ?? false, spatial: cfg.strictCaptionIdentity == true || (cfg.subtitleTracking ?? false),
                deadline: cfg.confirmationDeadline ?? 0.6, minimumConfidence: cfg.confidence ?? 0.3,
                strictSource: cfg.strictCaptionIdentity ?? false)
            candidateID = "\(captureID):\(cfg.rev ?? 0):\(decision.id)"
            confirmationReason = decision.reason
            candidateStartedAt = strict ? readStartedAt - max(0, readStartedMonotonic - decision.firstSeen) : decision.firstSeen
            candidateStartedMonotonic = strict ? decision.firstSeen : nil
            candidateCount = decision.ready || decision.duplicate ? 0 : 1
            guard !decision.duplicate else { return .duplicate }
            if decision.ready {
                sentKey = key
                judgeHeadStart(confirmed: key)
                send(kind: "ocr", lines: Array(lines.prefix(60)), stable: true, revision: cfg.rev)
            } else if key != specKey {
                specKey = key
                // Candidate notice is always sent, even when selective speculation later declines it.
                send(kind: "ocr", lines: Array(lines.prefix(60)), stable: false, revision: cfg.rev)
            }
            return decision.ready ? .ready : .pending
        }
        candidateID = nil
        confirmationReason = "fixed reads"
        if PipelineSafety.isDuplicate(key.components(separatedBy: "\n"), previous: sentKey.components(separatedBy: "\n")) { candidateKey = key; candidateCount = 0; return .duplicate }
        // A new confirmation run can resemble the previous subtitle. Reset timing
        // when the count restarts, even if the fuzzy comparison still matches.
        if candidateCount == 0 { candidateStartedAt = readStartedAt }
        if TextSim.similar(key, candidateKey) { candidateCount += 1 }
        else { candidateKey = key; candidateCount = 1; candidateStartedAt = readStartedAt }
        if candidateCount >= need {
            sentKey = key
            candidateCount = 0
            judgeHeadStart(confirmed: key)
            send(kind: "ocr", lines: Array(lines.prefix(60)), stable: true, revision: cfg.rev)
            return .ready
        } else if candidateCount == 1, need > 1, cfg.speculate ?? true, !TextSim.similar(key, specKey) {
            // First sighting: the app starts translating right away but only shows it once the text is confirmed.
            specKey = key
            send(kind: "ocr", lines: Array(lines.prefix(60)), stable: false, revision: cfg.rev)
        }
        return .pending
    }

    /// 2.5.0 (item F): a caption was confirmed (by a read or by the pixel check). Was the fast pass right about it?
    private func judgeHeadStart(confirmed key: String) {
        guard let waiting = headStartKey else { return }
        let right = waiting == key
        headStart.record(right: right)
        if right { headStartConfirmed += 1 } else { headStartMissed += 1 }
        headStartKey = nil
    }

    enum WatchResult { case unchanged, changed, notChecked }

    // MARK: Send
    private func send(kind: String, lines: [OCRLine], stable: Bool? = nil, revision: Int? = nil, closeConnection: Bool = false) {
        sendStatsLock.lock()
        let largeSoFar = largePacketCount, errorsSoFar = sendErrorCount
        sendStatsLock.unlock()
        heartbeatLock.lock(); heartbeatFrames = frames; lastSendUptime = ProcessInfo.processInfo.systemUptime; heartbeatLock.unlock()
        // 2.4.0 fields, worked out here so the long initializer below stays simple for the compiler.
        let confirmedPacket = kind == "ocr" && stable == true
        let armed: Bool? = (kind == "ocr" && stable == false) ? sendPixelArmed : nil
        let reads: Int? = confirmedPacket ? confirmReads : nil
        let rejections: Int? = confirmedPacket ? confirmPixelRejections : nil
        let frameWait: Double? = confirmedPacket ? confirmFrameWaitMs : nil
        let lead: Double? = confirmedPacket ? rediscoveryLeadMs : nil
        let headStartPacket = kind == "ocr" && sendingHeadStart
        let prePassMs = kind == "ocr" ? headStartPrePassMs : nil
        if kind == "ocr" { headStartPrePassMs = nil }
        let reasons: [Int]? = config.extraReadReasons == true ? extraReads : nil
        func encode(_ l: [OCRLine]) -> Data? {
            var packet = Packet(kind: kind, version: AppVersion.version, frames: frames, lines: l,
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
                                             visualChanges: visualChanges, earlyVisualWakes: visualWakeCount, earlyVisualWakesSuppressed: visualWakeSuppressedCount,
                                             totalEmptyOCRPasses: totalEmptyOCRPasses,
                                             lastVisualChangeAt: lastVisualChangeAt == .distantPast ?
                                                nil : lastVisualChangeAt.timeIntervalSince1970,
                                             effectiveOCRIntervalMs: effectiveOCRIntervalMs,
                                             captureSessionID: captureID,
                                             firstSeenMonotonic: kind == "ocr" && config.strictCaptionIdentity == true ? candidateStartedMonotonic : nil,
                                             sentMonotonic: ProcessInfo.processInfo.systemUptime,
                                             largePackets: largeSoFar, sendErrors: errorsSoFar,
                                             pixelConfirmations: pixelConfirmations, pixelRejections: pixelRejections,
                                             watchSkippedOCR: watchSkippedOCR, watchTriggeredOCR: watchTriggeredOCR,
                                             pixelArmed: armed, focusRediscoveries: focusRediscoveries,
                                             confirmReads: reads, confirmPixelRejections: rejections,
                                             confirmFrameWaitMs: frameWait, rediscoveryLeadMs: lead)
            // 2.5.0 fields, set after the long initializer.
            if headStartPacket {
                packet.headStart = true
                packet.candidateID = "\(captureID):hs:\(headStartSent)"
                packet.firstSeenAt = readStartedAt
                packet.firstSeenMonotonic = nil
                packet.pixelArmed = nil
            }
            if kind == "ocr" {
                packet.trustedBandReads = trustedBandReads
                packet.headStartPrePasses = headStartPrePasses
                packet.headStartSent = headStartSent
                packet.headStartConfirmed = headStartConfirmed
                packet.headStartMissed = headStartMissed
                packet.headStartPrePassMs = prePassMs
                packet.extraReadReasons = reasons
            }
            return try? JSONEncoder().encode(packet)
        }
        var data = encode(lines)
        if let d = data, d.count > 60000 { data = encode(Array(lines.prefix(30))) }
        guard let d = data else { return }
        if d.count > 8000 {
            sendStatsLock.lock(); largePacketCount += 1; sendStatsLock.unlock()
        }
        let connection = conn
        connection?.send(content: d, completion: .contentProcessed { [weak self] error in
            if error != nil, let self {
                self.sendStatsLock.lock(); self.sendErrorCount += 1; self.sendStatsLock.unlock()
            }
            if closeConnection { connection?.cancel() }
        })
    }
}

