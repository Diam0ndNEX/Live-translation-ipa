import Foundation

extension TranslatorEngine {
    /// 2.5.4 (Legacy, switch "captionLineSpeculation", default on): the lines whose confidence decides whether a
    /// first reading may start its early translation. Off, or when no line matches, this is every line of the
    /// packet, as before. The confidence limit and the other admission rules are unchanged.
    func speculationJudgedLines(_ p: Packet, candidateTexts: [String]) -> [OCRLine] {
        guard TranslationHotPathAB.captionLineSpeculation, activeTranslationSystem == .legacy else { return p.lines }
        let candidate = candidateTexts.map(TextSim.norm).joined(separator: "\n")
        let kept = CaptionLineSelection.indices(lineTexts: p.lines.map(\.t), candidate: candidate,
                                                normalize: TextSim.norm)
        return kept.map { p.lines[$0] }
    }
}
