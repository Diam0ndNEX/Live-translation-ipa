// Screen Translator – App – v0.11.0
import SwiftUI
import Charts
import os

// MARK: - Models
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
        case .startCapture: "Go to Home"
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

struct Stats {
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
    var specProcessingMs = 0.0, specDiscardedMs = 0.0
    var languageContextUsed = false
    var languageConfidence = 0.0, ocrConfidence = 0.0
    var recognitionReason = "–", confirmationReason = "–"
    var unchangedSkipped = 0, cadenceSkipped = 0, pausedSkipped = 0, emptyReads = 0, retryCount = 0
    var captureDrops = 0
    var rotationTries = 0
}

// MARK: - Recorder
@MainActor
final class Diagnostics: ObservableObject {
    @Published var s = Stats()
    @Published var ocr: [Sample] = []
    @Published var translate: [Sample] = []
    @Published var latency: [Sample] = []
    @Published var pipeline: [PipelineMeasurement] = []
    @Published var transport: [Sample] = []
    @Published var fps: [Sample] = []
    @Published var lineCounts: [Sample] = []
    @Published var extMem: [Sample] = []
    @Published var appMem: [Sample] = []
    @Published var thermal: [Sample] = []
    @Published var battery: [Sample] = []
    @Published var cacheRate: [Sample] = []
    @Published var events: [TimelineEvent] = []
    @Published var spans: [StateSpan] = []
    @Published private(set) var subtitleTraces: [SubtitleTrace] = []
    @Published var memoryHealth = MemoryDiagnosticHealth()
    @Published private(set) var structuredEvents: [StructuredDiagnosticEvent] = []
    @Published private(set) var archivedSessions: [DiagnosticSessionExport] = []
    @Published private(set) var archiveStatus = "Not saved"
    @Published private(set) var exportInProgress = false
    var memoryStore: TranslationMemoryStore?
    private let exportWriter = DiagnosticExportWriter()
    private var diagnosticSessionID = UUID()
    private var candidateIDs: [String: UUID] = [:]
    private var frameIDs: [Int: UUID] = [:]
    private var unitIDs: [String: UUID] = [:]
    private var memoryOutcomes: [MemoryDiagnosticOutcome: Int] = [:]
    private var lookupSamples: [Double] = []
    private var writeSamples: [Double] = []
    private var archiveInProgress = false
    private(set) var recorderCosts = RecorderCosts()
    private var recorderDepth = 0
    private struct CostToken { let start: Double; let outer: Bool; let detailed: Bool }
    private func beginRecorder() -> CostToken? {
        guard enabled else { return nil }
        recorderDepth += 1
        return CostToken(start: ProcessInfo.processInfo.systemUptime, outer: recorderDepth == 1, detailed: detailedCollection)
    }
    private func endRecorder(_ token: CostToken?) {
        guard let token else { return }
        recorderDepth -= 1
        if token.outer { recorderCosts.record(ms: (ProcessInfo.processInfo.systemUptime-token.start)*1000, detailed: token.detailed) }
    }
    private func stableCandidateID(_ candidate: String?) -> UUID? {
        guard let candidate else { return nil }
        if let existing = candidateIDs[candidate] { return existing }
        if candidateIDs.count >= 600 { candidateIDs.removeAll(keepingCapacity: true) }
        let id = UUID()
        candidateIDs[candidate] = id
        return id
    }

    private func stableFrameID(_ index: Int?) -> UUID? {
        guard let index else { return nil }
        if let id = frameIDs[index] { return id }
        if frameIDs.count >= 600 { frameIDs.removeAll(keepingCapacity: true) }
        let id = UUID(); frameIDs[index] = id
        return id
    }

    private func stableUnitID(_ canonicalKey: String?) -> UUID? {
        guard let canonicalKey else { return nil }
        if let id = unitIDs[canonicalKey] { return id }
        if unitIDs.count >= 600 { unitIDs.removeAll(keepingCapacity: true) }
        let id = UUID(); unitIDs[canonicalKey] = id
        return id
    }

    func trace(_ candidate: String?, stage: String, detail: String, at time: Date = Date(),
               frameIndex: Int? = nil) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard detailedCollection, let candidate else { return }
        // Never export a caller's identifier: historical candidates can encode input text.
        guard let safeID = stableCandidateID(candidate) else { return }
        let stages: Set<String> = ["first OCR", "seen", "confirmed", "processing", "speculating", "cache", "ready", "enqueued", "superseded", "memory", "cancelled"]
        let safeStage = stages.contains(stage) ? stage : "other"
        appendStructured(candidate: safeID, frameIndex: frameIndex, stage: safeStage,
                         outcome: "observed", reason: safeStage, durationMs: nil, at: time)
        subtitleTraces.append(SubtitleTrace(candidate: safeID.uuidString, stage: safeStage, time: time, detail: detail))
        if subtitleTraces.count > 300 { subtitleTraces.removeFirst(subtitleTraces.count - 300) }
    }


    /// Bounded, privacy-safe segmentation timing. Source text and cache keys are
    /// never stored in structured events; only opaque candidate IDs are emitted.
    func noteSegmentation(candidate: String?, reused: Bool, durationMs: Double) {
        let token = beginRecorder(); defer { endRecorder(token) }
        guard detailedCollection else { return }
        let outcome = reused ? "cache_hit" : "computed"
        appendStructured(candidate: stableCandidateID(candidate), stage: "segmentation",
                         outcome: outcome, reason: outcome, durationMs: durationMs)
    }

    private func appendStructured(candidate: UUID? = nil, frameIndex: Int? = nil,
                                  unitKey: String? = nil, stage: String, outcome: String,
                                  reason: String, durationMs: Double?, at time: Date = Date()) {
        structuredEvents.append(StructuredDiagnosticEvent(id: UUID(), timestamp: time,
            sessionID: diagnosticSessionID, candidateID: candidate,
            frameID: stableFrameID(frameIndex), unitID: stableUnitID(unitKey),
            stage: stage, outcome: outcome, reasonCode: reason,
            durationMs: durationMs.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, privacy: "metadataOnly"))
        if structuredEvents.count > 600 { structuredEvents.removeFirst(structuredEvents.count - 600) }
    }

    /// Counts one lookup outcome per unit; persistence and eviction counters have separate denominators.
    func recordMemory(_ outcome: MemoryDiagnosticOutcome, durationMs: Double = 0,
                      candidate: String? = nil, frameIndex: Int? = nil, unitKey: String? = nil,
                      count: Int = 1) {
        let token = beginRecorder(); defer { endRecorder(token) }
        guard enabled, count > 0 else { return }
        memoryOutcomes[outcome, default: 0] += count
        let finite = durationMs.isFinite && durationMs >= 0
        switch outcome {
        case .ramHit, .persistentHit, .legacyHit, .speculativeHit, .miss, .timeout, .compatibilityRejected, .databaseUnavailable:
            if finite { lookupSamples.append(durationMs) }
            if lookupSamples.count > 600 { lookupSamples.removeFirst(lookupSamples.count - 600) }
        case .persisted, .writeFailed:
            if finite { writeSamples.append(durationMs) }
            if writeSamples.count > 600 { writeSamples.removeFirst(writeSamples.count - 600) }
        default: break
        }
        // Preserve errors in basic mode; detailed events are pressure-aware.
        if detailedCollection || outcome == .writeFailed || outcome == .timeout || outcome == .databaseUnavailable {
            let safeID = detailedCollection ? stableCandidateID(candidate) : nil
            appendStructured(candidate: safeID, frameIndex: frameIndex, unitKey: unitKey,
                             stage: "memory", outcome: outcome.rawValue,
                             reason: outcome.rawValue, durationMs: durationMs)
        }
    }

    func memoryOutcomesForUI(_ outcome: MemoryDiagnosticOutcome) -> Int { memoryOutcomes[outcome, default: 0] }

    func sessionSnapshot() -> DiagnosticSessionExport {
        // Explicit allowlist excludes glossary, protected names, source fixes, user text and paths.
        let keys = ["mode", "speed", "stability", "frameRot", "area", "adaptiveOCR", "remember", "privateSession", "diagnosticsEnabled", "detailedCollection"]
        var settings: [String: String] = [:]
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { settings[key] = String(describing: value) }
        }
        var counters = Dictionary(uniqueKeysWithValues: memoryOutcomes.map { ($0.key.rawValue, $0.value) })
        counters["sessionCacheHits"] = s.cacheHits
        counters["savedMemoryHits"] = s.savedHits
        counters["speculativeHits"] = s.specHits
        counters["lookupMisses"] = s.cacheMisses
        counters["speculativeModelRequests"] = s.specModelRequests
        counters["supersededSpeculativePipelines"] = s.specDiscarded
        return DiagnosticSessionExport(id: diagnosticSessionID, startedAt: started, endedAt: Date(),
            appVersion: AppVersion.full, systemVersion: UIDevice.current.systemVersion,
            settings: settings, health: memoryHealth, counters: counters,
            distributions: ["memoryLookupMs": DiagnosticDistribution(lookupSamples), "memoryWriteMs": DiagnosticDistribution(writeSamples),
                "ocrMs": DiagnosticDistribution(ocr.map { $0.v }), "translationMs": DiagnosticDistribution(translate.map { $0.v }),
                "enqueueLatencyMs": DiagnosticDistribution(latency.map { $0.v })],
            events: structuredEvents,
            measurementBoundary: "First OCR sighting to PiP sample-buffer enqueue; physical display unmeasured. Distributions use the latest bounded samples within this session, not all-time aggregates. Stages can overlap.",
            textCapture: false)
    }

    func exportJSON() async {
        guard !exportInProgress else { return }
        exportInProgress = true
        defer { exportInProgress = false }
        let snapshot = sessionSnapshot()
        do {
            let url = try await exportWriter.export(snapshot)
            Sharer.present([url])
            archiveStatus = "JSON export ready"
        } catch { archiveStatus = "Export failed; no file was shared" }
    }

    func persistSession() {
        guard enabled, UserDefaults.standard.bool(forKey: "persistDiagnosticSessions"),
              !UserDefaults.standard.bool(forKey: "privateSession"), !archiveInProgress,
              let store = memoryStore else { return }
        archiveInProgress = true
        let snapshot = sessionSnapshot()
        Task {
            defer { archiveInProgress = false }
            do {
                let data = try await exportWriter.encode(snapshot)
                // Check privacy again after encoding, before submitting a durable write.
                guard UserDefaults.standard.bool(forKey: "persistDiagnosticSessions"),
                      !UserDefaults.standard.bool(forKey: "privateSession") else { return }
                try await store.saveDiagnosticSession(id: snapshot.id.uuidString, startedAt: snapshot.startedAt,
                    endedAt: snapshot.endedAt, payload: data)
                archiveStatus = "Session saved"
            } catch { archiveStatus = "Session could not be saved" }
        }
    }

    func loadSessions() async {
        guard let store = memoryStore else { archiveStatus = "Memory database unavailable"; return }
        do {
            let records = try await store.loadDiagnosticSessions()
            var decoded: [DiagnosticSessionExport] = []
            for record in records { decoded.append(try await exportWriter.decode(record)) }
            archivedSessions = decoded.sorted { $0.endedAt > $1.endedAt }
            archiveStatus = "Loaded \(decoded.count) sessions"
        } catch { archiveStatus = "Sessions could not be loaded" }
    }

    func deleteSessions() async {
        guard let store = memoryStore else { archiveStatus = "Memory database unavailable"; return }
        // Stop automatic re-creation; only diagnostics are removed.
        UserDefaults.standard.set(false, forKey: "persistDiagnosticSessions")
        do {
            try await store.clearDiagnosticSessions()
            archivedSessions = []; archiveStatus = "Saved sessions deleted"
        } catch { archiveStatus = "Saved sessions could not be deleted" }
    }

    @Published var sourceUsage = SourceLanguageUsage()
    @Published private(set) var executionPhase = "starting"
    private var lastPacketAt: Date?
    private var lastDeviceSampleAt: Date?
    @Published private var speakerSession = SpeakerSession()
    var names: [String] {
        guard enabled, !UserDefaults.standard.bool(forKey: "privateSession"),
              (UserDefaults.standard.object(forKey: "showSessionSpeakers") as? Bool) ?? true else { return [] }
        return speakerSession.names
    }
    var enabled: Bool { (UserDefaults.standard.object(forKey: "diagnosticsEnabled") as? Bool) ?? true }
    var detailedCollection: Bool {
        guard ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return false }
        return RuntimePolicy(coolMode: false, diagnosticsEnabled: enabled,
                      detailedRequested: UserDefaults.standard.bool(forKey: "detailedCollection")).detailedDiagnostics
    }

    func collectionChanged() {
        // A new collection interval must never be mistaken for continuous history.
        let costs = recorderCosts
        reset()
        recorderCosts = costs
        UIDevice.current.isBatteryMonitoringEnabled = detailedCollection
    }

    func clearSpeakers() { speakerSession = SpeakerSession() }
    @Published private(set) var started = Date()
    private var lastFrames = 0
    private var lastFrameTime = Date()
    private var tickN = 0
    private var lastState: EngineState?

    init() { UIDevice.current.isBatteryMonitoringEnabled = detailedCollection }

    private func add(_ kp: ReferenceWritableKeyPath<Diagnostics, [Sample]>, _ v: Double, cap: Int = 600) {
        guard detailedCollection else { return }
        self[keyPath: kp].append(Sample(t: Date(), v: v))
        let limit = max(300, min(1200, (UserDefaults.standard.object(forKey: "diagSamples") as? Int) ?? 600))
        let extra = self[keyPath: kp].count - limit
        if extra > 0 { self[keyPath: kp].removeFirst(extra) }
    }

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

    func recordLatency(ms: Double) { add(\.latency, ms) }

    func recordPipeline(_ stages: LatencyBreakdown) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard detailedCollection else { return }
        pipeline.append(PipelineMeasurement(date: Date(), stages: stages))
        let limit = max(300, min(1200, (UserDefaults.standard.object(forKey: "diagSamples") as? Int) ?? 600))
        if pipeline.count > limit { pipeline.removeFirst(pipeline.count - limit) }
    }

    func reset() {
        persistSession()
        diagnosticSessionID = UUID(); candidateIDs = [:]; frameIDs = [:]; unitIDs = [:]; structuredEvents = []
        memoryOutcomes = [:]; lookupSamples = []; writeSamples = []
        started = Date()
        subtitleTraces = []; recorderCosts = RecorderCosts()
        lastFrames = 0; lastFrameTime = Date(); tickN = 0
        lastPacketAt = nil; lastDeviceSampleAt = nil
        s = Stats()
        pipeline = []
        ocr = []; translate = []; latency = []; transport = []; fps = []; lineCounts = []
        extMem = []; appMem = []; thermal = []; battery = []; cacheRate = []
        events = []; spans = []; sourceUsage = SourceLanguageUsage(); clearSpeakers()
        lastState = nil
    }

    // MARK: Packets from the extension
    func onPacket(_ p: Packet, transport t: Double?) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard enabled else { return }
        lastPacketAt = Date()
        s.recognitionReason = p.recognitionReason ?? "legacy"
        s.confirmationReason = p.confirmationReason ?? "legacy"
        if !p.lines.isEmpty { s.ocrConfidence = p.lines.map { $0.confidence ?? 0 }.min() ?? 0 }
        s.unchangedSkipped = p.unchangedSkipped ?? s.unchangedSkipped
        s.cadenceSkipped = p.cadenceSkipped ?? s.cadenceSkipped
        s.pausedSkipped = p.pausedSkipped ?? s.pausedSkipped
        s.emptyReads = p.emptyReads ?? s.emptyReads
        s.retryCount = p.retryCount ?? s.retryCount
        s.packets += 1
        if p.kind == "ocr" {
            s.ocrPackets += 1
            add(\.lineCounts, Double(p.lines.count))
        } else if p.kind == "clear" {
            s.clearPackets += 1
        }
        let now = Date()
        let dt = now.timeIntervalSince(lastFrameTime)
        if p.frames < lastFrames {
            lastFrames = p.frames; lastFrameTime = now
        } else if dt >= 1 {
            s.fps = Double(p.frames - lastFrames) / dt
            add(\.fps, s.fps)
            lastFrames = p.frames; lastFrameTime = now
        }
        s.frames = p.frames
        if let m = p.memFreeMB { s.extFreeMB = m; if m > 0 { s.minExtFreeMB = Swift.min(s.minExtFreeMB, m) } }
        if let o = p.ocrMs, o > 0, p.kind != "ping" { add(\.ocr, o) }
        if let v = p.passes { s.passes = v }
        if let v = p.skipped { s.skippedFrames = v }
        if let w = p.bufW, let h = p.bufH { s.bufferSize = "\(w)×\(h)" }
        if let w = p.cropW, let h = p.cropH { s.cropSize = "\(w)×\(h)" }
        if let o = p.orient { s.orientation = Diagnostics.orientationName(o) }
        if let t, p.kind != "ping" { add(\.transport, t) }
    }

    // MARK: Once a second
    func tick(alive: Bool, paused: Bool, frozen: Bool) {
        let recorderToken = beginRecorder(); defer { endRecorder(recorderToken) }
        guard enabled else { return }
        tickN += 1
        if tickN % 30 == 0 { persistSession() }
        let st: EngineState = !alive ? .idle : (paused ? .paused : (frozen ? .frozen : .live))
        if st != lastState {
            if let i = spans.indices.last { spans[i].end = Date() }
            if detailedCollection { spans.append(StateSpan(start: Date(), end: nil, state: st)) }
            if spans.count > 300 { spans.removeFirst() }
            if let prev = lastState, prev != .idle, st == .idle { s.captureDrops += 1 }
            event(.state, "Now \(st.title)")
            lastState = st
        }
        if detailedCollection && tickN % 2 == 0 { sampleDevice(alive: alive) }
    }

    private func sampleDevice(alive: Bool) {
        lastDeviceSampleAt = Date()
        let level: Double
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: level = 0
        case .fair: level = 1
        case .serious: level = 2
        case .critical: level = 3
        @unknown default: level = 0
        }
        add(\.thermal, level, cap: 900)
        add(\.appMem, Double(os_proc_available_memory()) / 1_048_576, cap: 900)
        let b = Double(UIDevice.current.batteryLevel)
        if b >= 0 { add(\.battery, b * 100, cap: 900) }
        if alive, s.extFreeMB > 0 { add(\.extMem, s.extFreeMB, cap: 900) }
        let total = s.cacheHits + s.savedHits + s.specHits + s.cacheMisses
        if total > 0 { add(\.cacheRate, Double(s.cacheHits + s.savedHits + s.specHits) / Double(total) * 100, cap: 900) }
    }

    // MARK: Maths
    nonisolated static func summarize(_ a: [Sample]) -> Summary {
        guard !a.isEmpty else { return Summary() }
        let v = a.map { $0.v }.sorted()
        func pct(_ p: Double) -> Double { v[Swift.min(v.count - 1, Int(Double(v.count - 1) * p))] }
        return Summary(n: v.count, min: v.first ?? 0, avg: v.reduce(0, +) / Double(v.count),
                       p50: pct(0.5), p95: pct(0.95), max: v.last ?? 0, last: a.last?.v ?? 0)
    }

    nonisolated static func orientationName(_ v: Int) -> String {
        let n = ["up", "up mirrored", "down", "down mirrored", "left mirrored", "right", "right mirrored", "left"]
        return (1...8).contains(v) ? "\(n[v - 1]) (\(v))" : "\(v)"
    }

    // MARK: Health + advice
    func assessment(alive: Bool, paused: Bool) -> Assessment {
        var issues: [Issue] = []
        var score = 100
        func flag(_ sev: Int, _ title: String, _ detail: String, _ fix: Fix? = nil) {
            issues.append(Issue(severity: sev, title: title, detail: detail, fix: fix))
        }
        let ocrS = Diagnostics.summarize(Array(ocr.suffix(30)))
        let latS = Diagnostics.summarize(Array(latency.suffix(30)))
        let trS = Diagnostics.summarize(Array(translate.suffix(30)))

        if !alive {
            flag(2, "Capture isn't running", "Open Home, tap the broadcast button and choose Translator Capture.", .startCapture)
            score -= 45
        } else {
            if paused { flag(0, "Translating is paused", "Turn Pause off on the Home screen to continue."); score -= 5 }
            if ocrS.n >= 3 {
                if ocrS.avg > 500 {
                    flag(2, "Reading the screen is slow (\(Int(ocrS.avg)) ms)", "A smaller area or the Fast speed makes it quicker.", .fastSpeed); score -= 20
                } else if ocrS.avg > 300 {
                    flag(1, "Reading is a little slow (\(Int(ocrS.avg)) ms)", "Try the Fast speed or a smaller OCR area.", .fastSpeed); score -= 10
                }
            }
            if latS.n >= 3 {
                if latS.avg > 2000 {
                    flag(2, "Translations show up late (\(Int(latS.avg)) ms)", "Check measured queue and readability hold time. Immediate display keeps confirmation enabled.", .immediateDisplay); score -= 20
                } else if latS.avg > 1200 {
                    flag(1, "Slightly delayed translations (\(Int(latS.avg)) ms)", "Immediate display removes optional readability holds without changing translation quality.", .immediateDisplay); score -= 10
                }
            }
            if s.fps > 0 && s.fps < 15 {
                flag(1, "Low frame rate (\(Int(s.fps)) fps)", "The phone may be busy or warm."); score -= 8
            }
        }
        if s.minExtFreeMB < 12 {
            flag(2, "The capture extension nearly ran out of memory (\(Int(s.minExtFreeMB)) MB left)", "iOS may close it. Use the Fast speed or a smaller OCR area.", .fastSpeed); score -= 20
        } else if s.minExtFreeMB < 20 {
            flag(1, "Memory is getting tight (\(Int(s.minExtFreeMB)) MB left)", "The Fast speed uses less memory.", .fastSpeed); score -= 8
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            flag(2, "The phone is hot", "Reading slows down automatically. Let it cool down, or lower the brightness."); score -= 15
        default: break
        }
        if alive, trS.n >= 3, trS.avg > 400,
           (UserDefaults.standard.object(forKey: "translateAhead") as? Bool) == false {
            flag(1, "Translating is a big part of the delay (\(Int(trS.avg)) ms)",
                 "Translate-ahead starts translating before the text is confirmed, so the waits overlap.", .translateAhead)
            score -= 8
        }
        if s.sessionKind.contains("Hosted") {
            flag(0, "Translations use the slower engine",
                 "The faster direct engine needs iOS 26 and both language packs downloaded.", .openLanguages)
        }
        if s.translations + s.failures > 0, Double(s.failures) / Double(s.translations + s.failures) > 0.05 {
            flag(1, "Some sentences failed to translate", "Make sure the language packs are downloaded.", .openLanguages); score -= 10
        }
        if s.rotationTries >= 3 {
            flag(1, "Sentence order keeps being re-detected", "Pick a fixed frame rotation in Settings → Reading & OCR.", .fixedRotation); score -= 8
        }
        if s.captureDrops >= 2 {
            flag(1, "Capture stopped \(s.captureDrops) times", "iOS closed the extension. The Fast speed is easier on memory.", .fastSpeed); score -= 8
        }
        score = Swift.max(0, Swift.min(100, score))
        let headline = !alive ? "Not running" : (score >= 85 ? "Running smoothly" : (score >= 60 ? "Working, could be better" : "Needs attention"))
        issues.sort { $0.severity > $1.severity }
        return Assessment(score: score, headline: headline, issues: issues)
    }

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
        l.append("Speculative model requests \(s.specModelRequests); pipeline attempts \(s.specStarted), completed \(s.specCompleted), superseded/cancelled \(s.specDiscarded), declined \(s.specSkipped), unconsumed results \(engine.unconsumedSpeculation); processing \(Int(s.specProcessingMs)) ms, discarded work \(Int(s.specDiscardedMs)) ms. Attempts count pipeline jobs; cache hits count sentences.")
        l.append("OCR confidence \(Int(s.ocrConfidence*100))%, source evidence \(s.sourceOrigin == "Selected" ? "manual selection" : "\(Int(s.languageConfidence*100))%"); recognition: \(s.recognitionReason); confirmation: \(s.confirmationReason).")
        l.append("Frame skips: unchanged \(s.unchangedSkipped), cadence \(s.cadenceSkipped), paused \(s.pausedSkipped); consecutive empty reads \(s.emptyReads), contrast retries \(s.retryCount).")
        l.append("Instrumented recorder elapsed self-time, app lifetime: simple \(String(format: "%.2f", recorderCosts.simpleMs)) ms / \(recorderCosts.simpleCalls) calls; detailed \(String(format: "%.2f", recorderCosts.detailedMs)) ms / \(recorderCosts.detailedCalls) calls. Excludes async chart drawing, translation and OCR; workloads may differ.")
        l.append("Source language inputs: " + sourceUsage.counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        l.append("Source choice modes: " + SourceLanguageOrigin.allCases.map { "\($0.title)=\(sourceUsage.origins[$0, default: 0])" }.joined(separator: ", "))
        l.append("Execution phase \(executionPhase), PiP \(engine.pipActive ? "active" : "inactive"); last packet \(lastPacketAt?.ISO8601Format() ?? "none"), last device sample \(lastDeviceSampleAt?.ISO8601Format() ?? "none").")
        l.append("Settings: mode=\(UserDefaults.standard.string(forKey: "mode") ?? "movie"), area=\(UserDefaults.standard.string(forKey: "area") ?? "smart"), speed=\(UserDefaults.standard.string(forKey: "speed") ?? "balanced"), configured rotation=\(UserDefaults.standard.string(forKey: "frameRot") ?? "auto"), confirmation reads=\((UserDefaults.standard.object(forKey: "stability") as? Int) ?? 2)")
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

// MARK: - Small helpers
private func fmt(_ v: Double) -> String { v >= 100 ? "\(Int(v))" : String(format: "%.1f", v) }

private func level(_ v: Double, _ n: Int, _ warn: Double, _ bad: Double) -> Color {
    n == 0 ? Color.white : (v > bad ? Color.red : (v > warn ? Color.orange : Color.green))
}

private struct BarRow: Identifiable {
    let name: String
    let value: Int
    var id: String { name }
}

private struct DonutPart: Identifiable {
    let name: String
    let value: Int
    let color: Color
    var id: String { name }
}

private struct Bucket: Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
}

// MARK: - Building blocks
private struct StatTile: View {
    let title: String
    let value: String
    var tint: Color = Color.white
    var icon: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.caption2).foregroundStyle(tint) }
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct HealthRing: View {
    let score: Int
    private var color: Color { score >= 85 ? Color.green : (score >= 60 ? Color.orange : Color.red) }
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 10)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)").font(.title.weight(.bold).monospacedDigit())
                Text("health").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 96)
    }
}

private struct LineCard: View {
    let title: String
    let samples: [Sample]
    var color: Color = Color.cyan
    var unit = "ms"
    var rule: Double? = nil
    var markers: [TimelineEvent] = []

    private func stat(_ n: String, _ v: Double) -> some View {
        VStack(spacing: 1) {
            Text(fmt(v)).font(.caption.weight(.semibold).monospacedDigit())
            Text(n).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        let sm = Diagnostics.summarize(samples)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if sm.n > 0 {
                    Text("\(fmt(sm.last)) \(unit)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(color)
                }
            }
            if samples.count < 2 {
                Text("Collecting data…").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                Chart {
                    ForEach(samples) { s in
                        AreaMark(x: .value("Time", s.t), y: .value(unit, s.v))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", s.t), y: .value(unit, s.v))
                            .foregroundStyle(color)
                            .interpolationMethod(.monotone)
                    }
                    if let r = rule {
                        RuleMark(y: .value("Limit", r))
                            .foregroundStyle(Color.red.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    ForEach(markers) { e in
                        RuleMark(x: .value("Event", e.time))
                            .foregroundStyle(e.kind.color.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.minute().second())
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 110)
                HStack {
                    stat("min", sm.min)
                    Spacer()
                    stat("avg", sm.avg)
                    Spacer()
                    stat("p95", sm.p95)
                    Spacer()
                    stat("max", sm.max)
                }
            }
        }
        .card()
    }
}

private struct HistogramCard: View {
    let title: String
    let values: [Double]
    var color: Color = Color.cyan

    private struct Bin: Identifiable {
        let label: String
        let count: Int
        let order: Int
        var id: Int { order }
    }

    private var bins: [Bin] {
        guard values.count >= 3, let mx = values.max(), mx > 0 else { return [] }
        let n = 8
        let w = mx / Double(n)
        var counts = [Int](repeating: 0, count: n)
        for v in values { counts[Swift.min(n - 1, Int(v / w))] += 1 }
        return (0..<n).map { Bin(label: "\(Int(Double($0) * w))", count: counts[$0], order: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if bins.isEmpty {
                Text("Collecting data…").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                Chart(bins) { b in
                    BarMark(x: .value("Range (ms)", b.label), y: .value("Count", b.count))
                        .foregroundStyle(color.gradient)
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 120)
            }
        }
        .card()
    }
}

private struct DonutCard: View {
    let title: String
    let parts: [DonutPart]
    var body: some View {
        let shown = parts.filter { $0.value > 0 }
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if shown.isEmpty {
                Text("No data yet.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart(shown) { p in
                    SectorMark(angle: .value("Count", p.value), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(by: .value("Part", p.name))
                }
                .chartForegroundStyleScale(domain: shown.map { $0.name }, range: shown.map { $0.color })
                .chartLegend(position: .bottom, alignment: .center, spacing: 8)
                .frame(height: 210)
            }
        }
        .card()
    }
}

private struct BarListCard: View {
    let title: String
    let rows: [BarRow]
    var color: Color = Color.blue
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if rows.allSatisfy({ $0.value == 0 }) {
                Text("No data yet.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Chart(rows) { r in
                    BarMark(x: .value("Count", r.value), y: .value("Item", r.name))
                        .foregroundStyle(color.gradient)
                        .annotation(position: .trailing) {
                            Text("\(r.value)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                }
                .chartYScale(domain: rows.map { $0.name })
                .frame(height: CGFloat(rows.count) * 34 + 20)
            }
        }
        .card()
    }
}

private struct MultiSpeedChart: View {
    let ocr: [Sample]
    let translate: [Sample]
    let delay: [Sample]
    var body: some View {
        if ocr.count + translate.count + delay.count < 3 {
            Text("Collecting data…").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            Chart {
                ForEach(ocr) { s in
                    LineMark(x: .value("Time", s.t), y: .value("ms", s.v), series: .value("Step", "Reading"))
                        .foregroundStyle(by: .value("Step", "Reading"))
                        .interpolationMethod(.monotone)
                }
                ForEach(translate) { s in
                    LineMark(x: .value("Time", s.t), y: .value("ms", s.v), series: .value("Step", "Translating"))
                        .foregroundStyle(by: .value("Step", "Translating"))
                        .interpolationMethod(.monotone)
                }
                ForEach(delay) { s in
                    LineMark(x: .value("Time", s.t), y: .value("ms", s.v), series: .value("Step", "Total delay"))
                        .foregroundStyle(by: .value("Step", "Total delay"))
                        .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["Reading": Color.green, "Translating": Color.cyan, "Total delay": Color.orange])
            .chartLegend(position: .bottom)
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.minute().second())
                }
            }
            .frame(height: 160)
        }
    }
}

// MARK: - Pages
enum DiagPage: String, CaseIterable, Identifiable {
    case overview, speed, timeline, pipeline, language, device, memory, sessions, log
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .speed: "speedometer"
        case .timeline: "timeline.selection"
        case .pipeline: "arrow.triangle.branch"
        case .language: "globe"
        case .device: "iphone"
        case .memory: "internaldrive"
        case .sessions: "clock.arrow.circlepath"
        case .log: "list.bullet.rectangle"
        }
    }
}

enum DiagRange: Int, CaseIterable, Identifiable {
    case oneMin = 60, fiveMin = 300, fifteenMin = 900, session = 0
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .oneMin: "1 min"
        case .fiveMin: "5 min"
        case .fifteenMin: "15 min"
        case .session: "Session"
        }
    }
}

// MARK: - Screen
struct DiagnosticsView: View {
    @EnvironmentObject var engine: TranslatorEngine
    var body: some View { DiagnosticsBody(diag: engine.diag) }
}

private struct DiagnosticsBody: View {
    @EnvironmentObject var engine: TranslatorEngine
    @Environment(\.selectTab) private var selectTab
    @ObservedObject var diag: Diagnostics
    @AppStorage("diagDetailed") private var detailed = false
    @AppStorage("diagnosticsEnabled") private var collectionEnabled = true
    @AppStorage("detailedCollection") private var collectDetails = false
    @AppStorage("diagPage") private var pageRaw = DiagPage.overview.rawValue
    @AppStorage("diagRange") private var rangeRaw = DiagRange.fiveMin.rawValue
    @State private var visible = false
    @State private var kinds: Set<EventKind> = []
    @State private var query = ""
    @State private var confirmReset = false
    @State private var showSimulator = false
    @State private var confirmDeleteSessions = false
    @AppStorage("persistDiagnosticSessions") private var persistSessions = false

    private var page: DiagPage { DiagPage(rawValue: pageRaw) ?? .overview }
    private var range: DiagRange { DiagRange(rawValue: rangeRaw) ?? .fiveMin }
    private var rangeStart: Date {
        range == .session ? diag.started : Date().addingTimeInterval(-Double(range.rawValue))
    }
    private func slice(_ a: [Sample]) -> [Sample] { a.filter { $0.t >= rangeStart } }

    private func elapsed(_ d: Date) -> String {
        let s = Int(d.timeIntervalSince(diag.started))
        return String(format: "+%d:%02d", s / 60, s % 60)
    }

    // MARK: Body
    var body: some View {
        NavigationStack {
            ScrollView {
                if visible {
                    VStack(spacing: 14) {
                        if collectionEnabled {
                        if detailed { detailedBody } else { simpleBody }
                        if detailed && !collectDetails {
                            Text("Graphs and events are off. Language counters and session speaker labels still work. Enable Detailed diagnostics in the toolbar settings menu to collect graph samples.").font(.footnote).foregroundStyle(.secondary)
                        }
                        } else {
                            Text("Diagnostics collection is off. Translation and capture continue.").foregroundStyle(.secondary).card()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Sharer.shareFile(text: diag.report(engine: engine), name: "translator-report-\(Sharer.stamp()).txt") } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share report")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showSimulator = true } label: { Label("Pipeline simulator", systemImage: "point.3.connected.trianglepath.dotted") }
                        Section("View") {
                            Picker("Diagnostic view", selection: $detailed) {
                                Text("Simple").tag(false)
                                Text("Detailed").tag(true)
                            }
                        }
                        Section("Collection") {
                            Toggle("Save diagnostic sessions on this device", isOn: $persistSessions)
                            Toggle("Simple diagnostics", isOn: $collectionEnabled)
                            Toggle("Detailed diagnostics", isOn: $collectDetails).disabled(!collectionEnabled)
                        }
                    } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Diagnostic settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { Task { await diag.exportJSON() } } label: {
                            Label(diag.exportInProgress ? "Preparing JSON…" : "Export structured JSON", systemImage: "curlybraces")
                        }.disabled(diag.exportInProgress)
                        Button { Sharer.shareFile(text: diag.csv(), name: "translator-data-\(Sharer.stamp()).csv") } label: {
                            Label("Export data (CSV)", systemImage: "tablecells")
                        }
                        Button {
                            UIPasteboard.general.string = diag.report(engine: engine)
                            engine.toast("Report copied")
                        } label: { Label("Copy report", systemImage: "doc.on.doc") }
                        Button(role: .destructive) { confirmReset = true } label: {
                            Label("Reset diagnostics", systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showSimulator) { NavigationStack { PipelineSimulatorView().environmentObject(engine) } }
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .confirmationDialog("Delete saved diagnostic sessions? Translation memory and history are preserved.", isPresented: $confirmDeleteSessions, titleVisibility: .visible) {
                Button("Delete saved sessions", role: .destructive) { Task { await diag.deleteSessions() } }
            }
            .confirmationDialog("Clear all graphs, counters and the timeline?", isPresented: $confirmReset,
                                titleVisibility: .visible) {
                Button("Reset diagnostics", role: .destructive) { diag.reset(); engine.toast("Diagnostics reset") }
            }
        }
    }

    // MARK: Simple
    private var simpleBody: some View {
        let a = diag.assessment(alive: engine.captureAlive, paused: engine.paused)
        let cutoff = Date().addingTimeInterval(-120)
        return VStack(spacing: 14) {
            healthCard(a)
            adaptivePipelineCard
            if !a.issues.isEmpty { suggestions(a.issues, limit: 3) }
            liveFeed
            if collectDetails {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speed, last 2 minutes").font(.subheadline.weight(.semibold))
                MultiSpeedChart(ocr: diag.ocr.filter { $0.t > cutoff },
                                translate: diag.translate.filter { $0.t > cutoff },
                                delay: diag.latency.filter { $0.t > cutoff })
            }
            .card()
            recentEvents
            }
            if !collectDetails {
                Text("Summary collection is active. Timing history and events are off.").font(.footnote).foregroundStyle(.secondary).card()
            }
        }
    }

    private var statusLine: String {
        engine.captureAlive
            ? "Capture connected · \(diag.s.translations) translation\(diag.s.translations == 1 ? "" : "s") this session"
            : "Waiting for capture to start"
    }

    private func healthCard(_ a: Assessment) -> some View {
        let o = Diagnostics.summarize(Array(diag.ocr.suffix(30)))
        let t = Diagnostics.summarize(Array(diag.translate.suffix(30)))
        let d = Diagnostics.summarize(Array(diag.latency.suffix(30)))
        let read = collectDetails ? o.avg : engine.ocrMs
        let processing = collectDetails ? t.avg : engine.translateMs
        let delay = collectDetails ? d.avg : engine.latency.last.total
        return VStack(spacing: 14) {
            HStack(spacing: 16) {
                if collectDetails { HealthRing(score: a.score) }
                else { Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(Theme.accent.start) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(collectDetails ? a.headline : "Summary only").font(.title3.weight(.bold))
                    Text(statusLine).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if !collectDetails { Text("Latest pipeline values · no timing history").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 10) {
                StatTile(title: "Reads in", value: read > 0 ? "\(Int(read)) ms" : "–",
                         tint: level(o.avg, o.n, 300, 500), icon: "text.viewfinder")
                StatTile(title: "Translates in", value: processing > 0 ? "\(Int(processing)) ms" : "–",
                         tint: level(t.avg, t.n, 400, 800), icon: "character.bubble")
                StatTile(title: "Total delay", value: delay > 0 ? "\(Int(delay)) ms" : "–",
                         tint: level(d.avg, d.n, 1200, 2000), icon: "timer")
            }
        }
        .card()
    }

    private func apply(_ f: Fix) {
        let ud = UserDefaults.standard
        switch f {
        case .fastSpeed: ud.set("fast", forKey: "speed")
        case .instantStability: ud.set(1, forKey: "stability")
        case .immediateDisplay: ud.set("immediate", forKey: "displayPolicy"); engine.timingSettingsChanged()
        case .fixedRotation:
            ud.set("0", forKey: "frameRot")
            engine.rotationSettingChanged()
        case .narrowArea: ud.set("bottom", forKey: "area")
        case .openLanguages: selectTab(1); return
        case .startCapture: selectTab(0); return
        case .translateAhead: ud.set(true, forKey: "translateAhead")
        }
        engine.syncConfig()
        engine.tap()
        engine.toast("Applied: \(f.label)")
    }

    private func suggestions(_ issues: [Issue], limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What to look at").font(.subheadline.weight(.semibold))
            ForEach(Array(issues.prefix(limit))) { i in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: i.severity == 2 ? "exclamationmark.octagon.fill"
                          : (i.severity == 1 ? "exclamationmark.triangle.fill" : "lightbulb.fill"))
                        .foregroundStyle(i.severity == 2 ? Color.red : (i.severity == 1 ? Color.orange : Color.yellow))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(i.title).font(.footnote.weight(.semibold))
                        Text(i.detail).font(.caption).foregroundStyle(.secondary)
                        if let f = i.fix {
                            Button(f.label) { apply(f) }
                                .font(.caption.weight(.bold))
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .card()
    }

    private func feedRow(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(Theme.accent.start)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(text).font(.footnote).lineLimit(3)
            }
        }
    }

    private var liveFeed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Right now").font(.subheadline.weight(.semibold))
            feedRow("text.viewfinder", "Reads", engine.lastRaw.isEmpty ? "Nothing yet" : engine.lastRaw)
            feedRow("character.bubble", "Shows", engine.translated.isEmpty ? "Nothing yet" : engine.translated)
            Text(engine.status).font(.caption2).foregroundStyle(.secondary)
        }
        .card()
    }

    private var recentEvents: some View {
        let recent = Array(diag.events.filter { $0.kind != .translation }.suffix(5).reversed())
        return VStack(alignment: .leading, spacing: 10) {
            Text("Recent activity").font(.subheadline.weight(.semibold))
            if recent.isEmpty {
                Text("Nothing has happened yet.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(recent) { e in eventRow(e) }
            Button {
                detailed = true
                pageRaw = DiagPage.timeline.rawValue
            } label: {
                Label("Open the full timeline", systemImage: "timeline.selection").font(.footnote.weight(.semibold))
            }
        }
        .card()
    }

    // MARK: Detailed
    private func pageChip(_ p: DiagPage) -> some View {
        Button { pageRaw = p.rawValue } label: {
            Label(p.title, systemImage: p.icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(page == p ? Color.white : Color.secondary)
                .background(page == p ? Theme.accent.start.opacity(0.85) : Theme.card, in: Capsule())
        }
    }

    private var detailedBody: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { ForEach(DiagPage.allCases) { p in pageChip(p) } }
            }
            if page == .speed || page == .timeline || page == .device {
                Picker("Range", selection: $rangeRaw) {
                    ForEach(DiagRange.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            switch page {
            case .overview: overviewPage
            case .speed: speedPage
            case .timeline: timelinePage
            case .pipeline:
                pipelinePage
                adaptivePipelineCard
                subtitleLifecycleCard
            case .language: languagePage
            case .device: devicePage
            case .memory: memoryPage
            case .sessions: sessionsPage
            case .log: logPage
            }
        }
    }

    private var memoryPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Translation memory").font(.headline)
            LabeledContent("Entries", value: String(diag.memoryHealth.totalEntries))
            LabeledContent("Ready / needs validation", value: "\(diag.memoryHealth.readyEntries) / \(diag.memoryHealth.needsValidation)")
            LabeledContent("Conflicts", value: String(diag.memoryHealth.conflicts))
            LabeledContent("Database", value: ByteCountFormatter.string(fromByteCount: diag.memoryHealth.databaseBytes, countStyle: .file))
            LabeledContent("RAM entries", value: String(diag.memoryHealth.ramEntries))
            LabeledContent("Schema", value: String(diag.memoryHealth.schemaVersion))
            LabeledContent("Migration", value: diag.memoryHealth.migrationStatus)
            LabeledContent("Integrity", value: diag.memoryHealth.integrity)
            LabeledContent("Pending / failed writes", value: "\(diag.memoryHealth.pendingWrites) / \(diag.memoryHealth.failedWrites)")
            Text("Pending writes are not yet durable. RAM eviction never means permanent deletion. Lookup outcomes count translation units; persistence counters count write operations.").font(.caption).foregroundStyle(.secondary)
            ForEach(MemoryDiagnosticOutcome.allCases, id: \.self) { outcome in
                LabeledContent(outcome.rawValue, value: String(diag.memoryOutcomesForUI(outcome)))
            }
            Text(diag.archiveStatus).font(.caption).foregroundStyle(.secondary)
        }.card()
    }

    private var sessionsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Save sessions on this device", isOn: $persistSessions)
            Text("Opt-in metadata only. Up to 20 sessions, 7 days and 10 MB. No screen images or recognized text. Private sessions are not saved. Only instrumented boundaries are recorded.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Save now") { diag.persistSession() }.disabled(!persistSessions)
                Button("Refresh") { Task { await diag.loadSessions() } }
            }
            Text(diag.archiveStatus).font(.caption)
            ForEach(diag.archivedSessions) { session in
                DisclosureGroup(session.startedAt.formatted()) {
                    Text("\(session.appVersion) · \(session.events.count) retained events")
                    Text("Measured through \(session.endedAt.formatted())")
                    Text(session.measurementBoundary).font(.caption)
                }
            }
            Button("Delete saved diagnostic sessions", role: .destructive) { confirmDeleteSessions = true }
        }.card()
    }

    // MARK: Overview
    private var liveFraction: Double {
        let now = Date()
        let total = now.timeIntervalSince(diag.started)
        guard total > 1 else { return 0 }
        let live = diag.spans.filter { $0.state == .live }.reduce(0.0) { $0 + ($1.end ?? now).timeIntervalSince($1.start) }
        return Swift.min(1, live / total)
    }

    private var overviewPage: some View {
        let a = diag.assessment(alive: engine.captureAlive, paused: engine.paused)
        return VStack(spacing: 14) {
            healthCard(a)
            pipelineStrip
            adaptivePipelineCard
            sessionGrid
            percentileTable
            if !a.issues.isEmpty { suggestions(a.issues, limit: 8) }
            liveFeed
        }
    }

    private var arrow: some View {
        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
    }

    private func node(_ title: String, _ icon: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.18), in: Circle())
            Text(title).font(.system(size: 9, weight: .semibold))
            Text(value).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    private var pipelineStrip: some View {
        let o = Diagnostics.summarize(Array(diag.ocr.suffix(20)))
        let t = Diagnostics.summarize(Array(diag.translate.suffix(20)))
        let d = Diagnostics.summarize(Array(diag.latency.suffix(20)))
        let fpsColor: Color = !engine.captureAlive ? Color.red : (diag.s.fps >= 15 ? Color.green : Color.orange)
        let showColor: Color = !engine.pipActive ? Color.gray : level(d.avg, d.n, 1200, 2000)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Pipeline").font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                node("Capture", "video", engine.captureAlive ? "\(Int(diag.s.fps)) fps" : "off", fpsColor)
                arrow
                node("Read", "text.viewfinder", o.n > 0 ? "\(Int(o.avg)) ms" : "–", level(o.avg, o.n, 300, 500))
                arrow
                node("Filter", "line.3.horizontal.decrease", "\(diag.s.blocksKept)/\(diag.s.blocksIn)", Color.green)
                arrow
                node("Translate", "character.bubble", t.n > 0 ? "\(Int(t.avg)) ms" : "–", level(t.avg, t.n, 400, 800))
                arrow
                node("Show", "rectangle.on.rectangle", engine.pipActive ? (d.n > 0 ? "\(Int(d.avg)) ms" : "–") : "closed", showColor)
            }
        }
        .card()
    }

    private var sessionGrid: some View {
        let s = diag.s
        let hits = s.cacheHits + s.savedHits + s.specHits + s.cacheMisses
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            StatTile(title: "Time live", value: "\(Int(liveFraction * 100))%", tint: Color.green, icon: "dot.radiowaves.left.and.right")
            StatTile(title: "Started", value: diag.started.formatted(date: .omitted, time: .shortened), icon: "clock")
            StatTile(title: "Translations", value: "\(s.translations)", tint: Color.cyan, icon: "character.bubble")
            StatTile(title: "Sentences", value: "\(s.sentences)", icon: "text.alignleft")
            StatTile(title: "Characters", value: "\(s.chars)", icon: "textformat")
            StatTile(title: "Cache hits", value: hits == 0 ? "–" : "\(Int(Double(s.cacheHits + s.savedHits + s.specHits) / Double(hits) * 100))%",
                     tint: Color.purple, icon: "memorychip")
            StatTile(title: "Capture drops", value: "\(s.captureDrops)",
                     tint: s.captureDrops > 0 ? Color.orange : Color.white, icon: "bolt.slash")
            StatTile(title: "Failures", value: "\(s.failures)",
                     tint: s.failures > 0 ? Color.red : Color.white, icon: "exclamationmark.triangle")
            StatTile(title: "Pre-translated", value: "\(s.specHits)", tint: Color.cyan, icon: "forward.fill")
            StatTile(title: "Remembered", value: "\(engine.memoryCount)", tint: Color.mint, icon: "externaldrive")
        }
    }

    private var percentileTable: some View {
        let rows: [(String, Summary)] = [
            ("Reading", Diagnostics.summarize(diag.ocr)),
            ("Translating", Diagnostics.summarize(diag.translate)),
            ("Total delay", Diagnostics.summarize(diag.latency)),
            ("Transfer", Diagnostics.summarize(diag.transport))
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Timing summary (ms)").font(.subheadline.weight(.semibold))
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("avg")
                    Text("p50")
                    Text("p95")
                    Text("max")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                ForEach(rows, id: \.0) { r in
                    GridRow {
                        Text(r.0).font(.caption.weight(.semibold)).gridColumnAlignment(.leading)
                        Text(r.1.n > 0 ? "\(Int(r.1.avg))" : "–")
                        Text(r.1.n > 0 ? "\(Int(r.1.p50))" : "–")
                        Text(r.1.n > 0 ? "\(Int(r.1.p95))" : "–")
                        Text(r.1.n > 0 ? "\(Int(r.1.max))" : "–")
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
        .card()
    }

    // MARK: Speed
    private var speedPage: some View {
        let important: Set<EventKind> = [.error, .rotation, .preset, .capture]
        let markers = Array(diag.events.filter { important.contains($0.kind) && $0.time >= rangeStart }.suffix(6))
        return VStack(spacing: 14) {
            LineCard(title: "Reading the screen", samples: slice(diag.ocr), color: Color.green, unit: "ms", rule: 300, markers: markers)
            LineCard(title: "Translating", samples: slice(diag.translate), color: Color.cyan, unit: "ms", markers: markers)
            LineCard(title: "First sighting → frame enqueue", samples: slice(diag.latency), color: Color.orange, unit: "ms", rule: 1500, markers: markers)
            LineCard(title: "Transfer extension → app", samples: slice(diag.transport), color: Color.purple, unit: "ms")
            LineCard(title: "Frames per second", samples: slice(diag.fps), color: Color.teal, unit: "fps")
            HistogramCard(title: "How long reading takes", values: slice(diag.ocr).map { $0.v }, color: Color.green)
            HistogramCard(title: "How long the total delay is", values: slice(diag.latency).map { $0.v }, color: Color.orange)
            PairedTimingCard(samples: diag.pipeline.filter { $0.date >= rangeStart })
        }
    }

    // MARK: Timeline
    private var stateCard: some View {
        let spans = diag.spans.filter { ($0.end ?? Date()) >= rangeStart }
        let evs = diag.events.filter { $0.time >= rangeStart && $0.kind != .translation && $0.kind != .state }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Session timeline").font(.subheadline.weight(.semibold))
            if spans.isEmpty {
                Text("Collecting data…").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                Chart {
                    ForEach(spans) { s in
                        RectangleMark(xStart: .value("Start", Swift.max(s.start, rangeStart)),
                                      xEnd: .value("End", s.end ?? Date()),
                                      y: .value("Lane", "State"), height: .fixed(26))
                            .foregroundStyle(s.state.color.opacity(0.85))
                    }
                    ForEach(evs) { e in
                        PointMark(x: .value("Time", e.time), y: .value("Lane", "Events"))
                            .foregroundStyle(e.kind.color)
                            .symbolSize(70)
                    }
                }
                .chartXScale(domain: rangeStart...Date())
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .frame(height: 120)
                HStack(spacing: 12) {
                    ForEach([EngineState.live, .paused, .frozen, .idle], id: \.rawValue) { st in
                        HStack(spacing: 4) {
                            Circle().fill(st.color).frame(width: 8, height: 8)
                            Text(st.title).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .card()
    }

    private var perMinuteCard: some View {
        let unit: Calendar.Component = range == .oneMin ? .second : .minute
        let tr = diag.events.filter { $0.kind == .translation && $0.time >= rangeStart && $0.text.hasPrefix("Translated") }
        let grouped = Dictionary(grouping: tr) { Calendar.current.dateInterval(of: unit, for: $0.time)?.start ?? $0.time }
        let buckets = grouped.map { Bucket(date: $0.key, count: $0.value.count) }.sorted { $0.date < $1.date }
        return VStack(alignment: .leading, spacing: 8) {
            Text(range == .oneMin ? "Translations per second" : "Translations per minute").font(.subheadline.weight(.semibold))
            if buckets.isEmpty {
                Text("No translations in this period.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                Chart(buckets) { b in
                    BarMark(x: .value("Time", b.date, unit: unit), y: .value("Translations", b.count))
                        .foregroundStyle(Color.cyan.gradient)
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 120)
            }
        }
        .card()
    }

    private var timelinePage: some View {
        VStack(spacing: 14) {
            stateCard
            perMinuteCard
            eventListCard(limit: 150)
        }
    }

    private func eventRow(_ e: TimelineEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.time, format: .dateTime.hour().minute().second())
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                Text(elapsed(e.time))
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary)
            }
            .frame(width: 58, alignment: .leading)
            Image(systemName: e.kind.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(e.kind.color)
                .frame(width: 24, height: 24)
                .background(e.kind.color.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(e.text).font(.caption)
                if let d = e.detail, !d.isEmpty {
                    Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func kindChip(_ title: String, _ icon: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(on ? Color.white : Color.secondary)
                .background(on ? color.opacity(0.7) : Theme.card, in: Capsule())
        }
    }

    private var kindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                kindChip("All", "line.3.horizontal.decrease.circle", on: kinds.isEmpty, color: Color.gray) { kinds = [] }
                ForEach(EventKind.allCases) { k in
                    kindChip(k.title, k.icon, on: kinds.contains(k), color: k.color) {
                        if kinds.contains(k) { kinds.remove(k) } else { kinds.insert(k) }
                    }
                }
            }
        }
    }

    private func eventListCard(limit: Int) -> some View {
        let all = Array(diag.events.reversed())
        let shown = all.filter { e in
            (kinds.isEmpty || kinds.contains(e.kind))
                && (query.isEmpty || e.text.localizedCaseInsensitiveContains(query)
                    || (e.detail ?? "").localizedCaseInsensitiveContains(query))
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What happened").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(shown.count) event\(shown.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            kindChips
            if shown.isEmpty {
                Text("Nothing matches.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(shown.prefix(limit))) { e in eventRow(e) }
        }
        .card()
    }

    // MARK: Pipeline
    private var subtitleLifecycleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Per-subtitle timeline").font(.headline)
            if diag.subtitleTraces.isEmpty { Text("Waiting for tracked candidates. Enable Detailed diagnostics and subtitle tracking.").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(diag.subtitleTraces.suffix(18))) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(String(item.candidate.suffix(12))) · \(item.stage) · \(item.time.formatted(date: .omitted, time: .standard))").font(.caption.monospaced())
                    Text(item.detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("Times measure app processing and frame enqueue, not physical screen presentation. Full bounded timeline is in CSV.").font(.caption).foregroundStyle(.secondary)
        }.card()
    }

    private var adaptivePipelineCard: some View {
        let s = diag.s
        return VStack(alignment: .leading, spacing: 10) {
            Text("Recognition & work accounting").font(.headline)
            Text("OCR: \(Int(s.ocrConfidence*100))% · Source: \(s.sourceOrigin == "Selected" ? "selected" : "\(Int(s.languageConfidence*100))% confidence")").font(.footnote)
            Text(s.languageContextUsed ? "Recent source context assisted this ambiguous reading" : "Source evidence uses the current reading").font(.caption).foregroundStyle(.secondary)
            Text("\(s.recognitionReason) · \(s.confirmationReason)").font(.caption).foregroundStyle(.secondary)
            Text("Cache sentences · session \(s.cacheHits) · saved \(s.savedHits) · pre-translated \(s.specHits)").font(.footnote)
            Text("Speculative jobs · started \(s.specStarted) · completed \(s.specCompleted) · discarded \(s.specDiscarded) · declined \(s.specSkipped)").font(.footnote)
            Text("Discarded work: \(Int(s.specDiscardedMs)) ms. Unconsumed cached results: \(engine.unconsumedSpeculation). Completed results may still be reused later.").font(.caption).foregroundStyle(.secondary)
            Text("Skipped frames · unchanged \(s.unchangedSkipped) · cadence \(s.cadenceSkipped) · paused \(s.pausedSkipped)").font(.caption)
            Text("Recorder self-time · simple \(String(format: "%.1f", diag.recorderCosts.simpleMs)) ms · detailed \(String(format: "%.1f", diag.recorderCosts.detailedMs)) ms. Excludes chart drawing and model work; these are different workloads.").font(.caption).foregroundStyle(.secondary)
        }.card()
    }

    private var pipelinePage: some View {
        let s = diag.s
        let inArea = Swift.max(0, s.linesIn - s.dropArea)
        let afterRules = Swift.max(0, inArea - s.dropSmall - s.dropIgnore)
        let notOwn = Swift.max(0, afterRules - s.dropSelf)
        let needs = Swift.max(0, notOwn - s.dropTarget)
        let lines = [
            BarRow(name: "Lines read", value: s.linesIn),
            BarRow(name: "In the OCR area", value: inArea),
            BarRow(name: "Big enough & allowed", value: afterRules),
            BarRow(name: "Not our own window", value: notOwn),
            BarRow(name: "Need translating", value: needs)
        ]
        let realBlocks = Swift.max(0, s.blocksKept - s.dropNoise - s.dropLanguage)
        let blocks = [
            BarRow(name: "Text blocks found", value: s.blocksIn),
            BarRow(name: "Blocks kept", value: s.blocksKept),
            BarRow(name: "Real text", value: realBlocks),
            BarRow(name: "Sentences translated", value: s.sentences)
        ]
        let parts = [
            DonutPart(name: "Translated", value: needs, color: Color.green),
            DonutPart(name: "Outside area", value: s.dropArea, color: Color.gray),
            DonutPart(name: "Too small", value: s.dropSmall, color: Color.yellow),
            DonutPart(name: "Ignore list", value: s.dropIgnore, color: Color.orange),
            DonutPart(name: "Own window", value: s.dropSelf, color: Color.pink),
            DonutPart(name: "Already target", value: s.dropTarget, color: Color.blue)
        ]
        return VStack(spacing: 14) {
            BarListCard(title: "Where lines go", rows: lines, color: Color.blue)
            DonutCard(title: "What happens to every line", parts: parts)
            BarListCard(title: "Blocks and sentences", rows: blocks, color: Color.purple)
            LineCard(title: "Lines per read", samples: Array(diag.lineCounts.suffix(120)), color: Color.mint, unit: "lines")
            VStack(alignment: .leading, spacing: 8) {
                Text("Details").font(.subheadline.weight(.semibold))
                LabeledContent("Numbers / noise dropped", value: "\(s.dropNoise)")
                LabeledContent("Other-language blocks dropped", value: "\(s.dropLanguage)")
                LabeledContent("Floating window position", value: s.pipRegion)
                LabeledContent("Unchanged frames skipped", value: "\(s.skippedFrames)")
            }
            .font(.footnote)
            .card()
        }
    }

    // MARK: Language
    private var languagePage: some View {
        let s = diag.s
        let counts = diag.sourceUsage.counts.sorted { $0.value > $1.value }.prefix(8).map { BarRow(name: $0.key.uppercased(), value: $0.value) }
        let pair: String = engine.sourceCode == "auto" ? "Auto"
            : (engine.langStatus[engine.sourceCode] == .installed ? "Ready" : "Needs pack")
        let cache = [
            DonutPart(name: "Session cache", value: s.cacheHits, color: Color.green),
            DonutPart(name: "Pre-translated", value: s.specHits, color: Color.cyan),
            DonutPart(name: "Saved memory", value: s.savedHits, color: Color.purple),
            DonutPart(name: "Translated fresh", value: s.cacheMisses, color: Color.orange)
        ]
        return VStack(spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                StatTile(title: "Source used", value: s.sourceUsed == "–" ? "–" : s.sourceUsed.uppercased(), icon: "sparkle.magnifyingglass")
                StatTile(title: "Locked to", value: s.lockedLang == "–" ? "none" : s.lockedLang.uppercased(), tint: Color.purple, icon: "lock")
                StatTile(title: "Language pack", value: pair, tint: pair == "Needs pack" ? Color.orange : Color.green, icon: "arrow.down.circle")
                StatTile(title: "Engine", value: s.sessionKind == "–" ? "–" : (s.sessionKind.contains("iOS 26") ? "Direct" : "Hosted"), icon: "cpu")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(engine.sourceCode == "auto" ? "Source: Automatic" : "Source: \(engine.sourceCode.uppercased()) selected")
                    .font(.subheadline.weight(.semibold))
                Text(engine.sourceCode == "auto" ? "With language lock enabled, four confident matching detections within six qualifying readings lock the source. Clear language changes translate immediately; three mismatches release the lock. The target language is never locked." : "Automatic detection is off. Selected-language inputs still count in the graph.")
                    .font(.caption).foregroundStyle(.secondary)
            }.card()
            BarListCard(title: "Source languages used · session", rows: Array(counts), color: Color.purple)
            BarListCard(title: "How the source was chosen", rows: SourceLanguageOrigin.allCases.map {
                BarRow(name: $0.title, value: diag.sourceUsage.origins[$0, default: 0])
            }, color: Color.teal)
            DonutCard(title: "Where translations come from", parts: cache)
            LineCard(title: "Cache hit rate over time", samples: slice(diag.cacheRate), color: Color.green, unit: "%")
            VStack(alignment: .leading, spacing: 10) {
                Text("Recognized speaker labels · session").font(.subheadline.weight(.semibold))
                Text("This session list is local and clears on reset or app restart. Exporting names still requires text-sharing consent.").font(.caption).foregroundStyle(.secondary)
                if diag.names.isEmpty {
                    Text("Private sessions hide names. Otherwise, enable speaker recognition and session speaker labels; names appear for visible text such as \"Name: line\". Voices and unlabeled people are not identified.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(diag.names, id: \.self) { n in
                            Text(n).font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Theme.accent.start.opacity(0.25), in: Capsule())
                        }
                    }
                }
            }
            .card()
        }
    }

    // MARK: Device
    private var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot (throttling)"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
    private var thermalColor: Color {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: Color.green
        case .fair: Color.yellow
        case .serious: Color.orange
        case .critical: Color.red
        @unknown default: Color.gray
        }
    }

    private var thermalCard: some View {
        let data = slice(diag.thermal)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Phone temperature").font(.subheadline.weight(.semibold))
                Spacer()
                Text(thermalName).font(.subheadline.weight(.bold)).foregroundStyle(thermalColor)
            }
            if data.count < 2 {
                Text("Collecting data…").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart(data) { s in
                    AreaMark(x: .value("Time", s.t), y: .value("Level", s.v))
                        .foregroundStyle(Color.orange.opacity(0.35))
                        .interpolationMethod(.stepEnd)
                    LineMark(x: .value("Time", s.t), y: .value("Level", s.v))
                        .foregroundStyle(Color.orange)
                        .interpolationMethod(.stepEnd)
                }
                .chartYScale(domain: 0.0...3.0)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0.0, 1.0, 2.0, 3.0]) { v in
                        AxisGridLine()
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(["Normal", "Warm", "Hot", "Critical"][Swift.min(3, Swift.max(0, Int(d)))])
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
                .frame(height: 110)
            }
        }
        .card()
    }

    private var devicePage: some View {
        let s = diag.s
        let b = UIDevice.current.batteryLevel
        return VStack(spacing: 14) {
            LineCard(title: "Extension memory headroom", samples: slice(diag.extMem), color: Color.teal, unit: "MB", rule: 15)
            LineCard(title: "Main app memory headroom", samples: slice(diag.appMem), color: Color.indigo, unit: "MB")
            thermalCard
            LineCard(title: "Battery", samples: slice(diag.battery), color: Color.green, unit: "%")
            VStack(alignment: .leading, spacing: 8) {
                Text("Details").font(.subheadline.weight(.semibold))
                LabeledContent("Capture extension", value: engine.extensionVersion == "–" ? "not seen yet" : "v\(engine.extensionVersion)")
                LabeledContent("Frame size", value: s.bufferSize)
                LabeledContent("Orientation from iOS", value: s.orientation)
                LabeledContent("Read area size", value: s.cropSize)
                LabeledContent("Rotation applied", value: "\(s.rotation * 90)°")
                LabeledContent("Lowest extension headroom", value: s.minExtFreeMB > 9000 ? "–" : "\(Int(s.minExtFreeMB)) MB")
                LabeledContent("Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
                LabeledContent("Battery now", value: b < 0 ? "–" : "\(Int(b * 100))%")
            }
            .font(.footnote)
            .card()
        }
    }

    // MARK: Log
    private var logPage: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search the log", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            eventListCard(limit: 400)
        }
    }
}
