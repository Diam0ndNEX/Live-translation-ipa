// ScreenLingo – Shared – v0.7.0
import Foundation

enum AppVersion {
    static let version = "1.3.2"
    static let build = 27
    static var full: String { "v\(version) (build \(build))" }
    // Newest first. Keep this aligned with MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml.
    static let changelog: [(String, String)] = [
        ("1.3.2", "Improve source-vs-target language checks, retry failed batches, configurable OCR cleanup, slang expansion, speaker and protected-term handling, source corrections, glossary rules, stable language lock, settings profiles/backup, and PiP font/highlighting controls."),
        ("1.3.1", "Prevent spatial-only PiP feedback suppression from deleting genuine source text; improve OCR dialogue grouping using box-edge spacing."),
        ("1.3.0", "Unify OCR row ordering across block grouping and translation; improve deterministic bounding-box row clustering and add canonical OCR-order diagnostics; build 25."),
        ("1.2.9", "Ignore captured ScreenLingo settings/diagnostics screens and retain full diagnostic trace history for .txt export; build 24."),
        ("1.2.8", "Add age-filtered 60-second compact reports, privacy redaction, and full diagnostic .txt export; synchronize app/extension version metadata; build 23."),
        ("1.2.7", "Fix spatially overbroad self-output suppression, reject system privacy-sheet OCR/noise, and compact diagnostic reports; build 22."),
        ("1.2.6", "Fix Swift compilation in diagnostic language-score formatting; remove an unused OCR geometry variable; build 21."),
        ("1.2.5", "Add a rolling 60-second OCR-to-translation trace with block geometry, filter decisions, language hypotheses, cache decisions, per-block translations, and one-tap report export; build 20."),
        ("1.2.4", "Improve multilingual live OCR by relying on Vision auto-language detection in Auto mode, stricter speech-region separation, and more conservative target-language feedback filtering; build 19."),
        ("1.2.3", "Fix live OCR updates by accepting changed capture packets immediately and grouping OCR lines before target-language filtering; build 18."),
        ("1.2.2", "Move the loopback UDP channel to a fresh port after persistent address-in-use failures; keep app and capture extension synchronized."),
        ("1.2.1", "Fix duplicate UDP listener startup on app activation, prevent port rebind races, and improve capture connection recovery diagnostics."),
        ("1.2.0", "Comic-context translation, stable OCR reading order, centered dialogue grouping, right-to-left manga support, block-order diagnostics, output truncation checks, and app/extension version 1.2.0 build 15."),
        ("1.1.0", "Improved comic dialogue ordering, richer live diagnostics, history search/export, quick output actions, cache controls, and explicit bundle version metadata."),
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

enum Loopback { static let port: UInt16 = 48723 }

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
    var minimumConfidence: Double
    var languageCorrection: Bool
    var minimumTextHeight: Double?
    var ignoreList: [String]?
    var dropNoise: Bool?
    var boost: Int?
    var stability: Int?
    var skipUnchanged: Bool?
    var rotation: Int?
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
