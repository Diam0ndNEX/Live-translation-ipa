import SwiftUI

extension TranslatorEngine {
    /// 2.5.1 (Legacy, switch "legacyEagerSpeculation", default on): a first reading that arrives while the previous
    /// confirmed caption is still being translated or waits to be shown starts its early translation anyway.
    /// It does not replace the active caption: confirmation, the shown text and the handoff rules are unchanged.
    /// The same admission rules as an ordinary first reading apply (confidence, the adaptive window, the
    /// armed-deferral switch); `speculate` then queues it behind the running confirmed job.
    func speculateBehindActiveCaption(_ p: Packet, texts: [String]) {
        guard TranslationHotPathAB.legacyEagerSpeculation, activeTranslationSystem == .legacy,
              p.stable == false, !texts.isEmpty, speculationAllowed, flag("translateAhead", true) else { return }
        if p.pixelArmed == true, TranslationHotPathAB.deferArmedSpeculation { return }
        let base = flag("coolMode", false) ?
            max(0.95, num("speculationConfidence", 0.85)) : num("speculationConfidence", 0.85)
        let minimum = earlyStartConfidence(base: base) // 2.6.5 (learnedEarlyStart)
        // 2.5.4: judged on the lines that make up the text to translate (see speculationJudgedLines).
        let judgedLines = speculationJudgedLines(p, candidateTexts: texts)
        guard !flag("selectiveSpeculation", true) ||
            SpeculationPolicy.credible(lines: judgedLines, threshold: minimum) else { return }
        let strong = SpeculationPolicy.credible(lines: judgedLines, threshold: max(0.95, minimum))
        guard ram.speculationWindow.allowsCredibleOpportunity(
            enabled: flag("adaptiveSpeculation", true), strongCandidate: strong) else { return }
        noteLearnedAdmission(judged: judgedLines, base: base, effective: minimum)
        specPacket = p
        speculate(texts)
    }
}
