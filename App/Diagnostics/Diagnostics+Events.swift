import CryptoKit
import SwiftUI
import Charts
import os
import Darwin

extension Diagnostics {
    // MARK: Events
    func event(_ kind: EventKind, _ text: String, detail: String? = nil) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard detailedCollection else { return }
        events.append(TimelineEvent(time: Date(), kind: kind, text: text, detail: detail))
        let limit = max(300, min(1200, (UserDefaults.standard.object(forKey: "diagSamples") as? Int) ?? 600))
        if events.count > limit { events.removeFirst(events.count - limit) }
    }

    /// Plain log line; the category is worked out from the wording.
    func log(_ t: String) {
        guard enabled else { return }
        let k = EventKind.classify(t)
        if k == .rotation && t.lowercased().contains("trying") { s.rotationTries += 1 }
        event(k, t)
    }

    func learn(_ name: String) {
        var next = speakerSession
        next.record(name, enabled: enabled && ((UserDefaults.standard.object(forKey: "showSessionSpeakers") as? Bool) ?? true),
                    privateSession: UserDefaults.standard.bool(forKey: "privateSession"))
        if next.names != speakerSession.names { speakerSession = next }
    }

    func recordSourceLanguage(_ code: String, origin: SourceLanguageOrigin) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard enabled else { return }
        sourceUsage.record(code, origin: origin)
        s.sourceUsed = code
        s.sourceOrigin = origin.title
        if origin != .selected { s.detected = code } else { s.languageConfidence = 0; s.languageContextUsed = false }
    }

    func noteExecutionPhase(_ phase: String, pipActive: Bool) {
        guard enabled, executionPhase != phase else { return }
        executionPhase = phase
        event(.state, "App entered \(phase) (PiP \(pipActive ? "active" : "inactive"))")
    }

    func recordTranslate(ms: Double, sentences: Int, from: String, to: String, preview: String) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard detailedCollection else { return }
        add(\.translate, ms)
        event(.translation, "Translated \(sentences) sentence\(sentences == 1 ? "" : "s") \(from) → \(to) in \(Int(ms)) ms",
              detail: UserDefaults.standard.bool(forKey: "diagIncludeText") && !UserDefaults.standard.bool(forKey: "privateSession") ? String(preview.prefix(90)) : nil)
    }

    /// An actual selected caption can be entirely memory-served; never create
    /// a fictitious model-duration sample for those translations.
    func recordModeSelection(sentences: Int, source: String, target: String) {
        guard enabled else { return }
        event(.translation, "Translated \(sentences) sentence\(sentences == 1 ? "" : "s") \(source) → \(target)")
    }

    func recordLatency(ms: Double) { add(\.latency, ms) }

    /// 2.2.1 (D10): how long a persistent-memory lookup waited behind other work on the store actor.
    func noteMemoryLookupWait(_ ms: Double?) {
        guard enabled, let ms, ms.isFinite, ms >= 0 else { return }
        lookupWaitSamples.append(ms)
        if lookupWaitSamples.count > 600 { lookupWaitSamples.removeFirst(lookupWaitSamples.count - 600) }
    }

    /// 2.2.1 (D10): how long a memory health query ran on the store actor (it ends every save).
    func noteMemoryHealth(_ ms: Double?) {
        guard enabled, let ms, ms.isFinite, ms >= 0 else { return }
        memoryHealthSamples.append(ms)
        if memoryHealthSamples.count > 300 { memoryHealthSamples.removeFirst(memoryHealthSamples.count - 300) }
    }

    /// One Library write (E15). Bounded like the memory timings.
    func noteHistorySave(ms: Double) {
        guard enabled, ms.isFinite, ms >= 0 else { return }
        historySaveSamples.append(ms)
        if historySaveSamples.count > 600 { historySaveSamples.removeFirst(historySaveSamples.count - 600) }
    }

    func recordPipeline(_ stages: LatencyBreakdown) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard detailedCollection else { return }
        pipeline.append(PipelineMeasurement(date: Date(), stages: stages))
        let limit = max(300, min(1200, (UserDefaults.standard.object(forKey: "diagSamples") as? Int) ?? 600))
        if pipeline.count > limit { pipeline.removeFirst(pipeline.count - limit) }
    }
}
