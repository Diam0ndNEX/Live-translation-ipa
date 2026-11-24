import SwiftUI

// 2.6.5 (switch learnedEarlyStart, default on). Legacy early translations start from a caption's first reading when
// OCR is sure enough. The fixed limit (0.85) refused 320 first readings in report 2.6.3 build 128, and 326 of 502
// captions got no early translation. The limit is now learned from this run: every first reading is compared with
// the text confirmed for the same caption. Unverified on a device (nothing was compiled or run when it was written).
extension TranslatorEngine {
    /// The confidence a first reading needs, learned from the run when enough first readings were compared.
    func earlyStartConfidence(base: Double) -> Double {
        guard TranslationHotPathAB.learnedEarlyStart, activeTranslationSystem == .legacy,
              !flag("coolMode", false) else { return base }
        let learned = specLearner.threshold(fallback: base)
        if diag.enabled { diag.s.specLearnedMilli = Int((learned * 1000).rounded()) }
        return learned
    }

    /// Called for every first (unconfirmed) reading, before any admission rule. Only the first reading of a caption
    /// counts. A caption that is never confirmed counts as "not the final text" once it falls out of the book.
    func noteFirstReading(_ p: Packet, texts: [String]) {
        guard TranslationHotPathAB.learnedEarlyStart, activeTranslationSystem == .legacy, p.stable == false,
              let candidate = p.candidateID, !texts.isEmpty else { return }
        let lines = speculationJudgedLines(p, candidateTexts: texts)
        guard !lines.isEmpty else { return }
        let confidence = lines.map { $0.confidence ?? 0 }.min() ?? 0
        let identity = ConfirmedSourceIdentity.normalize(texts.joined(separator: "\n"))
        for lost in firstReadings.noteFirst(candidate: candidate, confidence: confidence, identity: identity) {
            recordEarlyStartOutcome(confidence: lost.confidence, matched: false)
        }
    }

    /// Called for every confirmed reading: was the first reading of this caption already the final text?
    func noteConfirmedAgainstFirst(_ p: Packet, texts: [String]) {
        guard TranslationHotPathAB.learnedEarlyStart, activeTranslationSystem == .legacy,
              p.stable != false, let candidate = p.candidateID,
              let note = firstReadings.take(candidate: candidate) else { return }
        let identity = ConfirmedSourceIdentity.normalize(texts.joined(separator: "\n"))
        recordEarlyStartOutcome(confidence: note.confidence, matched: identity == note.identity)
    }

    private func recordEarlyStartOutcome(confidence: Double, matched: Bool) {
        specLearner.record(confidence: confidence, matched: matched)
        if diag.enabled {
            diag.s.specLearnSamples += 1
            if matched { diag.s.specLearnMatches += 1 }
        }
    }

    /// An early translation was admitted only because the learned limit is lower than the fixed one.
    func noteLearnedAdmission(judged lines: [OCRLine], base: Double, effective: Double) {
        guard effective < base, diag.enabled,
              !SpeculationPolicy.credible(lines: lines, threshold: base) else { return }
        diag.s.earlyStartByLearning += 1
    }
}
