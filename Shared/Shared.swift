// Screen Translator – Shared – v0.11.0
import Foundation

enum AppVersion {
    static let version = "0.8.0"
    static let build = 37
    static var full: String { "v\(version) (build \(build))" }
    // Newest first. Add a line here each time you bump the version.
    static let changelog: [(String, String)] = [
        ("0.8.0", "Major workspace overhaul: photo/text translation, visual capture-area editor, focus reader, session controls, searchable history with notes, CSV/JSON export and restore, undo deletion, private sessions, OCR tuning and idle power saving."),
        ("1.5.0", "Integrated the latest main redesign, custom presets, diagnostics charts, translation memory and translate-ahead. Preserved ScreenLingo identity, small text, lyric rows and fragment protection. Fixed stale output, batch validation, frozen output and legacy timeouts."),
        ("0.11.0", "Faster translation with identical wording: translate-ahead (starts translating on first sight, shows when confirmed), warm translator, translation memory kept between launches, cached language-pack check. Sharing now goes through real files (fixes the endless Loading…)."),
        ("0.10.0", "Diagnostics rebuilt: Simple view (health score, plain-language fixes with one-tap buttons, live feed) and Detailed view with 7 pages. Real charts for speed, delay, frames per second, memory, temperature and battery, histograms, a session timeline of Live / Paused / Idle with event markers, translations per minute, a pipeline funnel and filter breakdown, language and cache charts, a searchable filterable event log, CSV export and a shareable report."),
        ("0.9.0", "Redesigned app. Custom presets (save, edit, duplicate, reorder, start-up preset) with icons and colours. New Home with live status badge, quick tiles and recent language pairs. Reader view, share-as-image, toasts, onboarding, keep-screen-awake, auto-copy, speech speed, saved history with search, stars and day groups, accent colours, Home sections you can hide, settings search and per-page reset."),
        ("0.8.0", "Fixes reversed sentence order (auto-detects upside-down frames and rotates them, or pick the rotation manually). Context layer: speaker names kept, chat slang expanded, OCR clean-up, noise filter, language lock, never-translate words. Live Diagnostics tab. 30+ new options, profiles, backup, history search + stars."),
        ("0.7.0", "App icon. Correct version shown when signing (was 1.0). Big new Settings screen: custom OCR area, ignore small text, ignore list, glossary, stability, floating-window font, hold time, auto-open. Quick presets (Movie/Game/Comic), setup checklist, export history."),
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
    var ts: Double?        // when the extension sent it (seconds since 1970)
    var rev: Int?          // settings revision the extension was using
    var bufW: Int?
    var bufH: Int?
    var orient: Int?       // raw RPVideoSampleOrientationKey value
    var cropW: Int?
    var cropH: Int?
    var passes: Int?       // OCR passes so far
    var skipped: Int?      // unchanged frames skipped
    var stable: Bool?      // false = first sighting (translate ahead), nil/true = confirmed
}

/// App → extension (sent back over the same localhost link)
struct Config: Codable, Equatable {
    var lang: String       // "auto" or a language code (used as OCR language hint)
    var y0: Double         // OCR area, 0 = bottom
    var y1: Double         // 1 = top
    var maxEdge: Double    // longest image side OCR works at (smaller = faster)
    var interval: Double   // minimum seconds between OCR passes
    var paused: Bool
    var stability: Int?    // how many identical reads before text is sent (1 = instant)
    var rot: Int?          // extra clockwise quarter-turns applied to the frame (0...3)
    var rev: Int?          // bumps whenever rot changes so stale packets can be ignored
    var boost: Int?        // 0 = off, 1 = only when nothing is found, 2 = always
    var skipUnchanged: Bool?
    var speculate: Bool?   // send an early "first sighting" so the app can translate ahead
    var confidence: Double? = nil
    var correction: Bool? = nil
    var idleBackoff: Bool? = nil
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
