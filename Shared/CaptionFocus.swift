import Foundation

/// Optional new-mode OCR crop. Coordinates stay in full-screen bottom-origin space.
/// Any uncertain observation loses the crop; a periodic broad pass finds moved text.
struct CaptionFocus {
    struct Scan {
        let y0: Double
        let y1: Double
        let broad: Bool
    }
    private var region: (Double, Double)?
    private var context = ""
    private var lastBroad = -Double.infinity
    /// `useBand` (2.5.0, item E): a focused read covers the trusted band when there is one, so a caption that
    /// grows by a line is still read whole. False gives the 2.4.0 crop.
    mutating func scan(at time: Double, y0: Double, y1: Double, context: String, useBand: Bool = false) -> Scan {
        if self.context != context { self.context = context; region = nil; lastBroad = -Double.infinity; forgetBand() }
        // The trusted band outlives the gap between two captions (no text on screen clears `region`, not the band),
        // so the first read of the next caption can be a band read. The whole area is still read every 0.75 s.
        if useBand, time - lastBroad < 0.75, let area = trustedScanArea(y0: y0, y1: y1) {
            return Scan(y0: area.0, y1: area.1, broad: false)
        }
        if time - lastBroad >= 0.75 || region == nil {
            lastBroad = time
            return Scan(y0: y0, y1: y1, broad: true)
        }
        let lower = max(y0, region!.0), upper = min(y1, region!.1)
        guard upper - lower >= 0.04 else { region = nil; return Scan(y0: y0, y1: y1, broad: true) }
        return Scan(y0: lower, y1: upper, broad: false)
    }
    mutating func requiresRediscovery(scan: Scan, recognized: String, previous: String) -> Bool {
        guard !scan.broad, recognized != previous else { return false }
        region = nil
        return true
    }
    mutating func observe(bounds: [(center: Double, height: Double, confidence: Double)]) {
        guard !bounds.isEmpty, bounds.allSatisfy({ $0.confidence >= 0.85 && $0.height > 0 }) else { region = nil; return }
        let low = bounds.map { $0.center - $0.height / 2 }.min()!
        let high = bounds.map { $0.center + $0.height / 2 }.max()!
        region = (max(0, low - 0.05), min(1, high + 0.05))
    }

    // MARK: 2.5.0 trusted caption band (item E)
    //
    // Until 2.4.0 a focused read whose text had changed was always thrown away and the whole area was read again,
    // so the first read of every new caption was a whole-area read. With the trusted band the focused read is
    // used when the whole area has repeatedly shown text only inside the band, and the new lines sit clearly
    // inside it. What this gives up: text that appears outside the band is not seen until the next whole-area
    // read (at most 0.75 s later, the interval `scan` already uses). All of it is switchable.

    /// Whole-area reads in a row whose confident text lay entirely inside the band.
    private(set) var bandAgreement = 0
    private var band: (Double, Double)?
    /// Whole-area reads that must agree before a focused read is trusted.
    static let requiredAgreement = 2
    /// The band reaches this many line heights above and below the caption lines, so a caption that grows by one
    /// line still fits. Never less than `minimumPadding` of the screen height.
    static let paddingInLineHeights = 1.6
    static let minimumPadding = 0.05
    /// A trusted line must keep this share of its height away from both band edges (a cut-off line is not trusted).
    static let edgeMarginInLineHeights = 0.35

    /// Call after every read with text, before `observe`. `broad` is true for a whole-area read.
    mutating func learnBand(bounds: [(center: Double, height: Double, confidence: Double)], broad: Bool) {
        guard broad else { return }
        guard !bounds.isEmpty, bounds.allSatisfy({ $0.confidence >= 0.85 && $0.height > 0 }) else {
            band = nil; bandAgreement = 0
            return
        }
        let low = bounds.map { $0.center - $0.height / 2 }.min()!
        let high = bounds.map { $0.center + $0.height / 2 }.max()!
        if let current = band, low >= current.0, high <= current.1 {
            bandAgreement = min(bandAgreement + 1, 1000)
            return
        }
        // Text outside the band (or no band yet): start again from what the whole area shows now.
        let line = bounds.map { $0.height }.max() ?? 0
        let padding = max(Self.minimumPadding, line * Self.paddingInLineHeights)
        band = (max(0, low - padding), min(1, high + padding))
        bandAgreement = 1
    }

    /// A whole-area read found nothing: the band is kept (captions come and go), the count is not raised.
    /// A context change (rotation, area, language) forgets it.
    mutating func forgetBand() { band = nil; bandAgreement = 0 }

    /// The area a focused read should cover when the trusted band is in use: the learned band, inside the
    /// configured area. Nil when the band is not trusted yet.
    func trustedScanArea(y0: Double, y1: Double) -> (Double, Double)? {
        guard bandAgreement >= Self.requiredAgreement, let band else { return nil }
        let lower = max(y0, band.0), upper = min(y1, band.1)
        return upper - lower >= 0.04 ? (lower, upper) : nil
    }

    /// True when the changed text of a focused read may be used without reading the whole area again:
    /// the band is trusted, every line was read with high confidence, and no line touches an edge of the read area.
    func trusts(bounds: [(center: Double, height: Double, confidence: Double)], scan: Scan) -> Bool {
        guard !scan.broad, bandAgreement >= Self.requiredAgreement, band != nil, !bounds.isEmpty else { return false }
        return bounds.allSatisfy { line in
            guard line.confidence >= 0.85, line.height > 0 else { return false }
            let margin = line.height * Self.edgeMarginInLineHeights
            return line.center - line.height / 2 - margin >= scan.y0 &&
                line.center + line.height / 2 + margin <= scan.y1
        }
    }
}
