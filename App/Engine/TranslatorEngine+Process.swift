import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    func process(_ blocks: [String], display: Bool = true) async {
        if display { isTranslating = true }
        defer { if display { isTranslating = false } }
        let t0 = Date()
        if display { processingStarted = t0; savedRequests = 0 }
        let workGeneration = generation
        let workContext = contextRevision
        let workMode = memoryTestMode
        let workRAM = ram
        let workCandidate = activeCandidateID
        let rules = memoryRuleToken
        let destination = targetCode
        let speculativeStart = Date()
        let diagnosticEpoch = diag.started
        let speculativeID: UInt64? = display ? nil : ram.speculationWindow.begin()
        if !display && diag.enabled { diag.s.specStarted += 1 }
        defer {
            let discarded = Task.isCancelled || workContext != contextRevision || workCandidate != activeCandidateID
            if let speculativeID { workRAM.speculationWindow.finish(speculativeID, discarded: discarded) }
            if !display && diag.enabled && diag.started == diagnosticEpoch {
                let ms = Date().timeIntervalSince(speculativeStart) * 1000
                diag.s.specProcessingMs += ms
                if Task.isCancelled || workContext != contextRevision || workCandidate != activeCandidateID {
                    diag.s.specDiscarded += 1; diag.s.specDiscardedMs += ms
                } else { diag.s.specCompleted += 1 }
            }
        }
        diag.trace(currentPacket?.candidateID, stage: display ? "processing" : "speculating",
                   detail: "Translation started", frameIndex: currentPacket?.frames)
        let target = Locale.Language(identifier: destination)
        let cleanOn = flag("cleanOCR", true), slangOn = flag("slang", true), speakerOn = flag("speakerDetect", true)
        let fixes = pairs("sourceFixes")
        let never = list("neverTranslate", lower: false)

        var units: [[CaptionTranslationUnit]] = []
        var pending: [String: [(b: Int, u: Int, s: Int, text: String, key: String)]] = [:]
        var srcLangs: [String: Locale.Language] = [:]
        var eligibleMemoryKeys = Set<String>()
        var resolvedLookups: [String: MemoryLookupResult] = [:]
        var translatedAny = false
        var unresolvedSource = false
        var failureReason: String? = nil
        func isCurrent() -> Bool {
            let current = !Task.isCancelled && workContext == contextRevision && workMode == memoryTestMode &&
                (!display || workGeneration == generation) &&
                CandidateValidity.isCurrent(workCandidate, active: activeCandidateID,
                    enabled: flag("steadyCaptions", true))
            if display && !current && diag.detailedCollection && diag.started == diagnosticEpoch {
                diag.trace(workCandidate, stage: "cancelled",
                           detail: "Obsolete translation generation or candidate")
            }
            return current
        }

        /// Remembers a finished sentence. Early (translate-ahead) results are marked so we can show how often they pay off.
        func store(_ key: String, _ out: String) {
            guard isCurrent(), memoryTestMode.allowsReuse else { return }
            guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            ram.values[key] = out
            ram.savedKeys.remove(key)
            if display && eligibleMemoryKeys.contains(key) && !flag("freshTranslationTest", false) {
                ram.confirmedKeys.insert(key)
                queueMemory(key, out, independentlyConfirmed: true)
            }
            memoryDirty = true
            touchCache(key)
            if !display {
                if ram.specKeys.insert(key).inserted { diag.noteSpeculativeUnit("retained") }
                if let speculativeID { ram.speculativeOrigins[key] = speculativeID }
            }
        }

        for (bi, raw) in blocks.enumerated() {
            let text = cleanedSource(raw, enabled: cleanOn, fixes: fixes)
            if display && diag.detailedCollection && text != raw {
                diag.trace(workCandidate, stage: "ocrCorrection",
                           detail: "Recognized text was cleaned or corrected")
            }
            guard let choice = detectSource(text, record: display) else {
                if display && diag.detailedCollection {
                    diag.trace(workCandidate, stage: "language",
                               detail: "No compatible source language selected")
                }
                unresolvedSource = true
                units.append([CaptionTranslationUnit(label: nil, sentences: [text], out: [text], tokens: [])])
                continue
            }
            guard choice.language.languageCode != target.languageCode else {
                units.append([CaptionTranslationUnit(label: nil, sentences: [text], out: [text], tokens: [])])
                continue
            }
            let src = choice.language
            let id = src.minimalIdentifier
            if display && diag.detailedCollection {
                diag.trace(workCandidate, stage: "language",
                           detail: "Source language resolved for current candidate")
            }
            if display {
                if diag.s.sourceUsed != id || diag.s.sourceOrigin != choice.origin.title {
                    diag.event(.language, "Source resolved: \(id) (\(choice.origin.title))")
                }
                diag.recordSourceLanguage(id, origin: choice.origin)
                if choice.origin != .selected, detectedLang != id { detectedLang = id }
            }
            srcLangs[id] = src
            let sourceConfidence = sourceCode == "auto" ? (languageEvidence(text, limit: 5).1.filter {
                SourceLanguageRouter.sameLanguage($0.key.rawValue, id)
            }.values.max() ?? 0) : 0
            let memoryEligible = MemoryRetentionPolicy.mayPersist(privateSession: flag("privateSession", false),
                selectedSource: sourceCode != "auto", confidence: sourceConfidence, confirmed: display) && allowsPersistentTranslations
            let parts = preparedSourceUnits(text, language: src.languageCode?.identifier ?? id,
                slang: slangOn, speakers: speakerOn, protected: never)
            var row: [CaptionTranslationUnit] = []
            for (ui, d) in parts.enumerated() {
                if display, let name = d.label { diag.learn(name) }
                let sentences = d.sentences
                if display && diag.detailedCollection {
                    diag.trace(workCandidate, stage: "segmentation",
                               detail: "Translation units assigned to stable block")
                }
                if display && diag.enabled { diag.s.sentences += sentences.count }
                var outs: [String?] = []
                for (si, s) in sentences.enumerated() {
                    let key = SharedTranslationWork.unitKey(source: id, target: destination, text: s, protectedWords: d.tokens.map { "\($0.0)=\($0.1)" }, rules: rules)
                    if memoryEligible && TranslationUnitPlanning.mayRemember(s, confirmed: display) {
                        eligibleMemoryKeys.insert(key)
                    }
                    let lookupStart = ProcessInfo.processInfo.systemUptime
                    let bypassReuse = bypassMemory || flag("freshTranslationTest", false)
                    if display && bypassReuse {
                        diag.recordMemory(.bypassed, candidate: workCandidate, unitKey: key)
                    }
                    var resolvedHit = bypassReuse ? nil : ram.values[key]
                    var diskHit = false
                    if resolvedHit == nil, !bypassReuse, allowsPersistentTranslations, memoryReady, flag("remember", true), !flag("privateSession", false) {
                        let lookup: MemoryLookupResult
                        if let previous = resolvedLookups[key] { lookup = previous }
                        else {
                            lookup = await memoryStore.lookup(key: key)
                            resolvedLookups[key] = lookup
                        }
                        guard isCurrent() else {
                            if display {
                                // Never attribute an obsolete result to the newer
                                // packet. Count it as cancelled, not as a usable hit.
                                if diag.started == diagnosticEpoch {
                                    diag.recordMemory(.cancelled, durationMs: lookup.durationMs,
                                        candidate: workCandidate, unitKey: key)
                                }
                            }
                            return
                        }
                        resolvedHit = lookup.value
                        diskHit = lookup.value != nil
                        if display {
                            let outcome: MemoryDiagnosticOutcome
                            switch lookup.outcome {
                            case "timeout": outcome = .timeout
                            case "normalized_hit": outcome = .normalizedHit
                            case "incompatible", "conflict": outcome = .compatibilityRejected
                            case "database_error", "unavailable": outcome = .databaseUnavailable
                            default: outcome = diskHit ? (lookup.origin == "legacy" ? .legacyHit : .persistentHit) : .miss
                            }
                            diag.recordMemory(outcome, durationMs: lookup.durationMs,
                                              candidate: currentPacket?.candidateID,
                                              frameIndex: currentPacket?.frames, unitKey: key)
                        }
                        if let value = resolvedHit {
                            ram.values[key] = value; ram.savedKeys.insert(key); touchCache(key)
                        }
                    }
                    if let hit = resolvedHit {
                        touchCache(key)
                        outs.append(hit); translatedAny = true
                        if display {
                            if memoryTestMode == .temporaryMemory { diag.noteTemporaryReuse() }
                            let speculativeHit = ram.specKeys.remove(key) != nil
                            if speculativeHit { diag.noteSpeculativeUnit("reused") }
                            if speculativeHit, let origin = ram.speculativeOrigins.removeValue(forKey: key) {
                                ram.speculationWindow.reuse(origin)
                            }
                            let savedFromRAM = ram.savedKeys.remove(key) != nil
                            let savedHit = diskHit || savedFromRAM
                            ram.speculationWindow.recordConfirmedOutcome(saved: savedHit && !speculativeHit)
                            if !diskHit { diag.recordMemory(speculativeHit ? .speculativeHit : .ramHit,
                                                                  durationMs: (ProcessInfo.processInfo.systemUptime - lookupStart) * 1000,
                                                                  candidate: currentPacket?.candidateID,
                                                                  frameIndex: currentPacket?.frames, unitKey: key) }
                            // A speculative result was produced by the current on-device
                            // model, not by historical memory. Once this exact key is
                            // independently confirmed by stable OCR, it is safe to use
                            // as evidence for lazy legacy reconciliation without another
                            // model call. Ordinary RAM/SQLite hits remain untrusted proof.
                            if memoryEligible && ram.confirmedKeys.insert(key).inserted && !savedHit {
                                queueMemory(key, hit, independentlyConfirmed: speculativeHit)
                            }
                            if diag.enabled {
                                if speculativeHit { diag.s.specHits += 1 }
                                else if savedHit { diag.s.savedHits += 1 }
                                else { diag.s.cacheHits += 1 }
                            }
                            diag.trace(currentPacket?.candidateID, stage: "cache", detail: speculativeHit ? "Speculative hit" : (savedHit ? "Saved-memory hit" : "Session hit"))
                        }
                    } else {
                        outs.append(nil)
                        if display && memoryTestMode == .temporaryMemory {
                            diag.recordMemory(.temporaryMiss, candidate: workCandidate, unitKey: key)
                        }
                        if display {
                            ram.speculationWindow.recordConfirmedOutcome(saved: false)
                            if diag.enabled { diag.s.cacheMisses += 1 }
                        }
                        pending[id, default: []].append((bi, ui, si, s, key))
                    }
                }
                row.append(CaptionTranslationUnit(label: d.label, sentences: sentences, out: outs, tokens: d.tokens))
            }
            units.append(row)
        }

        var failed = false
        for (id, items) in pending {
            guard let src = srcLangs[id] else { continue }
            guard isCurrent() else { return }
            let availability = await pairStatus(src, target)
            guard isCurrent() else { return }
            if availability == .unsupported {
                failureReason = "\(id) → \(targetCode) isn't supported"
                if display { status = failureReason ?? "Unsupported language pair"; diag.event(.language, status) }
                failed = true; continue
            }
            if availability == .supported {
                if !display { continue }
                failureReason = "Download the \(id) → \(targetCode) language packs in Languages"
                status = failureReason ?? "Language pack missing"
                diag.event(.language, status)
            }
            if display && diag.enabled { diag.s.batches += 1 }
            let installed = availability == .installed
            let plan = TranslationBatchPlan(items.map { $0.text }, contexts: items.map { $0.key })
            if display { savedRequests += items.count - plan.unique.count }
            diag.noteExactUnitCoalescing(items.count - plan.unique.count)
            if !display && diag.enabled { diag.s.specModelRequests += plan.unique.count }
            if display && diag.detailedCollection {
                diag.trace(workCandidate, stage: "freshTranslation",
                           detail: "Uncached units submitted to on-device translation")
            }
            let streamPartials = installed && workMode.allowsReuse &&
                (display || flag("incrementalBatchRecovery", false))
            var completedParts: [Int: String] = [:]
            var partialHandler: (@MainActor (Int, String) -> Void)?
            if streamPartials {
                let exactKeys = plan.uniqueContexts
                partialHandler = { [weak self] index, value in
                    guard index >= 0, index < exactKeys.count else { return }
                    completedParts[index] = value
                    self?.retainCompletedModelUnit(key: exactKeys[index], value: value,
                        context: workContext, rules: rules, destination: destination,
                        mode: workMode, bank: workRAM, confirmed: display,
                        speculativeID: speculativeID, epoch: diagnosticEpoch)
                }
            }
            modelUnitKeysInFlight = Set(items.map { $0.key })
            modelContextInFlight = workContext
            let batch = await translateBatch(plan.unique, source: src, target: target, installed: installed,
                                             speculative: !display, partial: partialHandler)
            // 2.2.3 (L2): a detached speculative call must not erase the newer confirmed call's in-flight set.
            if modelUnitKeysInFlight == Set(items.map { $0.key }) {
                modelUnitKeysInFlight.removeAll()
                modelContextInFlight = nil
            }
            if !isCurrent() {
                // Cancellation is cooperative: confirmed or speculative model work
                // can finish after a different caption arrives. Recover only completed exact-key
                // units in the SAME context, never publish this old caption,
                // never retry it and never write unconfirmed output to disk.
                let recovered = SubtitlePerformancePolicy.retainedSpeculativeResults(
                    keys: items.map { $0.key },
                    values: batch.flatMap { plan.expand($0.map(Optional.some)) },
                    workContext: workContext, currentContext: contextRevision,
                    reuseAllowed: workMode == memoryTestMode && !bypassMemory && !flag("freshTranslationTest", false) &&
                        rules == memoryRuleToken && destination == targetCode)
                var retained = 0
                for (key, value) in recovered where ram.values[key] == nil {
                    ram.values[key] = value
                    ram.savedKeys.remove(key)
                    if !display, ram.specKeys.insert(key).inserted { diag.noteSpeculativeUnit("retained") }
                    if let speculativeID { ram.speculativeOrigins[key] = speculativeID }
                    touchCache(key)
                    retained += 1
                }
                trimCache()
                if diag.enabled && diag.started == diagnosticEpoch {
                    if !display { diag.s.specRetainedUnits += retained }
                    else { diag.noteCompletedWorkRecovery(retained) }
                }
                return
            }
            guard isCurrent() else { return }
            if display && diag.detailedCollection {
                diag.trace(workCandidate, stage: "translationResult",
                           detail: (batch?.count == plan.unique.count) ?
                                   "On-device model batch returned expected count" :
                                   "Translation batch was incomplete; retry policy applies")
            }
            var uniqueResults: [String?]
            if let batch, batch.count == plan.unique.count {
                uniqueResults = batch.map(Optional.some)
            } else {
                // Tentative work gets one attempt. Let confirmed processing own
                // retries instead of holding its queue behind speculative retries.
                if !display { return }
                diag.log("Batch failed – retrying unique sentences")
                uniqueResults = []
                for (index, sentence) in plan.unique.enumerated() {
                    guard isCurrent() else { return }
                    if let completed = completedParts[index] {
                        uniqueResults.append(completed)
                        continue
                    }
                    if !display && diag.enabled { diag.s.specModelRequests += 1 }
                    let result = await translateBatch([sentence], source: src, target: target, installed: installed, speculative: !display)
                    uniqueResults.append(result?.count == 1 ? result?.first : nil)
                }
            }
            guard isCurrent(), let results = plan.expand(uniqueResults) else { return }
            for (index, item) in items.enumerated() {
                if let value = results[index] {
                    units[item.b][item.u].out[item.s] = value
                    store(item.key, value)
                    translatedAny = true
                } else {
                    failed = true
                    if display && diag.enabled { diag.s.failures += 1 }
                }
            }
        }
        guard isCurrent(), (!paused || manualMode) else { return }
        trimCache()
        bypassMemory = false

        guard translatedAny else {
            if display {
                if failed, failureReason == nil, !Task.isCancelled, sourceCode == "auto", flag("languageRecovery", true) {
                    languageFailures += 1
                    if languageFailures >= 2 {
                        languageRouter.reset(); languageContext.reset(); lockedLang = nil; languageCache.removeAll(); languageFailures = 0
                        diag.event(.language, "Automatic source recovery after repeated translation failures")
                        rotRev += 1; syncConfig()
                    }
                }
                lastHandled = ""
                status = failed ? (failureReason ?? "Translation failed – check the language packs in Languages")
                    : (unresolvedSource ? "Could not identify the source – choose a source language in Languages" : "Text is already in the target language")
            }
            return
        }
        if !display { return }          // translate-ahead: the result now waits in the active RAM bank
        guard !failed else {
            lastHandled = ""
            status = failureReason ?? "Translation incomplete – keeping the previous result. Tap Retry."
            return
        }
        guard let assembled = CaptionAssembly.complete(units, glossary: pairs("glossary")) else {
            lastHandled = ""
            status = "Translation incomplete – keeping the previous result. Tap Retry."
            return
        }
        languageFailures = 0
        translateMs = Date().timeIntervalSince(t0) * 1000
        diag.trace(currentPacket?.candidateID, stage: "ready", detail: "Translation assembled")
        var sentenceCount = 0
        for row in units { for u in row { sentenceCount += u.sentences.count } }
        if memoryTestMode.allowsReuse,
           let key = ExactCaptionIdentity.key(blocks: blocks, source: sourceCode,
                                              target: targetCode, rules: rules) {
            ram.retainCaption(key: key, result: ExactCaptionResult(
                translated: assembled, sentences: sentenceCount))
        }
        diag.recordTranslate(ms: translateMs, sentences: sentenceCount,
                             from: srcLangs.keys.sorted().joined(separator: "+"), to: targetCode,
                             preview: assembled)
        if diag.enabled { diag.s.translations += 1 }
        if diag.enabled { diag.s.chars += blocks.joined().count }
        status = "\(srcLangs.keys.sorted().joined(separator: "+")) → \(targetCode) ✓"
        let timing = PresentationTiming(packet: currentPacket, firstSeen: currentTs,
            queuedAt: currentQueuedAt, processingAt: processingStarted, processingMs: translateMs,
            savedRequests: savedRequests, readyAt: Date())
        schedulePresentation(blocks.joined(separator: "\n"), assembled,
                             generation: workGeneration, context: workContext, timing: timing)
    }
}
