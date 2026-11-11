import Foundation

/// 2.5.0: the new numbers of items A, C, D, E, F and the quiet re-warm. Names are fixed (`V250Names`); a name that
/// is not in that list is ignored, so nothing but counts and milliseconds can be recorded here.
extension Diagnostics {
    func noteV250(counter name: String, by amount: Int = 1) {
        guard enabled, amount > 0, V250Names.counters.contains(name) else { return }
        v250Counts[name, default: 0] += amount
    }

    func noteV250(metric name: String, ms: Double) {
        guard enabled, ms.isFinite, ms >= 0, V250Names.metrics.contains(name) else { return }
        v250Samples[name, default: []].append(ms)
        if v250Samples[name, default: []].count > 1200 { v250Samples[name]?.removeFirst() }
    }

    /// Whole-broadcast totals the capture extension sends with each OCR packet.
    func noteV250Packet(_ p: Packet) {
        guard enabled, p.kind == "ocr" else { return }
        func set(_ name: String, _ value: Int?) {
            if let value, value >= 0 { v250Counts[name] = value }
        }
        set("trustedBandReads", p.trustedBandReads)
        set("headStartPrePasses", p.headStartPrePasses)
        set("headStartSent", p.headStartSent)
        set("headStartConfirmed", p.headStartConfirmed)
        set("headStartMissed", p.headStartMissed)
        if let reasons = p.extraReadReasons, reasons.count == V250Names.extraReadCounters.count {
            for (name, value) in zip(V250Names.extraReadCounters, reasons) { set(name, value) }
        }
        if let ms = p.headStartPrePassMs { noteV250(metric: "headStartPrePassMs", ms: ms) }
    }

    func resetV250() {
        v250Counts = [:]
        v250Samples = [:]
    }
}
