import Foundation

extension TranslatorEngine {
    /// 2.5.6 (Legacy, switch "growthSettle", default on). A confirmed reading that is the previous reading with
    /// more text at the end is held, latest wins, until the text has been unchanged for the learned quiet period
    /// (never longer than CaptionGrowthTracker.maximumTotal), and then handled once, as a replay. A different
    /// caption drops a held state: the screen has moved on. Returns true when the packet was held.
    func holdGrowingCaption(_ p: Packet, text: String, receivedAt: Date, now: Date) -> Bool {
        guard TranslationHotPathAB.growthSettle, activeTranslationSystem == .legacy else { return false }
        switch captionGrowth.observe(text, at: now.timeIntervalSince1970) {
        case .different:
            if growthHeldPacket != nil {
                discardHeldGrowth()
                if diag.enabled { diag.s.growthDropped += 1 }
            }
            return false
        case .same:
            return growthHeldPacket != nil
        case .extended:
            if diag.enabled {
                diag.s.growthSteps += 1
                if growthHeldPacket == nil { diag.s.growthHeld += 1 } else { diag.s.growthIntermediate += 1 }
            }
            growthHeldPacket = p
            growthHeldReceivedAt = receivedAt
            let since = growthHeldSince ?? now
            growthHeldSince = since
            let wait = captionGrowth.wait(elapsed: now.timeIntervalSince(since))
            growthTask?.cancel()
            growthTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled, let pending = self.growthHeldPacket else { return }
                let received = self.growthHeldReceivedAt
                self.growthHeldPacket = nil
                self.growthHeldSince = nil
                self.growthTask = nil
                if self.diag.enabled { self.diag.s.growthReleased += 1 }
                self.handleContent(pending, receivedAt: received, replayed: true)
            }
            diag.notePipelineDecision(candidate: p.candidateID, frameIndex: p.frames,
                stage: "stability", reason: "growing_caption_held")
            return true
        }
    }

    /// First readings that are only a longer version of the last confirmed reading are not translated ahead:
    /// the text is still growing and the held state will be translated once it stops.
    func isGrowingFirstReading(_ text: String, now: Date) -> Bool {
        TranslationHotPathAB.growthSettle && activeTranslationSystem == .legacy
            && captionGrowth.wouldExtend(text, at: now.timeIntervalSince1970)
    }

    func discardHeldGrowth() {
        growthTask?.cancel()
        growthTask = nil
        growthHeldPacket = nil
        growthHeldSince = nil
    }

    /// New capture context, mode change or cleared subtitle: forget the held state and the previous reading.
    func growthReset() {
        discardHeldGrowth()
        captionGrowth.restart()
    }
}
