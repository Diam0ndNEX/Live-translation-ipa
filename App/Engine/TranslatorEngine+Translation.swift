import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    // MARK: Translation
    var memoryRuleToken: String {
        let keys = ["cleanOCR", "slang", "speakerDetect", "neverTranslate", "sourceFixes", "glossary"]
        var snapshot = keys.map { key in "\(key)=\(ud.object(forKey: key) ?? Self.defaults[key] ?? "")" }.joined(separator: "\u{1F}")
        // Preserve the original v4 memory rule digest when the optional model
        // strategy is OFF. Only isolate outputs when a genuinely distinct
        // low-latency model was selected on a supported OS.
        if #available(iOS 26.4, *) {
            snapshot = TranslationModelMemoryPolicy.rulesContext(
                base: snapshot, lowLatency: false)
        }
        if snapshot != rulesSnapshot {
            rulesSnapshot = snapshot
            rulesDigest = SHA256.hash(data: Data(snapshot.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return rulesDigest
    }

    func detectSource(_ text: String, record: Bool = true) -> (language: Locale.Language, origin: SourceLanguageOrigin)? {
        if sourceCode != "auto" { return (Locale.Language(identifier: sourceCode), .selected) }
        var evidence = languageEvidence(text, limit: 5).1
        var usedContext = false
        let now = Date().timeIntervalSince1970
        let rawHypotheses = Dictionary(uniqueKeysWithValues: evidence.map { ($0.key.rawValue, $0.value) })
        if flag("contextualLanguage", true), languageContext.mayAssist(rawHypotheses, now: now) {
            let combined = languageEvidence(languageContext.text + " " + text, limit: 5).1
            if let best = combined.max(by: { $0.value < $1.value }), best.value >= 0.8,
               SourceLanguageRouter.sameLanguage(best.key.rawValue, languageContext.code) {
                evidence = combined; usedContext = true
            }
        }
        let previous = languageRouter.locked
        let choice = languageRouter.resolve(
            hypotheses: Dictionary(uniqueKeysWithValues: evidence.map { ($0.key.rawValue, $0.value) }),
            target: targetCode, letters: text.filter(\.isLetter).count,
            useLock: flag("langLock", true), record: record)
        if record, previous != languageRouter.locked {
            lockedLang = languageRouter.locked
            diag.log(lockedLang.map { "Language locked to \($0)" } ?? "Language lock released")
        }
        guard let choice else { return nil }
        if record && diag.enabled {
            diag.s.languageConfidence = evidence.filter { SourceLanguageRouter.sameLanguage($0.key.rawValue, choice.code) }.values.max() ?? 0
            diag.s.languageContextUsed = usedContext
        }
        if record, !SourceLanguageRouter.sameLanguage(choice.code, targetCode) {
            let currentConfidence = languageEvidence(text, limit: 5).1.filter { SourceLanguageRouter.sameLanguage($0.key.rawValue, choice.code) }.values.max() ?? 0
            languageContext.record(text, code: choice.code, confidence: currentConfidence, now: now)
        }
        return (Locale.Language(identifier: choice.code), choice.origin)
    }

    func pairStatus(_ src: Locale.Language, _ target: Locale.Language) async -> LanguageAvailability.Status {
        // Never use presentation-layer aggregate status to admit a model request.
        // The pending UI mode can differ from the currently active capture mode.
        let k = "\(src.minimalIdentifier)>\(target.minimalIdentifier)|\((activeTranslationSystem == .lowLatency) ? "low" : "default")"
        if let c = availCache[k], Date().timeIntervalSince(c.0) < 60 { return c.1 }
        let availability: LanguageAvailability
        if #available(iOS 26.4, *), (activeTranslationSystem == .lowLatency) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }
        let s = await availability.status(from: src, to: target)
        availCache[k] = (Date(), s)
        return s
    }

    /// Splits a block into sentences so each is translated on its own (better quality, cacheable).
    func splitSentences(_ text: String) -> [String] {
        guard text.count > 24 else { return [text] }
        // Include effective language context: an OCR language correction must not
        // borrow the segmentation calculated for a different configuration.
        let key = "seg\(TranslationUnitPlanning.version)|\(sourceCode)|\(detectedLang)|\(targetCode)|\(text)"
        let started = ProcessInfo.processInfo.systemUptime
        if let cached = segmentationCache.lookup(key) {
            diag.noteSegmentation(candidate: activeCandidateID, reused: true,
                durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000)
            return cached
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var units: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.isEmpty { return true }
            if sentence.count < 4, let previous = units.popLast() {
                units.append(previous + " " + sentence)
            } else {
                units.append(sentence)
            }
            return true
        }
        let result = TranslationUnitPlanning.units(source: text, candidates: units.isEmpty ? [text] : units)
        segmentationCache.insert(key, units: result)
        diag.noteSegmentation(candidate: activeCandidateID, reused: false,
            durationMs: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        return result
    }

    struct PreparedSourceUnit {
        let label: String?
        let sentences: [String]
        let tokens: [(String, String)]
    }
    struct PreparedUnitIdentity: Equatable {
        let text: String
        let language: String
        let slang: Bool
        let speakers: Bool
        let protected: [String]
        let context: Int
    }
    func cleanedSource(_ raw: String, enabled: Bool, fixes: [(String, String)]) -> String {
        var text = enabled ? TextIntel.cleanOCR(raw) : raw
        for (from, to) in fixes { text = text.replacingOccurrences(of: from, with: to, options: [.caseInsensitive]) }
        return text
    }
}
