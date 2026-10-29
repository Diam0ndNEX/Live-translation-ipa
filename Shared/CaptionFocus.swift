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
    mutating func scan(at time: Double, y0: Double, y1: Double, context: String) -> Scan {
        if self.context != context { self.context = context; region = nil; lastBroad = -Double.infinity }
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
}
