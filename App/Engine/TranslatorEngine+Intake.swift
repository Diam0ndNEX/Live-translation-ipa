import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    // MARK: Packets from the extension
    func handle(_ incoming: Packet) {
        let p = incoming
        let now = Date()
        if p.kind == "stopped" {
            guard captureIdentity.stop(p.captureSessionID) else { return }
            captureReadiness.receive(frames: p.frames, session: p.captureSessionID, stopped: true, at: ProcessInfo.processInfo.systemUptime)
            publishCaptureStatus()
            captureAlive = false; lastPacketDate = .distantPast
            invalidatePending()
            diag.noteRuntimeState("heartbeat_timeout")
            diag.pauseRun(reason: "captureStopped", frames: frames)
            return
        }
        let captureAdmission = captureIdentity.admit(p.captureSessionID)
        guard captureAdmission != .rejected else { return }
        captureReadiness.receive(frames: p.frames, session: p.captureSessionID, stopped: false, at: ProcessInfo.processInfo.systemUptime)
        publishCaptureStatus()
        if captureAdmission == .newSession, captureAlive { invalidatePending(); captureAlive = false; diag.pauseRun(reason: "newCaptureSession", frames: frames) }
        let wasAlive = captureAlive
        lastPacketDate = now
        if !captureAlive { captureAlive = true }
        if frames != p.frames { frames = p.frames }
        if extensionVersion != p.version { extensionVersion = p.version }
        if let t = p.ocrMs, t != ocrMs { ocrMs = t }
        if let m = p.memFreeMB, m != extFreeMB { extFreeMB = m }
        if p.kind != "ocr" || p.rev == nil || p.rev == rotRev {
            let transit = p.sentMonotonic.map { max(0, ProcessInfo.processInfo.systemUptime - $0) * 1000 }
                ?? p.ts.map { max(0, now.timeIntervalSince1970 - $0) * 1000 }
            diag.onPacket(p, transport: transit)
        }

        if !wasAlive {
            activateTranslationSystem()
            diag.beginRun(sameBroadcast: captureAdmission == .current, frames: p.frames); refreshModeDiagnosticEpoch() // v2.0.0 build 84: one Test Run per broadcast, after the active mode is known
            interruptWarmupForLiveWork()
            startupWarmupTask?.cancel() // Live capture takes priority over idle prewarming.
            startupWarmupTask = nil
            idleValidationTask?.cancel()
            idleValidationTask = nil
            sessionStarted = now; limitBase = now
            sessionTranslations = 0; sessionCharacters = 0
            diag.log("Capture connected (extension v\(p.version))")
            diag.noteRuntimeState("capture_connected")
            lastTextDate = now
            syncConfig()
            // Do not launch a second synthetic model job as capture starts.
            // Startup preparation runs before capture; live text owns first use.
            // Capture just started: make sure the floating window is up too.
            // 2.2.1 (E17): the window opens only while ScreenLingo is still in front. When the person has already
            // switched to the video app the skip is recorded, and the window opens once when the app is active again.
            if flag("autoOpenPiP", true), !pip.isActive {
                if UIApplication.shared.applicationState == .active { startPiP() }
                else {
                    autoOpenSkipped = true
                    diag.noteRuntimeState("pip_auto_open_skipped_not_active")
                }
            }
        }
        if let orientation = p.orient {
            if let previous = lastCaptureOrientation, previous != orientation, frameRotMode == "auto" {
                rotationSettingChanged()
                diag.log("Capture orientation changed; restarting bounded calibration")
            }
            lastCaptureOrientation = orientation
        }
        if p.kind == "ping" { syncConfig(); return }          // keeps the extension's settings fresh
        handleContent(p, receivedAt: now)
    }

    /// Local handoffs never masquerade as fresh transport packets, extend the
    /// capture heartbeat, or count OCR/confirmation work twice.
    func handleContent(_ incoming: Packet, receivedAt: Date, replayed: Bool = false) {
        var p = incoming
        let now = Date()
        if replayed {
            guard captureAlive, now.timeIntervalSince(receivedAt) >= 0,
                  now.timeIntervalSince(receivedAt) < 1.2 else {
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                    stage: "stability", reason: "handoff_expired")
                return
            }
            diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                stage: "stability", reason: "handoff_replayed")
        }
        if paused || manualMode || (appInterfaceVisible && flag("suppressOwnInterface", true)) { return }
        if let rev = p.rev, rev != rotRev { return }
        if p.kind == "clear" {
            deferredConfirmedPacket = nil
            confirmedHandoffDeadlineTask?.cancel()
            confirmedHandoffDeadlineTask = nil
            invalidatePending(); latestBlocks = []; handleClear(); return
        }
        guard p.kind == "ocr" else { return }
        if diag.detailedCollection && !replayed {
            diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                                      stage: "frame_arrival", reason: "accepted")
        }
        extractingConfirmedPacket = p.stable != false
        let candidateTexts = extractTexts(p.lines, count: p.stable != false && !replayed)
        guard !candidateTexts.isEmpty else {
            if diag.detailedCollection {
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                                          stage: "ocr_filtering", reason: "rejected_empty")
            }
            return
        }
        // Both Legacy and new modes must count accepted confirmed packets.
        // Do this before dispatch, without counting a local replay twice.
        if p.stable != false && !replayed && diag.enabled { diag.s.confirmedCandidatePackets += 1 }
        if activeTranslationSystem != .legacy {
            handleModeCaption(candidateTexts, packet: p)
            return
        }
        let candidateText = candidateTexts.map(TextSim.norm).joined(separator: "\n")
        // Admission must precede generation changes, cancellation and continuity
        // accounting. Rejected fragments never become active confirmed work.
        if SubtitleAcquisitionPolicy.rejectsDisplayedFragment(confirmed: p.stable != false,
            text: candidateTexts.joined(separator: "\n"), displayed: original,
            age: Date().timeIntervalSince(lastShowDate)) {
            if diag.detailedCollection {
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                    stage: "duplicate_detection", reason: "rejected_recent_fragment")
            }
            return
        }
        let equivalentActiveCaption = SubtitleAcquisitionPolicy.isSameUnpresentedCaption(
            activeConfirmed: activeCandidateConfirmed,
            activePresented: activeCandidatePresented,
            previousBlocks: latestBlocks,
            incomingBlocks: candidateTexts)
        let handoffDelay = SubtitlePerformancePolicy.confirmedHandoffDelay(
            age: now.timeIntervalSince(activeCandidateConfirmedAt))
        if !replayed, handoffDelay > 0, flag("protectConfirmedPresentation", true),
           flag("steadyCaptions", true), p.candidateID != nil,
           activeCandidateText != candidateText,
           activeCandidateConfirmed, !activeCandidatePresented,
           p.stable != false, busy || queued != nil || waitingToDisplay,
           !equivalentActiveCaption {
            // One-slot, latest-wins handoff. The existing result gets a bounded
            // completion opportunity; replacement never renews the deadline.
            deferredConfirmedPacket = p
            deferredConfirmedReceivedAt = receivedAt
            // Keep the first deadline when the one-slot replacement changes.
            // Repeated packets cannot renew the grace period indefinitely.
            if confirmedHandoffDeadlineTask == nil {
                confirmedHandoffDeadlineTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(handoffDelay))
                    guard let self, !Task.isCancelled,
                          let pending = self.deferredConfirmedPacket else { return }
                    self.deferredConfirmedPacket = nil
                    self.confirmedHandoffDeadlineTask = nil
                    // Replay once, bypassing handoff protection to prevent a loop.
                    self.handleContent(pending, receivedAt: self.deferredConfirmedReceivedAt, replayed: true)
                }
            }
            if diag.enabled { diag.s.confirmedHandoffDeferred += 1 }
            diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                stage: "stability", reason: "confirmed_handoff_deferred")
            return
        }
        if flag("steadyCaptions", true), let candidate = p.candidateID,
           activeCandidateText != candidateText && !equivalentActiveCaption {
            let confirmed = p.stable != false
            // Tentative OCR jitter must never cancel a previously confirmed subtitle.
            // Its confirmed replacement can still supersede outdated work.
            guard SubtitleAcquisitionPolicy.shouldSupersedeActive(
                activeConfirmed: activeCandidateConfirmed, activePresented: activeCandidatePresented,
                incomingConfirmed: confirmed) else {
                if diag.enabled { diag.s.deferredEarlyCandidates += 1 }
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                    stage: "stability", reason: "deferred_early_candidate")
                return
            }
            if let previous = activeCandidateID {
                diag.trace(previous, stage: "superseded", detail: "Confirmed replacement or early candidate")
                if activeCandidateConfirmed && !activeCandidatePresented && diag.enabled {
                    diag.s.supersededUnpresentedConfirmed += 1
                    // 2.3.0: measurement only. Whether the replaced caption's translation had started, and its age.
                    diag.noteConfirmedSupersession(workStarted: busy && activeQueueOwner == .confirmed,
                        ageMs: max(0, now.timeIntervalSince(activeCandidateConfirmedAt) * 1000))
                }
            }
            activeCandidateID = candidate; activeCandidateText = candidateText
            activeCandidateConfirmed = confirmed; activeCandidatePresented = false
            activeCandidateConfirmedAt = confirmed ? now : .distantPast
            deferredConfirmedPacket = nil
            confirmedHandoffDeadlineTask?.cancel()
            confirmedHandoffDeadlineTask = nil
            clearTask?.cancel(); clearTask = nil
            generation += 1
            cancelPresentation()
            queued = nil; specQueued = nil
            let shared = sharedInFlightUnits(candidateTexts)
            if shared == 0 { cancelDrain(preemptSpeculation: confirmed) }
            else if activeQueueOwner == .confirmed { diag.noteSharedModelUnits(shared, confirmed: true) }
        } else if p.stable != false {
            if !activeCandidateConfirmed { activeCandidateConfirmedAt = now }
            activeCandidateConfirmed = true
            if equivalentActiveCaption && activeCandidateText != candidateText {
                diag.notePipelineDecision(candidate: activeCandidateID,
                    frameIndex: p.frames, stage: "duplicate_detection",
                    reason: "preserved_confirmed_work")
            }
        }
        // Overlay-only OCR changes must not supersede the same filtered subtitle.
        if flag("steadyCaptions", true), p.candidateID != nil { p.candidateID = activeCandidateID }
        if p.stable == false, let firstSeen = p.firstSeenAt {
            diag.trace(p.candidateID, stage: "first OCR", detail: "Capture first sighting",
                       at: Date(timeIntervalSince1970: firstSeen), frameIndex: p.frames)
        }
        diag.trace(p.candidateID, stage: p.stable == false ? "seen" : "confirmed", detail: p.confirmationReason ?? "legacy confirmation")
        if let candidate = p.candidateID {
            let first = p.firstSeenAt ?? p.ts ?? Date().timeIntervalSince1970
            diag.registerLegacyModeCaption(session: modeSessionID, caption: candidate,
                source: sourceCode == "auto" ? (detectedLang == "–" ? "auto" : detectedLang) : sourceCode,
                target: targetCode,
                fingerprint: SHA256.hash(data: Data(ConfirmedSourceIdentity.normalize(candidateTexts.joined(separator: "\n")).utf8)).map { String(format: "%02x", $0) }.joined(),
                firstOCR: ProcessInfo.processInfo.systemUptime - max(0, Date().timeIntervalSince1970 - first),
                confirmed: p.stable != false)
        }
        // First, unconfirmed sighting: translate quietly now so the result is ready the moment the text is confirmed.
        if p.stable == false {
            // 2.4.0: this read's pixel check is armed, so its confirmation follows one frame later. An Apple
            // Default call started now would be at most a few milliseconds ahead, and when the text is not the
            // final one it would still be running when the real caption is confirmed.
            if p.pixelArmed == true, TranslationHotPathAB.deferArmedSpeculation {
                if diag.enabled { diag.s.specSkipped += 1 }
                if let candidate = p.candidateID { diag.legacyModeEvent(candidate, reason: "speculation_deferred_armed") }
                return
            }
            if speculationAllowed && flag("translateAhead", true) {
                let minimumSpecConfidence = flag("coolMode", false) ?
                    max(0.95, num("speculationConfidence", 0.85)) : num("speculationConfidence", 0.85)
                let credible = !flag("selectiveSpeculation", true) ||
                    SpeculationPolicy.credible(lines: p.lines, threshold: minimumSpecConfidence)
                #if SCREENLINGO_REFERENCE_LEGACY_ADMISSION
                let admittedByHistory = ram.speculationWindow.allowsOpportunity(
                    enabled: flag("adaptiveSpeculation", true))
                #else
                // A low-confidence rejected OCR packet is not an opportunity to
                // send model work. Do not consume the bounded governor's probe
                // budget on one. The user-defined threshold is unchanged.
                if !credible {
                    if diag.enabled { diag.s.specSkipped += 1; diag.s.legacyLowConfidenceSkips += 1 }
                    diag.notePipelineDecision(candidate: p.candidateID,
                        frameIndex: p.frames, stage: "stability",
                        reason: "legacy_speculation_low_confidence")
                    return
                }
                let highConfidence = SpeculationPolicy.credible(
                    lines: p.lines, threshold: max(0.95, minimumSpecConfidence))
                let admittedByHistory = ram.speculationWindow.allowsCredibleOpportunity(
                    enabled: flag("adaptiveSpeculation", true), strongCandidate: highConfidence)
                #endif
                guard admittedByHistory else {
                    if diag.enabled {
                        diag.s.adaptiveSpeculationSkipped += 1
                        if ram.speculationWindow.savedMemoryDominant { diag.s.legacyAdaptiveSavedSkips += 1 }
                        else { diag.s.legacyAdaptiveLowYieldSkips += 1 }
                    }
                    if ram.speculationWindow.savedMemoryDominant { diag.noteMemoryAwareSpeculationSkip() }
                    diag.notePipelineDecision(candidate: p.candidateID,
                        frameIndex: p.frames, stage: "stability",
                        reason: ram.speculationWindow.savedMemoryDominant ?
                            "legacy_speculation_saved_memory_backoff" : "legacy_speculation_low_yield_backoff")
                    return
                }
                guard credible else {
                    if diag.enabled {
                        diag.s.specSkipped += 1
                        diag.s.legacyLowConfidenceSkips += 1
                    }
                    if diag.detailedCollection {
                        diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                            stage: "stability", reason: "legacy_speculation_low_confidence")
                    }
                    return
                }
                specPacket = p
                speculate(candidateTexts)
            }
            return
        }
        ocrCount += 1
        lastRaw = String(p.lines.map(\.t).joined(separator: " ").prefix(160))

        // Is text arriving upside down? Votes only count packets made with the current rotation.
        let revision = rotRev
        updateOrderVote(removeOwnOutput(p.lines))
        guard revision == rotRev else {
            if diag.detailedCollection {
                diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                                          stage: "rotation", reason: "rejected_revision")
            }
            return
        }

        let texts = candidateTexts
        latestBlocks = texts
        clearTask?.cancel()
        clearTask = nil
        queuedTs = p.firstSeenAt ?? p.ts ?? now.timeIntervalSince1970
        queuedPacket = p
        enqueue(texts.map { String($0.prefix(400)) })
    }

    private func extractTexts(_ lines: [OCRLine], count: Bool) -> [String] {
        let range = area.range()
        let minH = num("minTextH", 0)
        let ignore = list("ignoreList", lower: true)
        var cand: [OCRLine] = []
        for l in lines {
            if count && diag.enabled { diag.s.linesIn += 1 }
            if !range.contains(l.y) { if count && diag.enabled { diag.s.dropArea += 1 }; continue }
            if l.h < minH { if count && diag.enabled { diag.s.dropSmall += 1 }; continue }
            if ignore.contains(where: { l.t.lowercased().contains($0) }) { if count && diag.enabled { diag.s.dropIgnore += 1 }; continue }
            cand.append(l)
        }
        let n1 = cand.count
        cand = removeOwnOutput(cand)
        if count && diag.enabled { diag.s.dropSelf += n1 - cand.count }
        var allBlocks = makeBlocks(cand)
        if flag("deduplicateCopies", true) {
            var regions = subtitleRegions
            allBlocks = regions.deduplicated(allBlocks)
            if count { subtitleRegions = regions }
        }
        if count && diag.enabled { diag.s.blocksIn += allBlocks.count }
        let blocks = selectBlocks(allBlocks, diagnosticCount: count)
        if count && diag.enabled { diag.s.blocksKept += blocks.count }
        var texts: [String] = []
        for b in blocks {
            let t = blockText(b)
            let singleCJK = allowsSingleCJK(t)
            if TextSim.norm(t).count < 2 && !singleCJK { continue }
            if flag("dropNoise", true) && TextIntel.isNoise(t, allowSingleCJK: singleCJK) { if count && diag.enabled { diag.s.dropNoise += 1 }; continue }
            if isTargetLanguage(t) { if count && diag.enabled { diag.s.dropTarget += b.count }; continue }
            texts.append(t)
        }
        return dedupe(texts).map { String($0.prefix(400)) }
    }

    /// Queues a quiet, low-priority translation that only fills the cache.
    func speculate(_ blocks: [String]) {
        guard speculationAllowed else { return }
        // Confirmed translations own the model. A changing subtitle should not
        // multiply low-priority speculative work while a confirmed job is busy.
        guard !busy, queued == nil else {
            if diag.enabled {
                diag.s.specSkipped += 1
                diag.s.legacyBusySpeculationSkips += 1
            }
            return
        }
        let thermal = ProcessInfo.processInfo.thermalState
        if ProcessInfo.processInfo.isLowPowerModeEnabled || thermal == .serious || thermal == .critical { return }
        let joined = blocks.joined(separator: "\n")
        guard !frozen, joined != lastHandled, joined != lastSpecText else {
            if diag.enabled { diag.s.legacyDuplicateSpeculationSkips += 1 }
            return
        }
        if flag("selectiveSpeculation", true), TextSim.similar(joined, lastSpecText, 0.97) {
            if diag.enabled {
                diag.s.specSkipped += 1
                diag.s.legacyDuplicateSpeculationSkips += 1
            }
            return
        }
        lastSpecText = joined
        specQueued = blocks
        startDrain()
    }

    // MARK: Reading-order calibration
    /// Reads each text block forwards and backwards; if backwards reads more naturally, the frame is upside down.
    private func updateOrderVote(_ lines: [OCRLine]) {
        guard !calibrated || flag("continuousRotation", false) else { return }
        var diff = 0.0
        for b in makeBlocks(lines) where b.count >= 2 {
            let fwd = readingOrder(b).map(\.t)
            diff += TextIntel.orderScore(fwd) - TextIntel.orderScore(Array(fwd.reversed()))
        }
        guard diff != 0 else { return }
        orderVote = max(-30, min(30, orderVote * 0.8 + diff))
        votesSinceChange += 1
        if diag.enabled { diag.s.orderVote = orderVote }
        guard frameRotMode == "auto" else { return }
        if RotationBudget.sufficientEvidence(vote: orderVote, samples: votesSinceChange) {
            if calibrated && flag("continuousRotation", false) { rotationBudget.reset() }
            guard let nextRotation = rotationBudget.next() else { return }
            autoRot = nextRotation
            rotRev += 1
            invalidatePending()
            orderVote = 0; votesSinceChange = 0; calibrated = false
            if diag.enabled { diag.s.calibrated = false }
            if rotationBudget.exhausted {
                calibrated = true
                if diag.enabled { diag.s.calibrated = false }
                diag.log("Rotation probes exhausted; holding capture orientation until device orientation or settings change")
            } else { diag.log("Reading order looks reversed → trying rotation \(autoRot * 90)°") }
            syncConfig()
        } else if orderVote > 4 && !calibrated {
            calibrated = true
            if diag.enabled { diag.s.calibrated = true }
            diag.log("Reading order OK at rotation \(autoRot * 90)°")
        }
    }

    /// Optional active-text prioritization works with every preset category.
    private func selectBlocks(_ blocks: [[OCRLine]], diagnosticCount: Bool) -> [[OCRLine]] {
        guard !blocks.isEmpty else { return [] }
        let maxH = blocks.map { blockHeight($0) }.max() ?? 0
        var kept = blocks
        if flag("activeTextFocus", true) {
            let beforeHeightFilter = kept.count
            // Tiny dialogue must not be excluded because a persistent label uses a larger font.
            kept = blocks.filter { blockHeight($0) >= max(0.006, maxH * 0.20) }
            if kept.isEmpty { kept = blocks }
            // Aligned visible lyrics are one reading group, even with separate OCR boxes.
            let sorted = kept.sorted { ($0.first?.y ?? 0) > ($1.first?.y ?? 0) }
            var groups: [[[OCRLine]]] = []
            for block in sorted {
                let x = block.map(\.x).reduce(0, +) / Double(block.count)
                let y = block.map(\.y).reduce(0, +) / Double(block.count)
                if let i = groups.firstIndex(where: { group in
                    guard let previous = group.last else { return false }
                    let px = previous.map(\.x).reduce(0, +) / Double(previous.count)
                    let py = previous.map(\.y).reduce(0, +) / Double(previous.count)
                    return abs(px - x) <= 0.12 && abs(py - y) <= max(0.12, blockHeight(block) * 4.2)
                }) { groups[i].append(block) } else { groups.append([block]) }
            }
            let summaries = groups.map { group -> MovieTextGroup in
                let lines = group.flatMap { $0 }
                let x = lines.reduce(0.0) { $0 + $1.x } / Double(max(1, lines.count))
                let y = lines.reduce(0.0) { $0 + $1.y } / Double(max(1, lines.count))
                return MovieTextGroup(text: lines.map(\.t).joined(separator: " "), x: x, y: y,
                    weight: group.reduce(0.0) { $0 + blockWeight($1) })
            }
            // A label becomes background only after repeated, spatially stable OCR.
            // A lone held subtitle/lyrics group remains eligible for translation.
            let strongest = summaries.indices.max(by: { summaries[$0].weight < summaries[$1].weight })
            let chosen = movieTextFocus.preferredIndex(in: summaries, at: Date().timeIntervalSince1970)
            diag.noteMovieSelection(groups: groups.count,
                filteredSmall: beforeHeightFilter - kept.count,
                temporalOverride: chosen != nil && chosen != strongest,
                confirmed: diagnosticCount)
            if let chosen {
                kept = groups[chosen]
                if flag("preserveRelatedMovieGroups", false) {
                    // Opt-in lyrics mode: keep only nearby aligned secondary groups.
                    let focus = summaries[chosen]
                    for index in groups.indices where index != chosen {
                        let other = summaries[index]
                        let aligned = abs(focus.x - other.x) <= 0.10
                        let close = abs(focus.y - other.y) <= 0.24
                        let substantial = other.weight >= focus.weight * 0.26
                        if aligned && close && substantial { kept.append(contentsOf: groups[index]) }
                    }
                }
            } else { kept = [] }
        } else if area == .smart {
            kept = blocks.filter { blockHeight($0) >= maxH * 0.4 }
        }
        kept = Array(kept.sorted { blockWeight($0) > blockWeight($1) }.prefix(6))
        func top(_ b: [OCRLine]) -> Double { b.map { $0.y + $0.h / 2 }.max() ?? 0 }
        func left(_ b: [OCRLine]) -> Double { b.map { $0.x - ($0.w ?? 0) / 2 }.min() ?? 0 }
        return kept.sorted { a, b in
            let ra = Int((1 - top(a)) * 14), rb = Int((1 - top(b)) * 14)
            return ra != rb ? ra < rb : left(a) < left(b)
        }
    }

    func enqueue(_ blocks: [String]) {
        if activeTranslationSystem != .legacy {
            guard !blocks.isEmpty else { return }
            var packet = Packet(kind: "ocr", version: AppVersion.full, frames: frames, lines: [])
            packet.candidateID = "manual-\(UUID().uuidString)"; packet.stable = true
            packet.firstSeenAt = Date().timeIntervalSince1970
            handleModeCaption(blocks, packet: packet)
            return
        }
        let joined = blocks.joined(separator: "\n")
        guard !blocks.isEmpty, joined != lastHandled else { return }
        if PipelineSafety.isDuplicate(blocks, previous: lastHandled.components(separatedBy: "\n")) { return }
        generation += 1
        cancelPresentation()
        lastHandled = joined
        if queued != nil { diag.noteQueueReplacement() }
        // Confirmed OCR supersedes unstarted speculation; the currently
        // executing model retains its physical session until it returns.
        if SubtitlePerformancePolicy.discardPendingSpeculation(
            confirmedIncoming: true, speculativePending: specQueued != nil) {
            specQueued = nil
            diag.noteModelState("legacy_queued_speculation_superseded")
        }
        queued = blocks
        queuedAt = Date()
        queuedWaitOwner = busy ? activeQueueOwner : .scheduling
        if presentQueuedFromRAMIfComplete() { return }
        if SubtitlePerformancePolicy.preemptSpeculation(activeText: currentSpeculativeText, confirmedText: joined) {
            // Different input cannot supply an exact whole-caption reuse result.
            // Cancellation unwinds the single drain before confirmed work starts.
            let shared = sharedInFlightUnits(blocks)
            if shared == 0 {
                if diag.enabled { diag.s.specPreemptionRequested += 1 }
                cancelDrain(preemptSpeculation: true)
                detachCancelledSpeculationIfEnabled()
            }
            else { diag.noteSharedModelUnits(shared) }
        } else if currentSpeculativeText == joined {
            if diag.enabled { diag.s.specMatchingConfirmation += 1 }
            diag.noteLegacySpeculationInFlightMatch(candidate: queuedPacket?.candidateID)
        }
        startDrain()
    }

    /// Swift Task cancellation alone may leave Apple's model request running.
    /// Only the disposable speculative session receives explicit cancellation;
    /// confirmed work retains its own warm session and the drain still awaits unwind.
    func cancelDrain(preemptSpeculation: Bool) {
        drainTask?.cancel()
        if preemptSpeculation, speculativeSessions.cancelActive() {
            diag.noteModelState("speculative_stop_requested")
        }
    }
}
