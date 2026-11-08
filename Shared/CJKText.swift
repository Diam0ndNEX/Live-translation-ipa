// ScreenLingo – Shared – One-character Chinese, Japanese and Korean captions (2.2.1, finding E13)
// Used by the capture extension (OCR line filter) and the app (extraction and noise filter), so Shared.
import Foundation

enum CJKText {
    /// True when `text` (ignoring surrounding whitespace) is exactly one character and that character is a
    /// Han ideograph, kana or Hangul letter. One character can be a whole word in these languages.
    /// Latin letters, digits, punctuation, symbols (for example "x" or a multiplication sign) and full-width
    /// Latin or digits are not accepted, so UI glyphs and icon labels keep the old two-character minimum.
    static func isSingleCJKWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let scalar = trimmed.unicodeScalars.first, trimmed.unicodeScalars.count == 1,
              trimmed.first?.isLetter == true else { return false }
        return isCJKLetter(scalar)
    }

    private static func isCJKLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF: return true          // Hiragana, Katakana
        case 0x3400...0x4DBF: return true          // CJK Extension A
        case 0x4E00...0x9FFF: return true          // CJK Unified Ideographs
        case 0xAC00...0xD7AF: return true          // Hangul syllables
        case 0xFF66...0xFF9F: return true          // half-width Katakana
        case 0xFFA0...0xFFDC: return true          // half-width Hangul
        default: return false                      // the rest of 0x3000-0x9FFF and 0xFF00-0xFFEF is punctuation or symbols
        }
    }
}
