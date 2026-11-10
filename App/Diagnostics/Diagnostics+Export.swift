import CryptoKit
import SwiftUI
import Charts
import os
import Darwin

extension Diagnostics {
    // MARK: Export
    func csv() -> String {
        var rows = ["series,time,value"]
        func dump(_ name: String, _ a: [Sample]) {
            for x in a { rows.append("\(name),\(x.t.timeIntervalSince1970),\(x.v)") }
        }
        dump("read_ms", ocr); dump("translate_ms", translate); dump("delay_ms", latency); dump("transfer_ms", transport)
        dump("fps", fps); dump("lines_per_packet", lineCounts); dump("extension_free_mb", extMem)
        dump("app_free_mb", appMem); dump("thermal_level", thermal); dump("battery_percent", battery)
        dump("cache_hit_percent", cacheRate)
        rows.append("")
        rows.append("time,kind,text")
        for e in events {
            let clean = e.text.replacingOccurrences(of: "\"", with: "'")
            rows.append("\(e.time.timeIntervalSince1970),\(e.kind.rawValue),\"\(clean)\"")
        }
        rows.append("")
        rows.append("pipeline_time,confirmation_ms,ocr_ms,delivery_filtering_ms,queue_ms,processing_ms,readability_hold_ms,frame_ms,total_ms")
        for sample in pipeline {
            let v = sample.stages
            rows.append("\(sample.date.timeIntervalSince1970),\(v.confirmation),\(v.recognition),\(v.delivery),\(v.queue),\(v.translation),\(v.displayHold),\(v.rendering),\(v.total)")
        }
        rows.append("")
        rows.append("source_language,confirmed_blocks")
        for (code, count) in sourceUsage.counts.sorted(by: { $0.key < $1.key }) { rows.append("\(code),\(count)") }
        rows.append("")
        rows.append("source_choice_mode,confirmed_blocks")
        for mode in SourceLanguageOrigin.allCases { rows.append("\(mode.rawValue),\(sourceUsage.origins[mode, default: 0])") }
        rows.append("")
        rows.append("candidate,stage,time,detail")
        for item in subtitleTraces {
            rows.append(ExportFormat.csv([[item.candidate, item.stage, item.time.ISO8601Format(), item.detail]]))
        }
        rows.append("")
        rows.append("metric,value")
        for (name, value) in [("session_cache_hits", Double(s.cacheHits)), ("saved_memory_hits", Double(s.savedHits)),
            ("speculative_hits", Double(s.specHits)), ("fresh_requests", Double(s.cacheMisses)),
            ("speculative_attempts", Double(s.specStarted)), ("speculative_completed", Double(s.specCompleted)),
            ("speculative_discarded", Double(s.specDiscarded)), ("speculative_skipped", Double(s.specSkipped)),
            ("discarded_speculative_ms", s.specDiscardedMs), ("language_confidence", s.languageConfidence),
            ("recorder_simple_ms", recorderCosts.simpleMs), ("recorder_detailed_ms", recorderCosts.detailedMs)] {
            rows.append("\(name),\(value)")
        }
        return rows.joined(separator: "\n")
    }

    /// v2.0.0 L1/L3/L2 one-line view of where confirmed sentences came from,
    /// how often new speculative sessions were created, and confirmed model
    /// time split by a nearby call on another session. Diagnostics only.
    var servedByLine: String {
        let total = s.specHits + s.cacheHits + s.savedHits + s.cacheMisses
        func share(_ n: Int) -> String { total == 0 ? "–" : "\(Int((Double(n) / Double(total) * 100).rounded()))%" }
        let minutes = max(1.0 / 60, Date().timeIntervalSince(started) / 60)
        let created = eventTotals["speculative_session_created", default: 0]
        func median(_ key: String) -> String {
            let values = (modelTimingSamples[key] ?? []).sorted()
            guard !values.isEmpty else { return "– (0)" }
            return "\(Int(values[values.count / 2])) ms (\(values.count))"
        }
        return "Served by (sentences): speculation \(share(s.specHits)), session RAM \(share(s.cacheHits)), saved memory \(share(s.savedHits)), model \(share(s.cacheMisses)) of \(total). Speculative sessions created \(created) (\(String(format: "%.1f", Double(created) / minutes))/min). Legacy confirmed model median: other session nearby \(median("legacy_confirmed_after_switch")), no switch \(median("legacy_confirmed_no_switch"))."
    }

    func report(engine: TranslatorEngine) -> String {
        let a = assessment(alive: engine.captureAlive, paused: engine.paused)
        let o = Diagnostics.summarize(ocr), t = Diagnostics.summarize(translate)
        let d = Diagnostics.summarize(latency), x = Diagnostics.summarize(transport)
        func line(_ n: String, _ s: Summary) -> String {
            "\(n): avg \(Int(s.avg)) ms, p50 \(Int(s.p50)), p95 \(Int(s.p95)), max \(Int(s.max)) (\(s.n) samples)"
        }
        var l: [String] = []
        l.append("ScreenLingo \(AppVersion.full) – diagnostics")
        l.append("Collection: \(enabled ? (detailedCollection ? "detailed" : "simple (graphs and events off)") : "off"); Cool mode: \(UserDefaults.standard.bool(forKey: "coolMode") ? "on" : "off").")
        l.append("Health \(a.score)/100 – \(a.headline)")
        for i in a.issues { l.append("  • \(i.title)") }
        l.append("Capture: \(engine.captureAlive ? "connected" : "not connected"), extension v\(engine.extensionVersion), drops \(s.captureDrops)")
        l.append("Frames \(s.frames) (\(Int(s.fps)) fps), OCR passes \(s.passes), skipped \(s.skippedFrames)")
        l.append("Frame \(s.bufferSize), read area \(s.cropSize), orientation \(s.orientation), rotation \(s.rotation * 90)°")
        l.append(line("Reading", o)); l.append(line("Translating", t)); l.append(line("Total delay", d)); l.append(line("Transfer", x))
        l.append("Extension memory free \(Int(s.extFreeMB)) MB (lowest \(s.minExtFreeMB > 9000 ? 0 : Int(s.minExtFreeMB)) MB)")
        l.append("Lines \(s.linesIn): area \(s.dropArea), small \(s.dropSmall), ignore \(s.dropIgnore), own window \(s.dropSelf), target language \(s.dropTarget); blocks \(s.blocksIn) → \(s.blocksKept), noise \(s.dropNoise), other language \(s.dropLanguage)")
        l.append("Order confidence \(String(format: "%.1f", s.orderVote)), calibrated \(s.calibrated), rotation tries \(s.rotationTries)")
        l.append("Translations \(s.translations), sentences \(s.sentences), cache \(s.cacheHits + s.savedHits)/\(s.cacheHits + s.savedHits + s.specHits + s.cacheMisses) (pre-translated \(s.specHits)), failures \(s.failures), engine \(s.sessionKind)")
        l.append("Configured source \(engine.sourceCode), last source used \(s.sourceUsed) (\(s.sourceOrigin)), automatic detector \(engine.sourceCode == "auto" ? "enabled" : "off – source selected"), locked \(s.lockedLang).")
        l.append("Cache origins: session \(s.cacheHits), saved memory \(s.savedHits), speculative \(s.specHits), fresh requests \(s.cacheMisses).")
        l.append(servedByLine)
        l.append("Speculative model requests \(s.specModelRequests); pipeline attempts \(s.specStarted), completed \(s.specCompleted), superseded/cancelled \(s.specDiscarded), declined \(s.specSkipped), unconsumed results \(engine.unconsumedSpeculation); processing \(Int(s.specProcessingMs)) ms, discarded work \(Int(s.specDiscardedMs)) ms. Attempts count pipeline jobs; cache hits count sentences.")
        l.append("Idle validation: selected \(s.legacyBatchEntries), verified \(s.legacyBatchVerified), skipped \(s.legacyBatchSkipped); peak workers \(s.legacyBatchPeakWorkers); model + commit wall time \(Int(s.legacyBatchElapsedMs)) ms.")
        l.append("v1.4.5: deferred confirmed handoffs \(s.confirmedHandoffDeferred); adaptive speculative skips \(s.adaptiveSpeculationSkipped); slow (>1200 ms) PiP enqueues \(s.slowTailEnqueues).")
        l.append("OCR confidence \(Int(s.ocrConfidence*100))%, source evidence \(s.sourceOrigin == "Selected" ? "manual selection" : "\(Int(s.languageConfidence*100))%"); recognition: \(s.recognitionReason); confirmation: \(s.confirmationReason).")
        l.append("Frame skips: unchanged \(s.unchangedSkipped), cadence \(s.cadenceSkipped), paused \(s.pausedSkipped); consecutive empty reads \(s.emptyReads), contrast retries \(s.retryCount).")
        l.append("Instrumented recorder elapsed self-time, app lifetime: simple \(String(format: "%.2f", recorderCosts.simpleMs)) ms / \(recorderCosts.simpleCalls) calls; detailed \(String(format: "%.2f", recorderCosts.detailedMs)) ms / \(recorderCosts.detailedCalls) calls. Excludes async chart drawing, translation and OCR; workloads may differ.")
        l.append("Source language inputs: " + sourceUsage.counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        l.append("Source choice modes: " + SourceLanguageOrigin.allCases.map { "\($0.title)=\(sourceUsage.origins[$0, default: 0])" }.joined(separator: ", "))
        l.append("Execution phase \(executionPhase), PiP \(engine.pipActive ? "active" : "inactive"); last packet \(lastPacketAt?.ISO8601Format() ?? "none"), last device sample \(lastDeviceSampleAt?.ISO8601Format() ?? "none").")
        l.append("Settings: mode=\(UserDefaults.standard.string(forKey: "mode") ?? "movie"), area=\(UserDefaults.standard.string(forKey: "area") ?? "smart"), speed=\(UserDefaults.standard.string(forKey: "speed") ?? "balanced"), configured rotation=\(UserDefaults.standard.string(forKey: "frameRot") ?? "auto"), confirmation reads=\((UserDefaults.standard.object(forKey: "stability") as? Int) ?? 2)")
        l.append("v1.5.0 experiments: low-latency model \(UserDefaults.standard.bool(forKey: "lowLatencyTranslation")), incremental recovery \(UserDefaults.standard.bool(forKey: "incrementalBatchRecovery")), subtitle-area sampling \(UserDefaults.standard.bool(forKey: "subtitleAwareChangeDetection")), additional lyric groups \(UserDefaults.standard.bool(forKey: "preserveRelatedMovieGroups")), direct PiP drawing \(UserDefaults.standard.bool(forKey: "directPiPBuffer")).")
        l.append("Continuity: confirmed candidates \(s.confirmedCandidatePackets), successful PiP enqueues \(s.enqueuedCandidateFrames), superseded before enqueue \(s.supersededUnpresentedConfirmed), deferred handoffs \(s.confirmedHandoffDeferred); these are not unique-subtitle or physical-presentation counts.")
        l.append("Speculation: discarded pipelines \(s.specDiscarded), completed superseded units retained \(s.specRetainedUnits), adaptive skips \(s.adaptiveSpeculationSkipped).")
        if UserDefaults.standard.bool(forKey: "diagIncludeText"), !UserDefaults.standard.bool(forKey: "privateSession") {
            l.append("Speakers: \(names.joined(separator: ", "))")
        }
        l.append("")
        if let latest = pipeline.last?.stages {
            l.append("Latest paired timing (ms): confirmation \(Int(latest.confirmation)), OCR \(Int(latest.recognition)), delivery/filtering \(Int(latest.delivery)), queue \(Int(latest.queue)), processing \(Int(latest.translation)), readability hold \(Int(latest.displayHold)), frame preparation \(Int(latest.rendering)), total \(Int(latest.total))")
            l.append("Total measures first OCR sighting to frame enqueue; it does not measure physical screen presentation. Confirmation and translation-ahead can overlap.")
        }
        l.append("Memory schema \(memoryHealth.schemaVersion), entries \(memoryHealth.totalEntries), ready \(memoryHealth.readyEntries), needs validation \(memoryHealth.needsValidation), conflicts \(memoryHealth.conflicts).")
        l.append("Memory migration: \(memoryHealth.migrationStatus); integrity: \(memoryHealth.integrity); pending writes \(memoryHealth.pendingWrites), failed writes \(memoryHealth.failedWrites).")
        l.append("Recent events:")
        for e in events.suffix(60).reversed() {
            l.append("\(e.time.formatted(date: .omitted, time: .standard)) [\(e.kind.title)] \(e.text)")
        }
        return l.joined(separator: "\n")
    }
}
