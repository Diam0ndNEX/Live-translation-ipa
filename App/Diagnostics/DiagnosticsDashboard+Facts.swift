import SwiftUI
import Charts

/// Slow-changing engine values (system, capture state, language pack).
struct DashboardFacts: Equatable {
    var system: TranslationSystem
    var pending: TranslationSystem
    var availability: String
    var captureAlive: Bool
    var paused: Bool
    var pipActive: Bool
    var memoryCount: Int
    var unconsumedSpeculation: String
    var sourceCode: String
    var sourceReady: Bool
    var extensionVersion: String
    var capture: CaptureReadiness.State
    var targetCode: String
    var manual: Bool
    @MainActor static func read(_ e: TranslatorEngine) -> DashboardFacts {
        DashboardFacts(system: e.activeTranslationSystem, pending: e.pendingTranslationSystem, availability: e.modeAvailability,
                       captureAlive: e.captureAlive, paused: e.paused, pipActive: e.pipActive, memoryCount: e.memoryCount,
                       unconsumedSpeculation: "\(e.unconsumedSpeculation)", sourceCode: e.sourceCode,
                       sourceReady: e.langStatus[e.sourceCode] == .installed, extensionVersion: e.extensionVersion,
                       capture: e.captureStatus, targetCode: e.targetCode, manual: e.manualMode)
    }
    var phase: SessionPhase {
        SessionPhase.derive(capture: capture, alive: captureAlive, paused: paused, pipActive: pipActive,
                            packReady: sourceCode == "auto" || sourceReady, manual: manual)
    }
}

/// Fast-changing engine values. Only the overview answer and the "Right now" section read it.
struct PulseFacts: Equatable {
    var ocrMs: Double
    var translateMs: Double
    var totalMs: Double
    var lastRaw: String
    var translated: String
    var activity: String
    var status: String
    @MainActor static func read(_ e: TranslatorEngine) -> PulseFacts {
        PulseFacts(ocrMs: e.ocrMs, translateMs: e.translateMs, totalMs: e.latency.last.total, lastRaw: e.lastRaw,
                   translated: e.translated, activity: e.translationActivity.title, status: e.status)
    }
}

struct SeriesMark: Equatable {
    var count: Int
    var last: Date?
    init(_ samples: [Sample]) { count = samples.count; last = samples.last?.t }
}

/// What changed in the recorder. Arrays are summarised by length and newest timestamp, so a full ring still registers.
struct DiagTick: Equatable {
    var stats: Stats
    var series: [SeriesMark]
    var events: Int
    var lastEvent: Date?
    var spans: Int
    var traces: Int
    var structured: Int
    var pipeline: Int
    var names: Int
    var memoryEntries: Int
    var pendingWrites: Int
    var archive: String
    var exporting: Bool
    var recording: Bool
    var runs: Int
    @MainActor static func read(_ d: Diagnostics) -> DiagTick {
        DiagTick(stats: d.s,
                 series: [d.ocr, d.translate, d.latency, d.transport, d.fps, d.lineCounts, d.extMem, d.appMem, d.thermal, d.battery, d.cacheRate].map(SeriesMark.init),
                 events: d.events.count, lastEvent: d.events.last?.time, spans: d.spans.count, traces: d.subtitleTraces.count,
                 structured: d.structuredEvents.count, pipeline: d.pipeline.count, names: d.names.count,
                 memoryEntries: d.memoryHealth.totalEntries, pendingWrites: d.memoryHealth.pendingWrites,
                 archive: d.archiveStatus, exporting: d.exportInProgress, recording: d.activeRun != nil, runs: d.testRuns.count)
    }
}
