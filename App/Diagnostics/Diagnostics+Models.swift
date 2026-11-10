import CryptoKit
import SwiftUI
import Charts
import os
import Darwin

struct Sample: Identifiable {
    let id = UUID()
    let t: Date
    let v: Double
}

enum EventKind: String, CaseIterable, Identifiable {
    case capture, pip, translation, language, rotation, preset, state, error, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .capture: "Capture"
        case .pip: "Window"
        case .translation: "Translation"
        case .language: "Language"
        case .rotation: "Rotation"
        case .preset: "Preset"
        case .state: "State"
        case .error: "Problem"
        case .system: "System"
        }
    }
    var icon: String {
        switch self {
        case .capture: "record.circle"
        case .pip: "rectangle.on.rectangle"
        case .translation: "character.bubble"
        case .language: "globe"
        case .rotation: "rotate.right"
        case .preset: "square.stack.3d.up"
        case .state: "circle.dotted"
        case .error: "exclamationmark.triangle.fill"
        case .system: "gearshape"
        }
    }
    var color: Color {
        switch self {
        case .capture: Color.green
        case .pip: Color.blue
        case .translation: Color.cyan
        case .language: Color.purple
        case .rotation: Color.orange
        case .preset: Color.pink
        case .state: Color.gray
        case .error: Color.red
        case .system: Color.secondary
        }
    }
    /// Sorts a plain log line into a category.
    static func classify(_ t: String) -> EventKind {
        let s = t.lowercased()
        if s.contains("failed") || s.contains("couldn't") || s.contains("error") || s.contains("stopped") { return .error }
        if s.contains("floating window") { return .pip }
        if s.contains("capture") { return .capture }
        if s.contains("rotation") || s.contains("reading order") { return .rotation }
        if s.contains("preset") || s.contains("profile") { return .preset }
        if s.contains("language") { return .language }
        if s.contains("translat") || s.contains("cleared") { return .translation }
        if s.contains("paused") || s.contains("now ") { return .state }
        return .system
    }
}

struct TimelineEvent: Identifiable {
    let id = UUID()
    let time: Date
    let kind: EventKind
    let text: String
    var detail: String? = nil
}

enum EngineState: String {
    case idle, live, paused, frozen
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .idle: Color.gray
        case .live: Color.green
        case .paused: Color.orange
        case .frozen: Color.blue
        }
    }
}

struct StateSpan: Identifiable {
    let id = UUID()
    let start: Date
    var end: Date?
    let state: EngineState
}

enum Fix: String {
    case fastSpeed, instantStability, immediateDisplay, fixedRotation, narrowArea, openLanguages, startCapture, translateAhead
    var label: String {
        switch self {
        case .fastSpeed: "Use Fast speed"
        case .instantStability: "Use Instant mode"
        case .immediateDisplay: "Show ready results immediately"
        case .fixedRotation: "Turn off auto-rotation"
        case .narrowArea: "Read the bottom third only"
        case .openLanguages: "Open Languages"
        case .startCapture: "Open Translate"
        case .translateAhead: "Turn on translate-ahead"
        }
    }
}

struct Issue: Identifiable {
    let id = UUID()
    let severity: Int          // 0 tip, 1 warning, 2 problem
    let title: String
    let detail: String
    let fix: Fix?
}

struct Assessment {
    var score: Int
    var headline: String
    var issues: [Issue]
}

struct Summary {
    var n = 0
    var min = 0.0
    var avg = 0.0
    var p50 = 0.0
    var p95 = 0.0
    var max = 0.0
    var last = 0.0
}

struct Stats: Equatable {
    var packets = 0, ocrPackets = 0, clearPackets = 0
    var frames = 0, passes = 0, skippedFrames = 0
    var fps = 0.0
    var bufferSize = "–", cropSize = "–", orientation = "–"
    var extFreeMB = 0.0, minExtFreeMB = 9999.0
    var linesIn = 0, dropArea = 0, dropSmall = 0, dropIgnore = 0, dropSelf = 0, dropTarget = 0, dropNoise = 0, dropLanguage = 0
    var blocksIn = 0, blocksKept = 0
    var sentences = 0, cacheHits = 0, specHits = 0, cacheMisses = 0, batches = 0, failures = 0, translations = 0, chars = 0
    var sessionKind = "–"
    var detected = "–"
    var sourceUsed = "–"
    var sourceOrigin = "–"
    var lockedLang = "–"
    var orderVote = 0.0
    var rotation = 0
    var calibrated = false
    var pipRegion = "–"
    var savedHits = 0
    var specModelRequests = 0
    var specStarted = 0, specCompleted = 0, specDiscarded = 0, specSkipped = 0
    var adaptiveSpeculationSkipped = 0, confirmedHandoffDeferred = 0
    var legacyAdaptiveLowYieldSkips = 0, legacyAdaptiveSavedSkips = 0
    var legacyLowConfidenceSkips = 0, legacyBusySpeculationSkips = 0
    var legacyDuplicateSpeculationSkips = 0
    var slowTailEnqueues = 0
    var manualTranslations = 0
    var identicalFrameHolds = 0 // 2.2.1 (E9)
    var warmupsDuringCapture = 0 // 2.2.1 (E18)
    var specPreemptionRequested = 0, specMatchingConfirmation = 0
    var specRetainedUnits = 0
    var legacyBatchEntries = 0, legacyBatchVerified = 0, legacyBatchSkipped = 0
    var legacyBatchPeakWorkers = 0, legacyBatchElapsedMs = 0.0
    var specProcessingMs = 0.0, specDiscardedMs = 0.0
    var languageContextUsed = false
    var languageConfidence = 0.0, ocrConfidence = 0.0
    var recognitionReason = "–", confirmationReason = "–"
    var unchangedSkipped = 0, cadenceSkipped = 0, pausedSkipped = 0, emptyReads = 0, retryCount = 0
    var captureDrops = 0
    var rotationTries = 0
    var confirmedCandidatePackets = 0, deferredEarlyCandidates = 0
    var supersededUnpresentedConfirmed = 0, enqueuedCandidateFrames = 0
    /// 2.3.0: of the confirmed captions replaced by a different confirmed caption before enqueue, how many already had
    /// translation work running and how many had not started it.
    var supersededConfirmedInFlight = 0, supersededConfirmedNotStarted = 0
    var movieSelections = 0, movieTemporalOverrides = 0, movieRejectedSmall = 0
    var queueReplacements = 0, visualChanges = 0, earlyVisualWakes = 0, earlyVisualWakesSuppressed = 0, emptyOCRPasses = 0
    var largePackets = 0, packetSendErrors = 0
    var pixelConfirmations = 0, pixelRejections = 0, watchSkippedOCR = 0, watchTriggeredOCR = 0
    var firstSightVisualChangeLagMs = 0.0
    var effectiveOCRIntervalMs = 0.0
}
