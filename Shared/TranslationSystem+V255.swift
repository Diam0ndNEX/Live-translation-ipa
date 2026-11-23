import Foundation

// 2.5.5: Legacy translates the text blocks of one subtitle together. Pure policy and switch definitions, no UI or
// engine state, and no reference to types from Shared.swift, so the ThreeModes and HotPathAB test programs compile
// and test it with the rest of TranslationSystem. Nothing here was measured on a device.

extension TranslationHotPathAB {
    /// 2.5.5 switches: (setting key, pinned key, report label). Default ON; OFF gives the 2.5.4 behaviour.
    static let v255Switches: [(setting: String, pinned: String, report: String)] = [
        ("captionJoin", "captionJoinPinned", "captionJoinAB")
    ]
    /// Legacy only, CHANGES WHAT IS SENT TO THE TRANSLATOR: the text blocks that make up one subtitle are
    /// translated as one text, not one by one. A subtitle that the screen draws in two places (a line far below
    /// the first, a label above the sentence, a bracketed note in two pieces) was translated in pieces, each piece
    /// without the other.
    static var captionJoin: Bool {
        (UserDefaults.standard.object(forKey: "captionJoinPinned") as? Bool) ?? true
    }
    static let v255ReportLabels: [(key: String, label: String)] = [
        ("captionJoinAB", "text blocks of a subtitle translated together")
    ]
}

/// 2.5.5: joins the text blocks the capture step kept for one subtitle into a single text. No screen layout rule
/// is used, so it does not depend on how a video places its text: the blocks are already the ones chosen as the
/// active subtitle, in reading order. Very long results stay as they are, so one huge block is never sent.
enum CaptionJoin {
    static let maximumCharacters = 240

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3000...0x9FFF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
            || (0xFF00...0xFFEF).contains(scalar.value)
    }

    /// One text per subtitle when there are several blocks and the result is not longer than `maximumCharacters`;
    /// otherwise the blocks unchanged. Words are joined with a space, CJK text and a trailing hyphen without one,
    /// as inside a block.
    static func joined(_ texts: [String], maximumCharacters: Int = CaptionJoin.maximumCharacters) -> [String] {
        let parts = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard parts.count > 1 else { return texts }
        let total = parts.reduce(0) { $0 + $1.count } + parts.count - 1
        guard total <= maximumCharacters else { return texts }
        var out = ""
        for part in parts {
            if out.isEmpty { out = part; continue }
            if out.hasSuffix("-") { out += part }
            else if let last = out.unicodeScalars.last, isCJK(last) { out += part }
            else if let first = part.unicodeScalars.first, isCJK(first) { out += part }
            else { out += " " + part }
        }
        return [out]
    }
}
