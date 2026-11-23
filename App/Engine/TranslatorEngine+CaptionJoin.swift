import Foundation

extension TranslatorEngine {
    /// 2.5.5 (Legacy, switch "captionJoin", default on): the text blocks kept for one subtitle become one text for
    /// the translator. Off, or any other mode, the blocks are returned unchanged (2.5.4 behaviour). The counters
    /// only count confirmed readings.
    func captionJoinedTexts(_ texts: [String], count: Bool) -> [String] {
        guard TranslationHotPathAB.captionJoin, activeTranslationSystem == .legacy, texts.count > 1 else { return texts }
        if count && diag.enabled { diag.s.captionMultiBlock += 1 }
        let joined = CaptionJoin.joined(texts)
        if joined.count < texts.count, count && diag.enabled { diag.s.captionJoined += 1 }
        return joined
    }
}
