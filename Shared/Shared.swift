// ScreenLingo – Shared – v0.7.0
import Foundation

enum AppVersion {
    static let version = "0.8.0"
    static let build = 10
    static var full: String { "v\(version) (build \(build))" }
    // Newest first. Add a line here each time you bump the version.
    static let changelog: [(String, String)] = [
        ("0.8.0", "ScreenLingo bundle identity, advanced controls, live OCR tuning, and safer capture preferences."),
        ("0.7.1", "ScreenLingo branding, version metadata, and icon support."),
        ("0.7.0", "ScreenLingo refresh: persistent translation history, safer iOS 18 translation timeouts, refreshed branding, and clearer copy/clear history actions."),
        ("0.6.0", "Fixes mixed-up sentence order: text is grouped into blocks (bubble vs background), each block read in proper order and translated sentence by sentence in one batch. Ignores background text in another language. Floating-window appearance + text size, speak translation aloud."),
        ("0.5.0", "Much faster: OCR only reads your chosen area at reduced size, with the source language as a hint. Stops reading its own floating window (learns where it is). Speed presets, translation cache, auto-clear when text ends, pause, history tab, live OCR/translate timing + memory in diagnostics."),
        ("0.4.1", "Start section has a visible broadcast icon + separate floating-window button. Fixed build error."),
        ("0.4.0", "Stronger OCR (all languages, contrast fallback, stability check). Smart area. Auto-detect favors installed languages. Shows what OCR reads."),
        ("0.3.0", "Fixed PiP not starting, retries + error messages, redesigned UI, swap button, languages grouped by ready/available."),
        ("0.2.0", "No more App Group. Language pickers, pack downloads, modes, OCR area, window size, diagnostics, test button."),
        ("0.1.0", "First version.")
    ]
}

enum Loopback { static let port: UInt16 = 48721 }

struct OCRLine: Codable {
    var t: String      // text
    var x: Double      // normalized mid X
    var y: Double      // normalized mid Y of the FULL frame (0 = bottom, 1 = top)
    var h: Double      // normalized height (full frame)
    var w: Double?     // normalized width
}

/// Extension → app
struct Packet: Codable {
    var kind: String   // "ping" | "ocr" | "clear"
    var version: String
    var frames: Int
    var lines: [OCRLine]
    var ocrMs: Double?
    var memFreeMB: Double?
}

/// App → extension (sent back over the same localhost link)
struct Config: Codable {
    var lang: String       // "auto" or a language code (used as OCR language hint)
    var y0: Double         // OCR area, 0 = bottom
    var y1: Double         // 1 = top
    var maxEdge: Double    // longest image side OCR works at (smaller = faster)
    var interval: Double   // minimum seconds between OCR passes
    var paused: Bool
}

enum TextSim {
    static func norm(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

    static func grams(_ s: String) -> Set<String> {
        let c = Array(norm(s))
        if c.isEmpty { return [] }
        if c.count == 1 { return [String(c)] }
        return Set((0..<(c.count - 1)).map { String(c[$0...($0 + 1)]) })
    }

    /// Jaccard similarity of character bigrams (tolerates small OCR differences).
    static func similar(_ a: String, _ b: String, _ threshold: Double = 0.85) -> Bool {
        if a == b { return true }
        if a.isEmpty || b.isEmpty { return false }
        let x = grams(a), y = grams(b)
        let uni = x.union(y).count
        return uni > 0 && Double(x.intersection(y).count) / Double(uni) >= threshold
    }

    /// Fraction of `a`'s bigrams that appear in `set`.
    static func containment(of a: String, in set: Set<String>) -> Double {
        let g = grams(a)
        if g.isEmpty { return 0 }
        return Double(g.intersection(set).count) / Double(g.count)
    }
}
