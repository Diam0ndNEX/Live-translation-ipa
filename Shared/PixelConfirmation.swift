import Foundation

/// v2.0.0 G1: pixel-verified caption confirmation.
///
/// After the first OCR read of a new caption, the extension samples a fixed
/// grid of luminance values inside that caption's OCR line boxes. On later
/// frames it samples the same grid again. When the text pixels are unchanged
/// for at least the normal confirmation interval, the frame would OCR to the
/// same text, so it counts as the second identical read without running OCR
/// again. Any doubt falls back to a normal OCR read; this policy may only
/// say "same", never invent text.
enum PixelConfirmation {
    /// Grid per OCR line: columns across the line box, rows down it.
    static let columns = 64
    static let rows = 6
    /// At most this many lines (subtitles are 1-3 lines); more lines -> OCR.
    static let maximumLines = 4
    /// A grid point is "ink" when it differs this much from the box median.
    static let inkContrast = 60
    /// An ink point is lost when its luminance moves more than this.
    static let inkTolerance = 40
    /// Too few ink points means the text cannot be verified -> OCR.
    static let minimumInk = 12

    struct Fingerprint: Equatable {
        let luma: [UInt8]
        let ink: [Bool]
        let median: Int
        let inkBright: Bool
        let inkCount: Int
    }

    /// Builds a fingerprint from sampled luminance, or nil when the sample
    /// does not contain enough clear text strokes to verify.
    static func fingerprint(_ luma: [UInt8]) -> Fingerprint? {
        guard luma.count >= minimumInk else { return nil }
        let sorted = luma.sorted()
        let median = Int(sorted[sorted.count / 2])
        var ink = [Bool](repeating: false, count: luma.count)
        var bright = 0, dark = 0
        for index in luma.indices {
            let delta = Int(luma[index]) - median
            if abs(delta) >= inkContrast {
                ink[index] = true
                if delta > 0 { bright += 1 } else { dark += 1 }
            }
        }
        let count = bright + dark
        guard count >= minimumInk else { return nil }
        return Fingerprint(luma: luma, ink: ink, median: median, inkBright: bright >= dark, inkCount: count)
    }

    /// True only when the text strokes are where they were and no new strokes
    /// of the same polarity appeared. Background changes between strokes are
    /// tolerated; new or removed glyphs are not.
    static func matches(_ original: Fingerprint, _ current: [UInt8]) -> Bool {
        guard current.count == original.luma.count else { return false }
        let allowance = max(1, original.inkCount / 50)
        var lost = 0, gained = 0
        for index in current.indices {
            let now = Int(current[index])
            if original.ink[index] {
                if abs(now - Int(original.luma[index])) > inkTolerance {
                    lost += 1
                    if lost > allowance { return false }
                }
            } else {
                let polarity = original.inkBright ? now - original.median : original.median - now
                if polarity >= inkContrast {
                    gained += 1
                    if gained > allowance { return false }
                }
            }
        }
        return true
    }

    /// Normalized sample points (x right, y up, 0...1 of the oriented image)
    /// for line boxes given as centre x/y, width and height. Boxes are padded
    /// slightly so strokes on the edge are included.
    static func samplePoints(lines: [(x: Double, y: Double, w: Double, h: Double)]) -> [(x: Double, y: Double)]? {
        guard !lines.isEmpty, lines.count <= maximumLines else { return nil }
        var points: [(x: Double, y: Double)] = []
        points.reserveCapacity(lines.count * columns * rows)
        for line in lines {
            guard line.w.isFinite, line.h.isFinite, line.w > 0, line.h > 0 else { return nil }
            let width = min(1, line.w * 1.04), height = min(1, line.h * 1.15)
            let left = line.x - width / 2, bottom = line.y - height / 2
            for row in 0..<rows {
                let y = bottom + height * (Double(row) + 0.5) / Double(rows)
                for column in 0..<columns {
                    let x = left + width * (Double(column) + 0.5) / Double(columns)
                    points.append((min(1, max(0, x)), min(1, max(0, y))))
                }
            }
        }
        return points
    }

    /// The pixel check may confirm only after the same dwell a second OCR
    /// read would have needed: the planned interval, at least 100 ms.
    static func dwellSatisfied(sinceFirstReadStart elapsed: Double, interval: Double) -> Bool {
        guard elapsed.isFinite, interval.isFinite else { return false }
        return elapsed >= max(0.1, interval)
    }
}
