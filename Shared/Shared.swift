// Screen Translator – Shared – v0.4.1
import Foundation

enum AppVersion {
    static let version = "0.4.1"
    static let build = 5
    static var full: String { "v\(version) (build \(build))" }
    // Newest first. Add a line here each time you bump the version.
    static let changelog: [(String, String)] = [
        ("0.4.1", "Fixed build error (broken newline string). Start section now has a visible broadcast icon + separate floating-window button instead of an invisible overlay."),
        ("0.4.0", "Start now also opens the capture sheet. Stronger OCR (all languages, contrast fallback, stability check for fading/typing text). Smart area = whole screen, biggest text. Auto-detect favors installed languages. Shows what OCR reads."),
        ("0.3.0", "Fixed PiP not starting (preview must stay on screen), PiP start retries + error messages, redesigned UI, language swap button, languages grouped by ready/available."),
        ("0.2.0", "No more App Group (fixes 'nothing happens' when sideloaded). Source/target language pickers, language pack downloads, modes, OCR area, window size, diagnostics, test button."),
        ("0.1.0", "First version.")
    ]
}

enum Loopback { static let port: UInt16 = 48721 }

struct OCRLine: Codable {
    var t: String      // text
    var x: Double      // normalized mid X
    var y: Double      // normalized mid Y (0 = bottom, 1 = top)
    var h: Double      // normalized height
}

struct Packet: Codable {
    var kind: String   // "ping" or "ocr"
    var version: String
    var frames: Int
    var lines: [OCRLine]
}
