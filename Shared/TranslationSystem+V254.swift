import Foundation

// 2.5.4: Legacy latency work on the wait for confirmation and on early translation. Pure policy and switch
// definitions, no UI or engine state, and no reference to types from Shared.swift, so the ThreeModes and
// HotPathAB test programs compile and test it with the rest of TranslationSystem. Nothing here was measured on a
// device.

extension TranslationHotPathAB {
    /// 2.5.4 switches: (setting key, pinned key, report label). Default ON; OFF gives the 2.5.3 behaviour.
    static let v254Switches: [(setting: String, pinned: String, report: String)] = [
        ("pixelManyLines", "pixelManyLinesPinned", "manyLinesAB"),
        ("captionLineSpeculation", "captionLineSpeculationPinned", "captionLinesAB")
    ]
    /// Both modes, CHANGES WHAT CONFIRMS WITHOUT A SECOND OCR READ: the pixel check covers up to 24 lines (8 before),
    /// each judged with its own tolerance. What is read and translated does not change; a changed line still
    /// sends the caption back to a normal OCR read.
    static var pixelManyLines: Bool {
        (UserDefaults.standard.object(forKey: "pixelManyLinesPinned") as? Bool) ?? true
    }
    /// Legacy only: whether an early translation is allowed is judged on the lines that make up the text to be
    /// translated, not on every line the capture found on the screen. Same model, same wording.
    static var captionLineSpeculation: Bool {
        (UserDefaults.standard.object(forKey: "captionLineSpeculationPinned") as? Bool) ?? true
    }
    static let v254ReportLabels: [(key: String, label: String)] = [
        ("manyLinesAB", "pixel check up to 24 lines"),
        ("captionLinesAB", "early translation judged on caption lines")
    ]
}

/// 2.5.4: which lines of an OCR packet make up the text that will be translated.
/// The 2.5.3 rule asked for a confidence of 0.85 on EVERY line of the packet, including menus, logos and
/// background text on the same screen, so one such line could veto the early translation of a clear caption.
/// In the 2.5.2 device run about a quarter of the captions that took more than 300 ms to confirm had no early
/// translation at all.
enum CaptionLineSelection {
    /// Indices of the lines whose normalized text is part of the normalized text to be translated. When none
    /// matches (the text was rewritten by the block step), every line is kept, which is the 2.5.3 behaviour.
    static func indices(lineTexts: [String], candidate: String, normalize: (String) -> String) -> [Int] {
        var kept: [Int] = []
        for (index, text) in lineTexts.enumerated() {
            let normalized = normalize(text)
            if !normalized.isEmpty, candidate.contains(normalized) { kept.append(index) }
        }
        return kept.isEmpty ? Array(lineTexts.indices) : kept
    }
}
