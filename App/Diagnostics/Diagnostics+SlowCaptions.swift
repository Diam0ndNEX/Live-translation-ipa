import Foundation

// 2.6.3: the slowest captions of the run, kept with their stage times (numbers only).
extension Diagnostics {
    func noteSlowCaption(_ b: LatencyBreakdown) {
        guard enabled else { return }
        SlowCaptions.insert(&slowestCaptions, [b.total, b.recognition, b.confirmation, b.delivery, b.queue,
                                               b.translation, b.displayHold, b.rendering])
    }
}
