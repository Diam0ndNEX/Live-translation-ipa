import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    func startDrain() {
        guard !busy, drainTask == nil, queued != nil || specQueued != nil else { return }
        interruptWarmupForLiveWork()
        drainTask = Task(priority: .userInitiated) { await drain() }
    }

    func drain() async {
        guard !busy else { return }
        busy = true
        let epoch = drainEpoch
        defer {
            if epoch == drainEpoch {
                busy = false
                activeQueueOwner = .scheduling
                drainTask = nil
                replayDeferredConfirmedIfPossible()
                startDrain()
            }
        }
        while queued != nil || specQueued != nil {
            guard !Task.isCancelled, epoch == drainEpoch else { return }
            if deferredConfirmedPacket != nil, activeCandidatePresented, !waitingToDisplay { return }
            if let b = queued {
                queued = nil
                currentTs = queuedTs; currentPacket = queuedPacket; currentQueuedAt = queuedAt
                diag.recordQueueWait(owner: queuedWaitOwner,
                    durationMs: max(0, Date().timeIntervalSince(queuedAt) * 1000),
                    candidate: queuedPacket?.candidateID)
                activeQueueOwner = .confirmed
                await process(b, display: true)
            } else if let sp = specQueued {
                specQueued = nil
                currentPacket = specPacket
                if speculationAllowed {
                    activeQueueOwner = .speculative
                    currentSpeculativeText = sp.joined(separator: "\n")
                    await process(sp, display: false)
                    if epoch == drainEpoch { currentSpeculativeText = nil }
                    else if let at = detachedSpeculationAt {
                        diag.noteModelState("legacy_detached_speculation_released",
                                            durationMs: max(0, Date().timeIntervalSince(at) * 1000))
                    }
                }
            }
        }
    }

    /// Keep a completed unit, never a partial sentence. The old caption is not
    /// presented or persisted; a queued replacement must assemble every unit.
    func retainCompletedModelUnit(key: String, value: String,
        context: Int, rules: String, destination: String, mode: TranslationTestMode,
        bank: TranslationRAMBank, confirmed: Bool, speculativeID: UInt64?, epoch: Date) {
        guard context == contextRevision, mode == memoryTestMode, bank === ram,
              mode.allowsReuse, !bypassMemory, rules == memoryRuleToken,
              destination == targetCode,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bank.values[key] == nil else { return }
        bank.values[key] = value
        bank.savedKeys.remove(key)
        if !confirmed {
            if bank.specKeys.insert(key).inserted, diag.started == epoch { diag.noteSpeculativeUnit("retained") }
            if let speculativeID { bank.speculativeOrigins[key] = speculativeID }
        }
        touchCache(key)
        trimCache()
        if diag.started == epoch {
            if confirmed { diag.noteCompletedWorkRecovery(1) }
            else if diag.enabled { diag.s.specRetainedUnits += 1 }
        }
        // A needed result may arrive before unrelated units in the old batch.
        // This uses the existing complete-caption and presentation safeguards.
        presentQueuedFromRAMIfComplete()
    }

    /// Shared by real processing and the in-flight exact-key overlap check.
    func preparedSourceUnits(_ text: String, language: String, slang: Bool,
                                     speakers: Bool, protected: [String]) -> [PreparedSourceUnit] {
        let key = PreparedUnitIdentity(text: text, language: language, slang: slang,
                                       speakers: speakers, protected: protected, context: contextRevision)
        let reuseEnabled = activeTranslationSystem != .legacy ||
            TranslationHotPathAB.reuseLegacyPreparedUnits
        if reuseEnabled, let cached = preparedUnits.lookup(key) { return cached }
        let expanded = slang ? TextIntel.expandSlang(text, lang: language) : text
        let parts = speakers ? TextIntel.splitDialogue(expanded) : [(label: String?.none, text: expanded)]
        let output = parts.map { part in
            let tokens = TextIntel.protect(part.text, words: protected)
            return PreparedSourceUnit(label: part.label, sentences: splitSentences(tokens.text), tokens: tokens.tokens)
        }
        preparedUnits.insert(output, for: key)
        return output
    }

    /// Synchronous and RAM-only: safe while the model lane is awaiting unrelated work.
    /// Probe every current unit before consuming provenance or confirming any result.
    func cachedCaption(_ blocks: [String], identity: String) -> ExactCaptionResult? {
        if let ready = ram.captions[identity] {
            diag.noteExactCaptionReuse()
            return ready
        }
        guard sourceCode != "auto", memoryTestMode.allowsReuse, !bypassMemory else { return nil }
        let source = Locale.Language(identifier: sourceCode)
        guard source.languageCode != Locale.Language(identifier: targetCode).languageCode else { return nil }
        let id = source.minimalIdentifier
        let rules = memoryRuleToken
        let never = list("neverTranslate", lower: false)
        let fixes = pairs("sourceFixes")
        var units: [[CaptionTranslationUnit]] = []
        var hits: [(key: String, text: String, value: String, lookupMs: Double)] = []
        for raw in blocks {
            let text = cleanedSource(raw, enabled: flag("cleanOCR", true), fixes: fixes)
            var row: [CaptionTranslationUnit] = []
            for part in preparedSourceUnits(text, language: source.languageCode?.identifier ?? id,
                    slang: flag("slang", true), speakers: flag("speakerDetect", true), protected: never) {
                var values: [String?] = []
                for sentence in part.sentences {
                    let key = SharedTranslationWork.unitKey(source: id, target: targetCode, text: sentence,
                        protectedWords: part.tokens.map { "\($0.0)=\($0.1)" }, rules: rules)
                    let lookupStarted = ProcessInfo.processInfo.systemUptime
                    guard let value = ram.values[key],
                          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    hits.append((key, sentence, value,
                        (ProcessInfo.processInfo.systemUptime - lookupStarted) * 1000))
                    values.append(value)
                }
                row.append(CaptionTranslationUnit(label: part.label, sentences: part.sentences,
                                                  out: values, tokens: part.tokens))
            }
            units.append(row)
        }
        guard let result = CaptionAssembly.complete(units, glossary: pairs("glossary")) else { return nil }
        // No suspension above: mode, rules, bank and candidate cannot change mid-probe.
        let mayPersist = allowsPersistentTranslations && !flag("privateSession", false)
        for hit in hits {
            touchCache(hit.key)
            let speculative = ram.specKeys.remove(hit.key) != nil
            let saved = ram.savedKeys.remove(hit.key) != nil
            ram.speculationWindow.recordConfirmedOutcome(saved: saved && !speculative)
            if speculative {
                diag.noteSpeculativeUnit("reused")
                if let origin = ram.speculativeOrigins.removeValue(forKey: hit.key) { ram.speculationWindow.reuse(origin) }
            }
            diag.recordMemory(speculative ? .speculativeHit : .ramHit,
                durationMs: hit.lookupMs,
                candidate: queuedPacket?.candidateID, frameIndex: queuedPacket?.frames, unitKey: hit.key)
            if mayPersist, TranslationUnitPlanning.mayRemember(hit.text, confirmed: true),
               ram.confirmedKeys.insert(hit.key).inserted, !saved {
                queueMemory(hit.key, hit.value, independentlyConfirmed: speculative)
            }
            if diag.enabled {
                if speculative { diag.s.specHits += 1 }
                else if saved { diag.s.savedHits += 1 }
                else { diag.s.cacheHits += 1 }
            }
        }
        for row in units { for unit in row { if let label = unit.label { diag.learn(label) } } }
        diag.recordSourceLanguage(id, origin: .selected)
        if diag.enabled { diag.s.sentences += hits.count }
        diag.noteRAMCaptionBypass()
        let ready = ExactCaptionResult(translated: result, sentences: hits.count)
        ram.retainCaption(key: identity, result: ready)
        return ready
    }

    func sharedInFlightUnits(_ blocks: [String]) -> Int {
        guard activeQueueOwner != .scheduling, drainTask?.isCancelled == false,
              sourceCode != "auto", memoryTestMode.allowsReuse, !bypassMemory,
              !modelUnitKeysInFlight.isEmpty else { return 0 }
        let source = Locale.Language(identifier: sourceCode)
        let id = source.minimalIdentifier
        let rules = memoryRuleToken
        let never = list("neverTranslate", lower: false)
        let fixes = pairs("sourceFixes")
        let cleaningEnabled = flag("cleanOCR", true)
        let slangEnabled = flag("slang", true)
        let speakersEnabled = flag("speakerDetect", true)
        let languageCode = source.languageCode?.identifier ?? id
        var keys = Set<String>()
        for raw in blocks {
            let text = cleanedSource(raw, enabled: cleaningEnabled, fixes: fixes)
            for part in preparedSourceUnits(text, language: languageCode,
                    slang: slangEnabled, speakers: speakersEnabled, protected: never) {
                for sentence in part.sentences {
                    keys.insert(SharedTranslationWork.unitKey(source: id, target: targetCode, text: sentence,
                        protectedWords: part.tokens.map { "\($0.0)=\($0.1)" }, rules: rules))
                }
            }
        }
        return ExactModelWorkPolicy.sharedUnits(inFlight: modelUnitKeysInFlight, required: keys,
            workContext: modelContextInFlight, currentContext: contextRevision, reuseAllowed: true)
    }
}
