// ScreenLingo – App – v0.7.0
import SwiftUI
import UIKit
import Translation
import NaturalLanguage
import AVFoundation
import Network

enum TranslateMode: String, CaseIterable, Identifiable {
    case movie, game, comic
    var id: String { rawValue }
    var title: String {
        switch self { case .movie: "Movie / subtitles"; case .game: "Game / apps"; case .comic: "Comic / manga" }
    }
}
enum OCRArea: String, CaseIterable, Identifiable {
    case smart, full, bottom, top, middle, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: "Smart (auto)"; case .full: "Full screen"; case .bottom: "Bottom third"
        case .top: "Top half"; case .middle: "Middle band"; case .custom: "Custom area"
        }
    }
    func range(mode: TranslateMode) -> ClosedRange<Double> {   // y: 0 = bottom, 1 = top
        switch self {
        // Smart mode must work across the entire frame in every mode: subtitles,
        // dialogue, signs, captions, and game text can appear anywhere. Keep spatial
        // restriction as an explicit user choice (Full/Bottom/Top/Middle), never an
        // implicit Movie-mode filter.
        case .smart: return 0...1
        case .full: return 0...1
        case .bottom: return 0...0.33
        case .top: return 0.5...1
        case .middle: return 0.3...0.7
        case .custom:
            let defaults = UserDefaults.standard
            let low = max(0, min(0.9, defaults.object(forKey: "customY0") as? Double ?? 0.0))
            let high = max(low + 0.05, min(1, defaults.object(forKey: "customY1") as? Double ?? 0.5))
            return low...high
        }
    }
}
enum WindowSize: String, CaseIterable, Identifiable {
    case small, normal, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var size: CGSize {
        switch self {
        case .small: CGSize(width: 720, height: 200)
        case .normal: CGSize(width: 720, height: 360)
        case .large: CGSize(width: 720, height: 540)
        }
    }
}
enum SpeedPreset: String, CaseIterable, Identifiable {
    case fast, balanced, sharp
    var id: String { rawValue }
    var title: String {
        switch self { case .fast: "Fast"; case .balanced: "Balanced"; case .sharp: "Sharp (small text)" }
    }
    var maxEdge: Double {
        switch self { case .fast: 1000; case .balanced: 1400; case .sharp: 2000 }
    }
    var interval: Double {
        switch self { case .fast: 0.12; case .balanced: 0.22; case .sharp: 0.4 }
    }
}

struct LangItem: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

struct HistoryItem: Identifiable {
    let id = UUID()
    let original: String
    let translated: String
    var date = Date()
    var starred = false
}

private struct StoredHistoryItem: Codable {
    let original: String
    let translated: String
    let date: Date
    var starred: Bool?
}

@MainActor
final class TranslatorEngine: ObservableObject {
    // Settings
    @Published var sourceCode: String {
        didSet { UserDefaults.standard.set(sourceCode, forKey: "source"); lastHandled = ""; syncConfig() }
    }
    @Published var targetCode: String {
        didSet {
            UserDefaults.standard.set(targetCode, forKey: "target"); lastHandled = ""; directSession = nil
            Task { await refreshStatus() }
        }
    }
    @Published var paused = false { didSet { syncConfig() } }
    // Languages
    @Published var languages: [LangItem] = TranslatorEngine.fallbackLanguages
    @Published var langStatus: [String: LanguageAvailability.Status] = [:]
    // Output + diagnostics
    @Published var original = ""
    @Published var translated = ""
    @Published var status = "Idle"
    @Published var captureAlive = false
    @Published var frames = 0
    @Published var ocrCount = 0
    @Published var extensionVersion = "–"
    @Published var pipActive = false
    @Published var lastRaw = ""
    @Published var lastSelectedBlocks = ""
    @Published var lastTranslationInput = ""
    @Published var lastOutputQuality = "Not evaluated"
    @Published var selectedBlockCount = 0
    @Published var lastOCRLineCount = 0
    @Published var ocrMs: Double = 0
    @Published var translateMs: Double = 0
    @Published var extFreeMB: Double = 0
    @Published var lastPacketAge: Double = 0
    @Published var lastDetectedLanguage = "—"
    @Published var cacheHits = 0
    @Published var translationFailures = 0
    @Published var lastTranslationError = "None"
    @Published var lockedLang: String? = nil
    private var languageDetectionHistory: [String] = []
    private var languageMismatchCount = 0
    // Automatic frame-rotation calibration: reject upside-down OCR ordering and retry
    // alternate quarter-turns, echoing a revision so stale frames cannot be published.
    private var orderVote = 0.0
    private var votesSinceRotationChange = 0
    private var rotationTrial = 0
    private var autoRotation = 0
    private var rotationRevision = 0
    private var rotationCalibrated = false
    @Published var diagnosticEvents: [String] = []
    @Published var processingTrace: [String] = []
    private var processingTraceDates: [Date] = []
    // Session-wide trace for full export; published trace remains a rolling 60-second view.
    private var fullProcessingTrace: [String] = []
    @Published var lastPacketKind = "None"
    @Published var totalPackets = 0
    @Published var pingPackets = 0
    @Published var ocrPackets = 0
    @Published var clearPackets = 0
    @Published var lastPacketSummary = "No packets received"
    @Published var capturePhase = "Waiting for extension"
    @Published var acceptedInputCount = 0
    @Published var discardedStaleCount = 0
    @Published var stabilizationWaitCount = 0
    @Published var lastCandidateText = ""
    @Published var lastFilterSummary = "No OCR processed"
    @Published var serverReady = false
    @Published var lastStatusChangeAt = Date()
    @Published var history: [HistoryItem] = [] {
        didSet { saveHistory() }
    }
    @Published var profileNames: [String] = []
    private static let profileStorageKey = "screenlingo.profiles.v1"
    private static let profileSettingKeys = [
        "source", "target", "mode", "area", "customY0", "customY1", "winSize", "theme", "textSize",
        "pipFont", "highlightNames", "showOriginal", "speed", "autoClear", "clearHold", "textHoldDuration", "autoOpenPiP", "minDisplay", "haptics",
        "ocrConfidence", "languageCorrection", "rightToLeftReading", "cleanOCR", "slang",
        "speakerDetect", "langLock", "neverTranslate", "sourceFixes", "glossary", "speak", "includeDiagnosticText",
        "customY0", "customY1", "frameRot", "minTextH", "ignoreList", "dropNoise", "boost",
        "stability", "skipUnchanged", "adaptive", "idleMinutes"
    ]
    // Translation session plumbing
    @Published var legacyConfig: TranslationSession.Configuration?
    @Published var downloadConfig: TranslationSession.Configuration?

    let pip = PiPRenderer()
    let server = LoopbackServer()

    private var lastHandled = ""
    private var queued: [String]?
    private var busy = false
    // Require two consecutive OCR passes before replacing the displayed translation.
    // This filters transient OCR mixtures while adding only one capture interval.
    private var pendingInput = ""
    private var pendingInputCount = 0
    private var lastShowDate = Date.distantPast
    private var showing = false
    private var pendingTexts: [String] = []
    private var legacyContinuation: CheckedContinuation<[String]?, Never>?
    private var legacyRequestID = UUID()
    private let speech = AVSpeechSynthesizer()
    private var lastPacketDate = Date.distantPast
    private var cache: [String: String] = [:]
    private var directSession: TranslationSession?
    private var directKey = ""

    // Self-reading protection: what the PiP window currently shows, and where it is on screen
    private let placeholderGrams = TextSim.grams("Waiting for screen text… Listening…")
    private var renderedGrams = TextSim.grams("Waiting for screen text… Listening…")
    private var renderedNorm = TextSim.norm("Waiting for screen text… Listening…")
    private var sourceGrams: Set<String> = []
    // Keep separate exclusion regions so distant subtitle bubbles cannot be erased together.
    private var pipRegions: [CGRect] = []
    private var pipRegionStamp = Date.distantPast

    private var ud: UserDefaults { .standard }
    private var mode: TranslateMode { TranslateMode(rawValue: ud.string(forKey: "mode") ?? "") ?? .movie }
    private var area: OCRArea { OCRArea(rawValue: ud.string(forKey: "area") ?? "") ?? .smart }
    private var windowSize: WindowSize { WindowSize(rawValue: ud.string(forKey: "winSize") ?? "") ?? .normal }
    private var speed: SpeedPreset { SpeedPreset(rawValue: ud.string(forKey: "speed") ?? "") ?? .balanced }
    private var showOriginal: Bool { (ud.object(forKey: "showOriginal") as? Bool) ?? false }
    private var speakEnabled: Bool { (ud.object(forKey: "speak") as? Bool) ?? false }
    private var pipStyle: PiPStyle {
        var style = PiPStyle.make(theme: PiPTheme(rawValue: ud.string(forKey: "theme") ?? "") ?? .dark,
                                  size: PiPTextSize(rawValue: ud.string(forKey: "textSize") ?? "") ?? .auto,
                                  font: PiPFont(rawValue: ud.string(forKey: "pipFont") ?? "") ?? .standard)
        style.highlightNames = (ud.object(forKey: "highlightNames") as? Bool) ?? true
        return style
    }
    private var autoClear: Bool { (ud.object(forKey: "autoClear") as? Bool) ?? true }
    private var textHoldDuration: Double { max(0, min(5, ud.object(forKey: "clearHold") as? Double ?? ud.object(forKey: "textHoldDuration") as? Double ?? 1.0)) }
    private var minimumOCRConfidence: Double { ud.object(forKey: "ocrConfidence") as? Double ?? 0.30 }
    private var delayedClearWork: DispatchWorkItem?
    private var languageCorrection: Bool { (ud.object(forKey: "languageCorrection") as? Bool) ?? true }

    init() {
        sourceCode = UserDefaults.standard.string(forKey: "source") ?? "auto"
        targetCode = UserDefaults.standard.string(forKey: "target") ?? "en"
        history = Self.loadHistory()
        profileNames = (UserDefaults.standard.dictionary(forKey: Self.profileStorageKey) ?? [:]).keys.sorted()
        server.onPacket = { [weak self] p in Task { @MainActor in self?.handle(p) } }
        server.onState = { [weak self] ready in
            Task { @MainActor in
                guard let self else { return }
                self.serverReady = ready
                self.recordDiagnostic(ready ? "UDP listener ready" : "UDP listener failed or stopped")
            }
        }
        server.onDiagnostic = { [weak self] message in
            Task { @MainActor in self?.recordDiagnostic(message) }
        }
        recordDiagnostic("App initialized; starting UDP listener")
        server.start()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let alive = Date().timeIntervalSince(self.lastPacketDate) < 5
                if self.captureAlive && !alive {
                    self.status = "Capture stopped – iOS may have closed the capture extension. Tap the broadcast icon again (try Speed: Fast)."
                }
                self.captureAlive = alive
                self.lastPacketAge = self.lastPacketDate == .distantPast ? -1 : Date().timeIntervalSince(self.lastPacketDate)
                if self.lastPacketDate == .distantPast {
                    self.capturePhase = self.serverReady ? "Listener ready; waiting for capture extension" : "Listener unavailable"
                } else if !alive {
                    self.capturePhase = "Packets stopped; extension may have ended"
                } else {
                    self.capturePhase = self.pipActive ? "Capture connected; PiP active" : "Capture connected; PiP inactive"
                }
            }
        }
        pip.setSize(windowSize.size)
        pip.onStatus = { [weak self] s in Task { @MainActor in self?.status = s } }
        pip.onActiveChange = { [weak self] a in Task { @MainActor in self?.pipActive = a } }
    }


    private func recordDiagnostic(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        diagnosticEvents.append("[\(formatter.string(from: Date()))] \(message)")
        if diagnosticEvents.count > 120 { diagnosticEvents.removeFirst(diagnosticEvents.count - 120) }
        lastStatusChangeAt = Date()
    }

    /// Local-only pipeline trace. Entries expire after 60 seconds.
    private func trace(_ stage: String, _ detail: String) {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let entry = "[\(formatter.string(from: now))] [\(stage)] \(detail)"
        processingTrace.append(entry)
        processingTraceDates.append(now)
        fullProcessingTrace.append(entry)
        if fullProcessingTrace.count > 2000 { fullProcessingTrace.removeFirst(fullProcessingTrace.count - 2000) }
        while let first = processingTraceDates.first, now.timeIntervalSince(first) > 60 {
            processingTraceDates.removeFirst()
            processingTrace.removeFirst()
        }
        if processingTrace.count > 500 {
            let excess = processingTrace.count - 500
            processingTrace.removeFirst(excess)
            processingTraceDates.removeFirst(excess)
        }
    }

    private func traceBlock(_ lines: [OCRLine]) -> String {
        let text = blockText(lines).replacingOccurrences(of: "\n", with: " ")
        let minX = lines.map { $0.x - ($0.w ?? 0.2) / 2 }.min() ?? 0
        let maxX = lines.map { $0.x + ($0.w ?? 0.2) / 2 }.max() ?? 0
        let minY = lines.map { $0.y - $0.h / 2 }.min() ?? 0
        let maxY = lines.map { $0.y + $0.h / 2 }.max() ?? 0
        return String(format: "bbox x=%.3f…%.3f y=%.3f…%.3f; %d lines; text=%@", minX, maxX, minY, maxY, lines.count, text)
    }

    private func languageDecision(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let target = Locale.Language(identifier: targetCode).languageCode
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        let scores = hypotheses.sorted { $0.value > $1.value }.map { item in
            "\(Locale.Language(identifier: item.key.rawValue).languageCode?.identifier ?? item.key.rawValue)=\(String(format: "%.2f", item.value))"
        }.joined(separator: ", ")
        let targetScore = hypotheses.reduce(0.0) { $0 + (Locale.Language(identifier: $1.key.rawValue).languageCode == target ? $1.value : 0) }
        return "target=\(targetCode) score=\(String(format: "%.2f", targetScore)); hypotheses=[\(scores)]"
    }

    private func privacySafe(_ value: String, includeRecognizedText: Bool) -> String {
        guard !includeRecognizedText else { return value }
        var result = value
        let patterns = [
            #"(?i)(text=)[^;\n]*"#,
            #"(?i)(RAW OCR:\n)[\s\S]*?(?=\n[A-Z][A-Z _()-]+:\n|\nPROCESSING TRACE|\nDIAGNOSTIC EVENTS|$)"#,
            #"(?i)(CANDIDATE:\n)[\s\S]*?(?=\n[A-Z][A-Z _()-]+:\n|\nPROCESSING TRACE|\nDIAGNOSTIC EVENTS|$)"#,
            #"(?i)(SELECTED BLOCKS:\n)[\s\S]*?(?=\n[A-Z][A-Z _()-]+:\n|\nPROCESSING TRACE|\nDIAGNOSTIC EVENTS|$)"#,
            #"(?i)(TRANSLATION INPUT:\n)[\s\S]*?(?=\n[A-Z][A-Z _()-]+:\n|\nPROCESSING TRACE|\nDIAGNOSTIC EVENTS|$)"#,
            #"(?i)(CURRENT ORIGINAL:\n)[\s\S]*?(?=\n[A-Z][A-Z _()-]+:\n|\nPROCESSING TRACE|\nDIAGNOSTIC EVENTS|$)"#,
            #"(?i)(CURRENT TRANSLATION:\n)[\s\S]*?(?=\n[A-Z][A-Z _()-]+:\n|\nPROCESSING TRACE|\nDIAGNOSTIC EVENTS|$)"#,
            #"(?i)(Accepted OCR input immediately: )[^;\n]*"#,
            #"(?i)(Translation complete: )[^;\n]*"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1[REDACTED]")
            }
        }
        return result
    }

    private static var thermalStateLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "normal"
        case .fair: return "warm"
        case .serious: return "hot"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static var batteryLevelLabel: String {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        return level < 0 ? "unavailable" : "\(Int(level * 100))%"
    }

    func copyDetailedDiagnosticReport(includeRecognizedText: Bool = true, compact: Bool = true) -> String {
        let now = Date()
        let traceEntries: [String]
        let eventEntries: [String]
        if compact {
            let recent = zip(processingTrace, processingTraceDates).filter { now.timeIntervalSince($0.1) <= 60 }
            traceEntries = recent.suffix(180).map { $0.0 }
            eventEntries = Array(diagnosticEvents.suffix(30))
        } else {
            traceEntries = fullProcessingTrace
            eventEntries = diagnosticEvents
        }
        let sections = [
            "ScreenLingo \(AppVersion.full)",
            "Report type: \(compact ? "Compact (rolling 60 seconds)" : "Full diagnostic history; trace retention capped at 2,000 events")",
            "Timestamp: \(ISO8601DateFormatter().string(from: now))",
            "Recognized text included: \(includeRecognizedText)",
            "Capture=\(capturePhase); connected=\(captureAlive); PiP=\(pipActive); extension=\(extensionVersion)",
            "Packets all=\(totalPackets), ping=\(pingPackets), OCR=\(ocrPackets), clear=\(clearPackets); last=\(lastPacketSummary)",
            "Frames=\(frames); OCR passes=\(ocrCount); raw lines=\(lastOCRLineCount); OCR ms=\(Int(ocrMs)); translation ms=\(Int(translateMs))",
            "Source setting=\(sourceCode), detected=\(lastDetectedLanguage), target=\(targetCode), mode=\(mode.rawValue), area=\(area.rawValue)",
            "Filter counts: \(lastFilterSummary)",
            "Accepted=\(acceptedInputCount); stabilization waits=\(stabilizationWaitCount); stale discarded=\(discardedStaleCount); cache hits=\(cacheHits); failures=\(translationFailures)",
            "Last error=\(lastTranslationError); quality=\(lastOutputQuality); status=\(status)",
            "Device: thermal=\(Self.thermalStateLabel); lowPowerMode=\(ProcessInfo.processInfo.isLowPowerModeEnabled); battery=\(Self.batteryLevelLabel)",
            "RAW OCR:\n\(String(lastRaw.prefix(compact ? 1200 : 10000)))",
            "CANDIDATE:\n\(String(lastCandidateText.prefix(compact ? 1000 : 10000)))",
            "SELECTED BLOCKS:\n\(String(lastSelectedBlocks.prefix(compact ? 1000 : 10000)))",
            "TRANSLATION INPUT:\n\(String(lastTranslationInput.prefix(compact ? 1200 : 10000)))",
            "CURRENT ORIGINAL:\n\(String(original.prefix(compact ? 800 : 10000)))",
            "CURRENT TRANSLATION:\n\(String(translated.prefix(compact ? 800 : 10000)))",
            "PROCESSING TRACE (\(traceEntries.count) events):\n\(traceEntries.joined(separator: "\n"))",
            "DIAGNOSTIC EVENTS (\(eventEntries.count) events):\n\(eventEntries.joined(separator: "\n"))"
        ]
        let report = privacySafe(sections.joined(separator: "\n"), includeRecognizedText: includeRecognizedText)
        guard compact, report.count > 15000 else { return report }
        return String(report.prefix(14960)) + "\n[Compact report truncated at 15,000 characters]"
    }

    func clearDiagnosticEvents() {
        diagnosticEvents.removeAll()
        processingTrace.removeAll()
        processingTraceDates.removeAll()
        fullProcessingTrace.removeAll()
        recordDiagnostic("Diagnostic event log cleared")
        trace("DIAGNOSTICS", "Event log and processing trace cleared")
    }

    private static let historyKey = "screenlingo.history.v1"

    private static func loadHistory() -> [HistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let stored = try? JSONDecoder().decode([StoredHistoryItem].self, from: data) else { return [] }
        let retentionDays = max(0, UserDefaults.standard.integer(forKey: "historyRetentionDays"))
        let cutoff = retentionDays > 0
            ? Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())
            : nil
        return stored.filter { item in cutoff.map { item.date >= $0 } ?? true }
            .prefix(100)
            .map { item in
                HistoryItem(original: item.original, translated: item.translated, date: item.date, starred: item.starred ?? false)
            }
    }

    private func saveHistory() {
        let retentionDays = max(0, UserDefaults.standard.integer(forKey: "historyRetentionDays"))
        let cutoff = retentionDays > 0
            ? Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())
            : nil
        let retained = history.filter { item in cutoff.map { item.date >= $0 } ?? true }
        let stored = retained.prefix(100).map {
            StoredHistoryItem(original: $0.original, translated: $0.translated, date: $0.date, starred: $0.starred)
        }
        guard let data = try? JSONEncoder().encode(Array(stored)) else { return }
        UserDefaults.standard.set(data, forKey: Self.historyKey)
    }

    func applyHistoryRetention() {
        let retentionDays = max(0, UserDefaults.standard.integer(forKey: "historyRetentionDays"))
        guard retentionDays > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else { return }
        let retained = history.filter { $0.date >= cutoff }
        if retained.count != history.count { history = retained }
        recordDiagnostic("Applied history retention: \(retentionDays) day(s); retained \(history.count) item(s)")
    }

    func toggleStar(_ id: UUID) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].starred.toggle()
    }

    // MARK: Settings profiles and backup
    private func storedProfiles() -> [String: [String: Any]] {
        UserDefaults.standard.dictionary(forKey: Self.profileStorageKey) as? [String: [String: Any]] ?? [:]
    }

    func saveProfile(_ name: String) {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { status = "Enter a profile name"; return }
        var profiles = storedProfiles()
        var values: [String: Any] = [:]
        for setting in Self.profileSettingKeys {
            if let value = UserDefaults.standard.object(forKey: setting) { values[setting] = value }
        }
        profiles[key] = values
        UserDefaults.standard.set(profiles, forKey: Self.profileStorageKey)
        profileNames = profiles.keys.sorted()
        status = "Saved profile: \(key)"
        recordDiagnostic("Saved settings profile \(key)")
    }

    func applyProfile(_ name: String) {
        guard let values = storedProfiles()[name] else { status = "Profile not found"; return }
        for (key, value) in values where Self.profileSettingKeys.contains(key) {
            UserDefaults.standard.set(value, forKey: key)
        }
        sourceCode = UserDefaults.standard.string(forKey: "source") ?? sourceCode
        targetCode = UserDefaults.standard.string(forKey: "target") ?? targetCode
        syncConfig()
        applyStyle()
        applyWindowSize()
        status = "Applied profile: \(name)"
        recordDiagnostic("Applied settings profile \(name)")
    }

    func deleteProfile(_ name: String) {
        var profiles = storedProfiles()
        profiles.removeValue(forKey: name)
        UserDefaults.standard.set(profiles, forKey: Self.profileStorageKey)
        profileNames = profiles.keys.sorted()
    }

    func exportSettings() -> String {
        let payload: [String: Any] = [
            "format": "ScreenLingoSettings",
            "version": 1,
            "settings": Dictionary(uniqueKeysWithValues: Self.profileSettingKeys.compactMap { key in
                UserDefaults.standard.object(forKey: key).map { (key, $0) }
            }),
            "profiles": storedProfiles()
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: data, encoding: .utf8) else { return "{}" }
        return result
    }

    @discardableResult
    func importSettings(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            status = "Invalid settings backup"; return false
        }
        let values = (payload["settings"] as? [String: Any]) ?? payload
        var imported = 0
        for key in Self.profileSettingKeys {
            if let value = values[key], !(value is NSNull) {
                UserDefaults.standard.set(value, forKey: key); imported += 1
            }
        }
        if let profiles = payload["profiles"] as? [String: [String: Any]] {
            UserDefaults.standard.set(profiles, forKey: Self.profileStorageKey)
            profileNames = profiles.keys.sorted()
        }
        sourceCode = UserDefaults.standard.string(forKey: "source") ?? sourceCode
        targetCode = UserDefaults.standard.string(forKey: "target") ?? targetCode
        syncConfig(); applyStyle(); applyWindowSize()
        status = imported > 0 ? "Imported \(imported) settings" : "No recognized settings found"
        recordDiagnostic("Imported settings backup: \(imported) setting(s)")
        return imported > 0
    }

    func resetAllSettings() {
        for key in Self.profileSettingKeys { UserDefaults.standard.removeObject(forKey: key) }
        sourceCode = "auto"
        targetCode = "en"
        syncConfig(); applyStyle(); applyWindowSize()
        status = "Settings reset to defaults"
        recordDiagnostic("Reset all app settings")
    }

    // MARK: Settings → capture extension
    /// Sends OCR area, source-language hint and speed to the extension.
    func syncConfig() {
        let r = area.range(mode: mode)
        let defaults = UserDefaults.standard
        let customMinHeight = defaults.object(forKey: "minTextH") as? Double ?? 0
        let ignore = (defaults.string(forKey: "ignoreList") ?? "")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let rotationSetting = defaults.string(forKey: "frameRot") ?? "auto"
        let rotation = rotationSetting == "auto" ? autoRotation : (["90": 1, "180": 2, "270": 3][rotationSetting] ?? 0)
        server.send(Config(lang: sourceCode, y0: r.lowerBound, y1: r.upperBound,
                           maxEdge: speed.maxEdge, interval: speed.interval, paused: paused,
                           minimumConfidence: minimumOCRConfidence, languageCorrection: languageCorrection,
                           minimumTextHeight: customMinHeight > 0 ? customMinHeight : nil,
                           ignoreList: ignore,
                           dropNoise: defaults.object(forKey: "dropNoise") as? Bool ?? true,
                           boost: defaults.object(forKey: "boost") as? Int ?? 1,
                           stability: defaults.object(forKey: "stability") as? Int ?? 2,
                           skipUnchanged: defaults.object(forKey: "skipUnchanged") as? Bool ?? true,
                           rotation: rotation,
                           adaptive: defaults.object(forKey: "adaptive") as? Bool ?? true,
                           idleMinutes: defaults.object(forKey: "idleMinutes") as? Int ?? 0,
                            revision: rotationRevision))
    }

    /// Reset automatic reading-order calibration when the user changes the rotation mode.
    func rotationSettingChanged() {
        autoRotation = 0
        rotationTrial = 0
        orderVote = 0
        votesSinceRotationChange = 0
        rotationCalibrated = false
        rotationRevision += 1
        syncConfig()
                recordDiagnostic("Reading-order calibration reset; mode=\(UserDefaults.standard.string(forKey: "frameRot") ?? "auto")")
    }

    /// Detect when line order reads more naturally in reverse and try another frame rotation.
    private func updateOrderVote(_ lines: [OCRLine]) {
        var difference = 0.0
        for block in makeBlocks(lines) where block.count >= 2 {
            let forward = readingOrder(block).map(\.t)
            difference += TextIntel.orderScore(forward) - TextIntel.orderScore(Array(forward.reversed()))
        }
        guard difference != 0 else { return }
        orderVote = max(-30, min(30, orderVote * 0.8 + difference))
        votesSinceRotationChange += 1
        let mode = UserDefaults.standard.string(forKey: "frameRot") ?? "auto"
        guard mode == "auto" else { return }
        if orderVote < -4 && votesSinceRotationChange >= 2 {
            rotationTrial = (rotationTrial + 1) % 4
            autoRotation = [0, 2, 1, 3][rotationTrial]
            rotationRevision += 1
            orderVote = 0
            votesSinceRotationChange = 0
            rotationCalibrated = false
            recordDiagnostic("Reading order appears reversed; testing rotation \(autoRotation * 90)°")
            syncConfig()
        } else if orderVote > 4 && !rotationCalibrated {
            rotationCalibrated = true
            recordDiagnostic("Reading order calibrated at rotation \(autoRotation * 90)°")
        }
    }

    // MARK: PiP
    /// Starts the PiP window (retrying while iOS gets ready), then calls `done`.
    func startPiP(then done: @escaping () -> Void = {}) {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? s.setActive(true)
        pip.setSize(windowSize.size)
        attemptPiP(0, done)
    }
    private func attemptPiP(_ n: Int, _ done: @escaping () -> Void) {
        // A true return from start() means iOS accepted the request, not that PiP
        // actually became active. The previous implementation called done() after
        // one second regardless, masking a failed start and leaving capture unusable.
        if pip.isActive {
            status = captureAlive ? "Capture connected · floating window ready" : status
            done()
            return
        }
        if n >= 12 {
            status = "PiP failed to become active. Keep ScreenLingo in the foreground, close other PiP windows, then retry."
            done()
            return
        }

        if pip.start() {
            status = "Waiting for iOS to open the floating window… (attempt \(n + 1)/12)"
        } else {
            status = "iOS PiP is not ready yet… retrying (attempt \(n + 1)/12)"
        }

        // Wait for the delegate to report actual activation; if iOS rejected or
        // stalled the request, try again instead of reporting success prematurely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self else { done(); return }
            if self.pip.isActive {
                self.status = self.captureAlive ? "Capture connected · floating window ready" : self.status
                done()
            } else {
                self.attemptPiP(n + 1, done)
            }
        }
    }
    func swapLanguages() {
        guard sourceCode != "auto" else { status = "Pick a source language to swap"; return }
        let s = sourceCode
        sourceCode = targetCode
        targetCode = s
    }
    func applyWindowSize() { pip.setSize(windowSize.size) }
    func applyStyle() { pip.style = pipStyle; pip.rerender() }

    // MARK: Packets from the extension
    private func handle(_ p: Packet) {
        let wasAlive = captureAlive
        lastPacketDate = Date()
        lastPacketKind = p.kind
        totalPackets += 1
        lastPacketSummary = "kind=\(p.kind), frames=\(p.frames), lines=\(p.lines.count), version=\(p.version)"
        switch p.kind {
        case "ping": pingPackets += 1
        case "ocr": ocrPackets += 1
        case "clear": clearPackets += 1
        default: break
        }
        capturePhase = "Receiving \(p.kind) packets"
        if totalPackets == 1 || totalPackets % 20 == 0 {
            recordDiagnostic("Packet #\(totalPackets): \(lastPacketSummary)")
        }
        captureAlive = true
        frames = p.frames
        extensionVersion = p.version
        if let t = p.ocrMs { ocrMs = t }
        if let m = p.memFreeMB { extFreeMB = m }

        if !wasAlive {
            syncConfig()
            // Capture just started: make sure the floating window is up too.
            let autoOpen = (ud.object(forKey: "autoOpenPiP") as? Bool) ?? true
            if autoOpen, !pip.isActive, UIApplication.shared.applicationState == .active { startPiP() }
        }
        if p.kind == "ping" { syncConfig(); return }       // keeps the extension's settings fresh
        if paused { return }
        if p.kind == "clear" { handleClear(); return }
        guard p.kind == "ocr" else { return }
        ocrCount += 1
        lastRaw = String(p.lines.map(\.t).joined(separator: " ").prefix(1200))
        lastOCRLineCount = p.lines.count
        trace("PACKET", "OCR #\(ocrCount), frames=\(p.frames), lines=\(p.lines.count), extension=\(p.version), OCR ms=\(p.ocrMs ?? 0)")
        for (i, line) in p.lines.enumerated() {
            trace("RAW LINE", String(format: "#%02d x=%.3f y=%.3f w=%.3f h=%.3f | %@", i + 1, line.x, line.y, line.w ?? -1, line.h, line.t))
        }
        let orderedForTrace = readingOrder(p.lines)
        trace("CANONICAL OCR ORDER", orderedForTrace.enumerated().map {
            String(format: "#%02d y=%.3f x=%.3f | %@", $0.offset + 1, $0.element.y, $0.element.x, $0.element.t)
        }.joined(separator: "\n"))
        // ReplayKit doesn't identify the foreground bundle. Treat origin as a
        // heuristic, not as proof that an unknown frame is video content. This is
        // especially important while the user swipes through ScreenLingo, Home,
        // app switcher, or navigation transitions before/after opening the video.
        let frameIsScreenLingoUI = isScreenLingoInterface(p.lines)
        trace("FRAME ORIGIN", frameIsScreenLingoUI
              ? "SCREENLINGO_APP_UI | distinctive app controls detected; drop frame"
              : "NON_SCREENLINGO_OR_UNKNOWN | ReplayKit supplies no foreground app identity; may be video, Home Screen, app switcher, or transition")
        if frameIsScreenLingoUI {
            trace("FRAME FILTER", "DROP entire ScreenLingo UI frame before grouping/translation")
            recordDiagnostic("FRAME FILTER=SCREENLINGO_APP_UI; ignored app-owned interface frame")
            return
        }

        if let packetRevision = p.rev, packetRevision != rotationRevision {
            discardedStaleCount += 1
            trace("ROTATION REVISION", "Dropped stale OCR packet revision=\(packetRevision), current=\(rotationRevision)")
            return
        }
        let range = area.range(mode: mode)
        var cand = p.lines.filter { range.contains($0.y) }
        trace("AREA FILTER", "\(p.lines.count) raw → \(cand.count) inside \(area.rawValue) y=\(range.lowerBound)…\(range.upperBound)")
        if mode == .movie {
            let beforeUI = cand.count
            let removedUI = cand.filter { isScreenLingoChromeText($0.t) }
            cand = cand.filter { !isScreenLingoChromeText($0.t) }
            trace("MOVIE UI FILTER", "\(beforeUI - cand.count) ScreenLingo control/diagnostic lines removed; \(cand.count) remain; dropped=[\(removedUI.map(\.t).joined(separator: " | "))]")
        }
        let beforeOwnOutput = cand.count
        cand = removeOwnOutput(cand)
        trace("PIP FEEDBACK", "\(beforeOwnOutput - cand.count) likely self-output lines removed; \(cand.count) remain")
        if mode == .movie {
            let beforeDedupe = cand.count
            cand = dedupeOCRLines(cand)
            trace("OCR DEDUPE", "\(beforeDedupe) lines → \(cand.count); removed \(beforeDedupe - cand.count) near-identical OCR copies with overlapping geometry")
        }
        // Calibrate from filtered source candidates, not our own PiP or app controls.
        let revisionBeforeCalibration = rotationRevision
        updateOrderVote(cand)
        if rotationRevision != revisionBeforeCalibration {
            trace("ROTATION REVISION", "Dropped frame used to choose a new reading rotation")
            return
        }
        let groupedBlocks = makeBlocks(cand)
        trace("BLOCK GROUPING", "\(cand.count) lines → \(groupedBlocks.count) blocks")
        for (i, block) in groupedBlocks.enumerated() {
            trace("BLOCK \(i + 1)", "\(traceBlock(block)); \(languageDecision(blockText(block)))")
        }
        let sourceBlocks = groupedBlocks.filter { block in
            let text = blockText(block)
            let rejected = isTargetLanguage(text)
            trace("LANGUAGE FILTER", "\(rejected ? "REJECT target feedback" : "KEEP possible source") | \(text) | \(languageDecision(text))")
            return !rejected
        }
        let blocks = selectBlocks(sourceBlocks)
        trace("BLOCK SELECTION", "\(sourceBlocks.count) possible → \(blocks.count) selected; mode=\(mode.rawValue), area=\(area.rawValue)")
        let texts = dedupe(blocks.map { blockText($0) }.filter { text in
            let valid = TextSim.norm(text).count >= 2 && isUsefulOCRText(text) && plausiblySource(text)
            trace("TEXT VALIDATION", "\(valid ? "KEEP" : "DROP") | \(text)")
            return valid
        })
        trace("FINAL OCR", texts.isEmpty ? "No source text accepted; keeping last good result." : "Sending \(texts.count) block(s):\n" + texts.enumerated().map { "#\($0.offset + 1) \($0.element)" }.joined(separator: "\n"))
        selectedBlockCount = texts.count
        lastSelectedBlocks = texts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        lastFilterSummary = "raw=\(p.lines.count), in-area=\(p.lines.filter { range.contains($0.y) }.count), post-filter=\(cand.count), grouped=\(groupedBlocks.count), source=\(sourceBlocks.count), selected=\(texts.count)"
        // A single empty/noisy OCR pass is not evidence that the dialogue disappeared.
        // Keep the last good result until the extension explicitly reports a clear frame.
        guard !texts.isEmpty else { return }

        // The capture extension deliberately sends only changed OCR states, not
        // repeated identical frames. Waiting for a second matching packet therefore
        // blocks updates until the user swipes or the text changes again.
        // Accept the first usable state; enqueue() already suppresses OCR jitter
        // and near-duplicates without blocking short-lived subtitles.
        delayedClearWork?.cancel()
        delayedClearWork = nil
        let candidate = texts.map { String($0.prefix(900)) }.joined(separator: "\n")

        // OCR can intermittently lose the first line/words of a still-visible subtitle.
        // Do not replace a recently displayed complete sentence with a much shorter
        // candidate that is exactly its tail; that produces a visible correct → truncated
        // → correct flicker. This is deliberately short-lived and only applies to suffixes,
        // so genuine new dialogue and unrelated text can still replace the current result.
        let previousNorm = TextSim.norm(original)
        let candidateNorm = TextSim.norm(candidate)
        let shownRecently = showing && Date().timeIntervalSince(lastShowDate) < 2.0
        let looksLikeDroppedPrefix = previousNorm.count >= candidateNorm.count + 8
            && candidateNorm.count >= 8
            && Double(candidateNorm.count) / Double(max(1, previousNorm.count)) < 0.82
            && previousNorm.contains(candidateNorm)
        if shownRecently && looksLikeDroppedPrefix {
            stabilizationWaitCount += 1
            trace("OCR STABILIZATION", "Rejected likely truncated suffix; kept recent complete text (old=\(previousNorm.count) chars, candidate=\(candidateNorm.count) chars)")
            recordDiagnostic("Ignored a likely partial OCR result that omitted the beginning of the current sentence")
            return
        }

        pendingInput = candidate
        pendingInputCount = 1
        acceptedInputCount += 1
        lastCandidateText = candidate
        recordDiagnostic("Accepted OCR input immediately: \(candidate.count) characters")

        // Keep separate spatial regions separate; never merge different bubbles.
        enqueue(texts.map { String($0.prefix(900)) })
    }

    // MARK: Text blocks
    /// Deterministic visual reading order for Vision OCR observations.
    /// Vision uses a bottom-left origin, so larger normalized y means visually higher.
    /// Group by vertical overlap/line height (not exact y equality), then read each
    /// row left-to-right. Stable index tie-breakers prevent sort comparator ambiguity.
    private func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        let sorted = lines.enumerated().sorted {
            if abs($0.element.y - $1.element.y) < 0.000001 { return $0.offset < $1.offset }
            return $0.element.y > $1.element.y
        }
        var rows: [[(index: Int, line: OCRLine)]] = []
        var anchors: [Double] = []
        for item in sorted {
            let line = item.element
            let lineHeight = max(line.h, 0.012)
            let tolerance = max(0.012, min(lineHeight * 0.65, 0.075))
            // Prefer the nearest compatible row; do not attach to the first row
            // merely because its tolerance happens to overlap.
            let compatible = anchors.indices
                .filter { abs(anchors[$0] - line.y) <= max(tolerance, min(lineHeight, 0.075) * 0.5) }
                .min { abs(anchors[$0] - line.y) < abs(anchors[$1] - line.y) }
            if let idx = compatible {
                rows[idx].append((item.offset, line))
                anchors[idx] = rows[idx].map { $0.line.y }.reduce(0, +) / Double(rows[idx].count)
            } else {
                rows.append([(item.offset, line)])
                anchors.append(line.y)
            }
        }
        return rows.flatMap { row in
            row.sorted {
                if abs($0.line.x - $1.line.x) < 0.000001 { return $0.index < $1.index }
                return $0.line.x < $1.line.x
            }.map(\.line)
        }
    }

    /// Clusters OCR lines into vertical text runs.
    /// Same-row OCR observations are deliberately kept separate: their bounding boxes
    /// often overlap even when they come from different speakers or speech bubbles.
    /// Only tightly aligned, similarly sized lines on adjacent rows may be joined.
    private func makeBlocks(_ lines: [OCRLine]) -> [[OCRLine]] {
        // Use the same canonical row-based ordering everywhere. Sorting raw OCR
        // observations independently here used to disagree with readingOrder() when
        // several boxes occupied one visual line.
        let ordered = readingOrder(lines)

        var blocks: [[OCRLine]] = []
        for line in ordered {
            let lineWidth = max(line.w ?? 0.2, 0.001)
            var bestIndex: Int?
            var bestScore = -Double.infinity

            for index in blocks.indices {
                guard let previous = blocks[index].last else { continue }
                // A line can only attach to the immediately preceding line of a block.
                // Do not let a distant line jump across another speech bubble.
                let previousWidth = max(previous.w ?? 0.2, 0.001)
                let overlap = min(line.x + lineWidth / 2, previous.x + previousWidth / 2)
                    - max(line.x - lineWidth / 2, previous.x - previousWidth / 2)
                let verticalGap = previous.y - line.y
                let lineHeight = max(previous.h, line.h, 0.001)
                let sizeRatio = min(previous.h, line.h) / lineHeight
                // Compare empty space between box edges, not just center distance.
                // Tall OCR boxes can otherwise bridge separate dialogue bubbles.
                let edgeGap = verticalGap - (previous.h + line.h) / 2

                // Vision y increases upward. Since input is top-to-bottom, the next
                // line must be below the previous line and within a plausible line gap.
                let centerDistance = abs(line.x - previous.x)
                let overlapRatio = overlap / max(0.001, min(lineWidth, previousWidth))
                let horizontalGap = max(
                    0,
                    max(line.x - lineWidth / 2, previous.x - previousWidth / 2)
                        - min(line.x + lineWidth / 2, previous.x + previousWidth / 2)
                )
                let stacked = verticalGap > 0.20 * lineHeight
                    && edgeGap < 0.75 * lineHeight
                    && edgeGap > -0.35 * lineHeight
                    && (overlapRatio > 0.35 || centerDistance < 0.09)
                    // Large horizontal spans often indicate separate speech bubbles
                    // or an OCR line from the floating PiP overlay. Do not bridge them
                    // merely because their text boxes overlap a little.
                    && !(lineWidth > 0.62 && previousWidth > 0.62 && centerDistance > 0.035)
                // Movie subtitles can be returned as multiple side-by-side OCR boxes
                // on one visual row. Claude's working implementation joined these
                // when their box edges were close; keeping them separate lets Movie
                // mode rank a fragment and discard the rest of the actual sentence.
                // Keep the stricter vertical-only rule for comic/game bubbles, where
                // adjacent same-row boxes may belong to different speakers.
                // Vision can split one long subtitle into adjacent boxes whose
                // vertical centers differ slightly (for example, a long left box and
                // a short final-word box on the right). Compare box-edge spacing and
                // the smaller box height, rather than requiring nearly identical
                // center y values; otherwise the last words become a separate block.
                let sameMovieRow = mode == .movie
                    && abs(verticalGap) <= max(0.016, min(previous.h, line.h) * 1.25)
                    && edgeGap <= 0.35 * lineHeight
                    && edgeGap >= -0.35 * lineHeight
                    && horizontalGap < 0.06
                guard sizeRatio > 0.45, (stacked || sameMovieRow) else { continue }

                let score = (overlap / min(lineWidth, previousWidth))
                    - abs(edgeGap) / lineHeight * 0.15
                    - abs(line.x - previous.x) * 0.2
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }

            if let bestIndex {
                blocks[bestIndex].append(line)
            } else {
                blocks.append([line])
            }
        }

        // Canonicalize each block's line order after grouping, then order regions
        // top-to-bottom. For regions on the same row, read left-to-right (or RTL
        // in the later mode-specific display ordering).
        return blocks.map { readingOrder($0) }.sorted {
            let ay = $0.map(\.y).max() ?? 0
            let by = $1.map(\.y).max() ?? 0
            if abs(ay - by) > 0.02 { return ay > by }
            let ax = $0.map(\.x).min() ?? 0
            let bx = $1.map(\.x).min() ?? 0
            return ax < bx
        }
    }

    private func blockHeight(_ b: [OCRLine]) -> Double {
        let h = b.map(\.h).sorted()
        return h.isEmpty ? 0 : h[h.count / 2]
    }
    private func blockWeight(_ b: [OCRLine]) -> Double {
        blockHeight(b) * Double(b.reduce(0) { $0 + $1.t.count }).squareRoot()
    }

    /// Movie mode keeps the dominant block(s); other modes keep everything that isn't tiny.
    private func selectBlocks(_ blocks: [[OCRLine]]) -> [[OCRLine]] {
        guard !blocks.isEmpty else { return [] }
        let maxH = blocks.map { blockHeight($0) }.max() ?? 0
        var kept = blocks
        if mode == .movie {
            func movieScore(_ block: [OCRLine]) -> Double {
                let text = blockText(block)
                let letters = Double(text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count)
                let lineBonus = Double(max(0, block.count - 1)) * 12
                let width = block.compactMap(\.w).max() ?? 0
                let centerY = block.map(\.y).reduce(0, +) / Double(max(1, block.count))
                let subtitleZoneBonus = (centerY >= 0.08 && centerY <= 0.48) ? 8.0 : 0.0
                let upperScreenPenalty = centerY > 0.72 ? 22.0 : (centerY > 0.60 ? 8.0 : 0.0)
                let words = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).count
                let sentenceBonus = (words >= 3 && text.contains(where: { ".!?¡¿。！？".contains($0) })) ? 10.0 : 0.0
                let fragmentPenalty = (words <= 2 && letters < 15) ? 18.0 : 0.0
                return min(letters, 140) + lineBonus + min(12.0, width * 12.0)
                    + subtitleZoneBonus + sentenceBonus - fragmentPenalty - upperScreenPenalty
            }

            func centerY(_ block: [OCRLine]) -> Double {
                block.map(\.y).reduce(0, +) / Double(max(1, block.count))
            }
            func centerX(_ block: [OCRLine]) -> Double {
                block.map(\.x).reduce(0, +) / Double(max(1, block.count))
            }
            func leftEdge(_ block: [OCRLine]) -> Double {
                block.map { $0.x - ($0.w ?? 0.2) / 2 }.min() ?? 0
            }
            func areAdjacentLyricRows(_ upper: [OCRLine], _ lower: [OCRLine]) -> Bool {
                let upperHeight = max(blockHeight(upper), 0.001)
                let lowerHeight = max(blockHeight(lower), 0.001)
                let sizeRatio = min(upperHeight, lowerHeight) / max(upperHeight, lowerHeight)
                let verticalGap = abs(centerY(upper) - centerY(lower))
                let typicalHeight = max(upperHeight, lowerHeight)
                guard sizeRatio >= 0.55,
                      verticalGap >= min(upperHeight, lowerHeight) * 0.65,
                      verticalGap <= max(0.12, typicalHeight * 4.2) else { return false }

                // Lyrics often arrive as separate OCR blocks because centered lines
                // have different widths. Accept either a shared center or a shared
                // left edge, but require similar font size and close vertical spacing.
                let centered = abs(centerX(upper) - centerX(lower)) <= 0.12
                let leftAligned = abs(leftEdge(upper) - leftEdge(lower)) <= 0.10
                return centered || leftAligned
            }

            // Filter player/app chrome before looking for lyric rows. Keep short
            // candidate lines temporarily: a one- or two-word verse can be valid
            // when it belongs to a coherent multi-line lyric group.
            let eligible = blocks.filter { block in
                let text = blockText(block)
                let norm = TextSim.norm(text)
                let uiLike = isScreenLingoChromeText(text)
                    || ["copyrawocr", "showoriginaltext", "clearwhentextends",
                        "floatingwindow", "startcapture", "closefloatingwindow",
                        "pausetranslating", "captureconnected", "home settings history",
                        "movie subtitles", "ocrsees"].contains(where: { norm.contains(TextSim.norm($0)) })
                let instructionalUI = isMovieInstructionOrNavigationText(text)
                let likelyTargetLanguage = isLikelyTargetLanguageForMovie(text)
                let passes = !uiLike && !instructionalUI && !likelyTargetLanguage
                    && isUsefulOCRText(text) && !isTargetLanguage(text)
                    && plausiblySource(text)
                if !passes {
                    let reason = uiLike ? "ScreenLingo/player UI" :
                        (instructionalUI ? "instructional/navigation text" :
                        (likelyTargetLanguage ? "likely target-language text" :
                        (!isUsefulOCRText(text) ? "low OCR usefulness" :
                        (isTargetLanguage(text) ? "target-language feedback" :
                        (!plausiblySource(text) ? "source-language mismatch" : "other")))))
                    trace("MOVIE CANDIDATE REJECT", "\(text) | reason=\(reason)")
                }
                return passes
            }

            // Cluster adjacent, similarly sized, aligned text rows. A normal video
            // subtitle remains one candidate; visible song lyrics can be translated
            // as a single batch instead of repeatedly selecting only the bottom row.
            let topToBottom = eligible.sorted { centerY($0) > centerY($1) }
            var clusters: [[[OCRLine]]] = []
            for block in topToBottom {
                if let index = clusters.indices.first(where: { cluster in
                    guard let previous = cluster.last else { return false }
                    return areAdjacentLyricRows(previous, block)
                }) {
                    clusters[index].append(block)
                } else {
                    clusters.append([block])
                }
            }

            let lyricGroups = clusters.filter { group in
                guard group.count >= 2, group.count <= 6,
                      let first = group.first, let last = group.last else { return false }
                return centerY(first) - centerY(last) <= 0.34
            }
            func groupScore(_ group: [[OCRLine]]) -> Double {
                group.reduce(0.0) { $0 + movieScore($1) } + Double(max(0, group.count - 1)) * 12
            }
            let bestGroup = lyricGroups.max { groupScore($0) < groupScore($1) }
            let bestSingle = eligible.max { movieScore($0) < movieScore($1) }
            if let group = bestGroup,
               groupScore(group) >= max(30, (bestSingle.map(movieScore) ?? 0) * 1.1) {
                kept = group.sorted { centerY($0) > centerY($1) }
                trace("MOVIE LYRIC GROUP", "selected \(kept.count) aligned rows | \(kept.map { blockText($0) }.joined(separator: " / "))")
            } else {
                let ranked = eligible.filter { block in
                    let text = blockText(block)
                    let norm = TextSim.norm(text)
                    let words = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
                    let letters = norm.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
                    let isSingleGenericLabel = words.count == 1 && letters < 13
                    let score = movieScore(block)
                    let passesQuality = score >= 20 && !(words.count <= 2 && letters < 10) && !isSingleGenericLabel
                    if !passesQuality {
                        trace("MOVIE CANDIDATE REJECT", "\(text) | score=\(Int(score)); reason=below subtitle quality threshold")
                    } else {
                        trace("MOVIE CANDIDATE ACCEPT", "\(text) | score=\(Int(score)); words=\(words.count); lines=\(block.count)")
                    }
                    return passesQuality
                }.sorted { movieScore($0) > movieScore($1) }
                kept = Array(ranked.prefix(1))
                trace("MOVIE SELECT", kept.first.map { "selected=\(blockText($0)) | score=\(Int(movieScore($0)))" } ?? "no credible subtitle; wait for stable source text")
            }        } else if area == .smart {
            kept = blocks.filter { blockHeight($0) >= maxH * (mode == .comic ? 0.22 : 0.32) }
        }
        // Comic/game mode must not throw away small dialogue bubbles just because
        // they are smaller than a title or a background sign.
        let limit = mode == .comic ? 14 : (mode == .game ? 10 : 6)
        if kept.count > limit {
            kept = Array(kept.sorted { blockWeight($0) > blockWeight($1) }.prefix(limit))
        }
        func top(_ b: [OCRLine]) -> Double { b.map { $0.y + $0.h / 2 }.max() ?? 0 }
        func left(_ b: [OCRLine]) -> Double { b.map { $0.x - ($0.w ?? 0) / 2 }.min() ?? 0 }
        // Build explicit top-to-bottom row bands. A fuzzy pairwise comparator
        // can be non-transitive and accidentally shuffle complete dialogue blocks.
        let byTop = kept.enumerated().sorted {
            let ay = top($0.element), by = top($1.element)
            if abs(ay - by) < 0.000001 { return $0.offset < $1.offset }
            return ay > by
        }.map { $0.element }
        var rows: [[[OCRLine]]] = []
        var anchors: [Double] = []
        for block in byTop {
            let y = top(block)
            let tolerance = max(0.018, min(max(blockHeight(block), 0.018), 0.08) * 0.8)
            if let idx = anchors.indices.first(where: { abs(anchors[$0] - y) <= tolerance }) {
                rows[idx].append(block)
                anchors[idx] = rows[idx].map { top($0) }.reduce(0, +) / Double(rows[idx].count)
            } else {
                rows.append([block])
                anchors.append(y)
            }
        }
        let rightToLeft = mode == .comic && ud.bool(forKey: "rightToLeftReading")
        return rows.flatMap { row in
            row.enumerated().sorted {
                let ax = left($0.element), bx = left($1.element)
                if abs(ax - bx) < 0.000001 { return $0.offset < $1.offset }
                return rightToLeft ? ax > bx : ax < bx
            }.map { $0.element }
        }
    }

    private func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xFF00...0xFFEF).contains(v)
    }

    /// One block's lines joined into running text ("p-" + "pq" → "p-pq").
    private func blockText(_ lines: [OCRLine]) -> String {
        var out = ""
        for l in readingOrder(lines) {
            let t = l.t.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if out.isEmpty { out = t }
            else if out.hasSuffix("-"),
                    let first = t.first,
                    first.isLowercase,
                    !t.hasPrefix("Rem:"),
                    !t.hasPrefix("O-") {
                // Join a hyphenated word only when the continuation looks like the
                // lowercase remainder of that word. OCR can place separate bubbles
                // on adjacent rows (for example "p-" beside "Rem:"); blindly joining
                // them creates the exact cross-speaker word corruption seen in reports.
                out += t
            }
            else if let last = out.last, isCJK(last) { out += t }
            else { out += " " + t }
        }
        return out
    }

    /// Reject obvious setup instructions/navigation text in Movie mode only.
    /// These heuristics deliberately do not affect game or comic OCR.
    private func isMovieInstructionOrNavigationText(_ text: String) -> Bool {
        let n = TextSim.norm(text)
        guard !n.isEmpty else { return false }
        let phrases = [
            "openthevideo", "openvideo", "startoutside", "tapthe", "selectthe",
            "gotosettings", "returnto", "swipeto", "scrollto", "step1", "step2",
            "step3", "step4", "step5", "screenshot", "backtocapture",
            "trythis", "followthesesteps", "20to40sec", "2040sec"
        ]
        if phrases.contains(where: { n.contains($0) }) { return true }
        if text.range(of: #"^\s*[0-9]{1,2}[.)]\s+"#, options: .regularExpression) != nil,
           n.contains("video") || n.contains("sec") || n.contains("step")
            || n.contains("open") || n.contains("screen") || n.contains("capture") {
            return true
        }
        return false
    }

    /// For explicit source/target pairs, reject strong evidence that a Movie-mode
    /// candidate is already in the target language. Short ambiguous dialogue is kept.
    private func isLikelyTargetLanguageForMovie(_ text: String) -> Bool {
        guard mode == .movie, sourceCode != "auto", sourceCode != targetCode,
              text.count >= 10 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let target = Locale.Language(identifier: targetCode).languageCode
        let source = Locale.Language(identifier: sourceCode).languageCode
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        let targetScore = hypotheses.reduce(0.0) {
            $0 + (Locale.Language(identifier: $1.key.rawValue).languageCode == target ? $1.value : 0)
        }
        let sourceScore = hypotheses.reduce(0.0) {
            $0 + (Locale.Language(identifier: $1.key.rawValue).languageCode == source ? $1.value : 0)
        }
        return targetScore >= 0.55 && targetScore > sourceScore * 1.8
    }

    /// Detect our own settings/diagnostics screens using combinations of distinctive UI labels.
    /// Requiring multiple markers avoids rejecting legitimate dialogue containing a common word.
    private func isScreenLingoInterface(_ lines: [OCRLine]) -> Bool {
        let normalizedLines = lines.map { TextSim.norm($0.t) }
        let allText = TextSim.norm(lines.map(\.t).joined(separator: " "))

        // The History screen is composed of repeated Original / Translation / Star
        // cards with a date on each card. Those labels may be fragmented across OCR
        // observations, so they do not necessarily trigger the distinctive settings
        // screen fingerprints below. A repeated card pattern is strong evidence that
        // ReplayKit is capturing ScreenLingo's own History UI, not subtitle dialogue.
        let originalCardLabels = normalizedLines.filter { $0 == "original" }.count
        let translationCardLabels = normalizedLines.filter { $0 == "translation" }.count
        let starCardLabels = normalizedLines.filter { $0 == "star" }.count
        let monthNames = [
            "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november", "december"
        ]
        let datedCards = normalizedLines.filter { line in
            line.range(of: #"[0-9]{4}"#, options: .regularExpression) != nil
                && monthNames.contains(where: { line.contains($0) })
        }.count
        if originalCardLabels >= 2 && translationCardLabels >= 2
            && starCardLabels >= 2 && datedCards >= 2 {
            return true
        }

        let markers = [
            "copyreportforchatgpt", "copycompactreportlast60seconds",
            "exportfulldiagnosticreporttxt", "compactreportsincludeonlythelast60seconds",
            "includerecognizedtextinreports", "refreshlanguageavailability",
            "cleartranslationcache", "cleardiagnosticeventlog", "livediagnostics",
            "processingtrace", "recentdiagnosticevents", "runtranslationtest",
            "translationinput", "currentoriginal", "currenttranslation",
            "showoriginaltext", "clearwhentextends", "floatingwindow",
            "startcapture", "closefloatingwindow", "pausetranslating",
            "captureconnected", "copyrawocr", "ocrsees", "extensionmemoryleft",
            // Settings/diagnostics labels observed in real OCR reports. These are
            // deliberately multi-word fingerprints rather than generic words.
            "languageawareocrcorrection", "selectedblocks", "ocrfiltercounts",
            "acceptedinputs", "waitingforstabilization", "staleresultsdiscarded",
            "translationcachehits", "translationfailures", "outputquality",
            "lasttranslationerror", "currentstatus", "lastrawocrtext",
            "latestcandidatetext", "selectedblocksreadingorder",
            "processingtracelast60seconds", "recentdiagnosticeventslatestfirst"
        ]
        let matchedDistinctive = markers.filter { allText.contains($0) }
        // A diagnostic label is distinctive; on the main screen, require two
        // independent ScreenLingo controls to avoid matching unrelated video dialogue.
        if matchedDistinctive.contains(where: {
            ["copyreportforchatgpt", "livediagnostics", "processingtrace",
             "translationinput", "currentoriginal", "currenttranslation",
             "copyrawocr", "ocrsees", "extensionmemoryleft"].contains($0)
        }) { return true }
        if matchedDistinctive.count >= 2 { return true }

        // The diagnostics screen may not include the app title or version in the
        // current crop. A cluster of diagnostics-only labels is a stronger fingerprint.
        let diagnosticMarkers = [
            "selectedblocks", "ocrfiltercounts", "acceptedinputs",
            "waitingforstabilization", "staleresultsdiscarded",
            "translationcachehits", "translationfailures", "outputquality",
            "lasttranslationerror", "currentstatus", "lastrawocrtext",
            "latestcandidatetext", "translationinput", "currentoriginal",
            "currenttranslation", "processingtracelast60seconds"
        ]
        let diagnosticCount = diagnosticMarkers.filter { allText.contains($0) }.count
        if diagnosticCount >= 3 { return true }

        let navigation = ["home", "languages", "settings", "history"]
            .filter { allText.contains($0) }.count
        let hasAppChrome = allText.contains("screenlingo")
            || allText.contains("changelog")
            || allText.contains("build")
            || allText.contains("version")
        return navigation >= 3 && hasAppChrome
    }

    /// Strong app-owned labels only. Generic words are rejected only when they form
    /// a known control label; this avoids a global ban on words used in real dialogue.
    private func isScreenLingoChromeText(_ text: String) -> Bool {
        let n = TextSim.norm(text)
        guard !n.isEmpty else { return false }
        let exact: Set<String> = [
            "home", "languages", "settings", "history", "screenlingo",
            "translationinput", "currentoriginal", "currenttranslation",
            "processingtrace", "recentdiagnosticevents", "runtranslationtest",
            "refreshlanguageavailability", "cleartranslationcache",
            "cleardiagnosticeventlog", "includerecognizedtextinreports",
            "copyreportforchatgpt", "copycompactreportlast60seconds",
            "exportfulldiagnosticreporttxt", "retranslate", "retryfresh",
            "changelog", "languagesettings", "mode", "copyrawocr",
            "showoriginaltext", "clearwhentextends", "floatingwindow",
            "startcapture", "closefloatingwindow", "pausetranslating",
            "captureconnected", "ocrsees", "extensionmemoryleft",
            "languageawareocrcorrection", "selectedblocks", "ocrfiltercounts",
            "acceptedinputs", "waitingforstabilization", "staleresultsdiscarded",
            "translationcachehits", "translationfailures", "outputquality",
            "lasttranslationerror", "currentstatus", "lastrawocrtext",
            "latestcandidatetext", "selectedblocksreadingorder",
            "processingtracelast60seconds", "recentdiagnosticeventslatestfirst"
        ]
        if exact.contains(n) { return true }
        let phrases = [
            "reportsincludeactualocrsourcedialogueandtranslatedtext",
            "compactreportsincludeonlythelast60seconds",
            "exportthefullertracehistoryasatxtfile",
            "checkbeforesharing", "movie subtitles", "movie/subtitles",
            "recommended balance between text detail",
            "right-to-left manga reading", "text capture area",
            "performance profile", "ocr ms", "translate ms",
            "language-aware ocr correction", "selected blocks / reading order",
            "ocr filter counts", "accepted inputs", "waiting for stabilization",
            "stale results discarded", "translation cache hits",
            "translation failures", "output quality", "last translation error",
            "current status", "last raw ocr text", "latest candidate text",
            "processing trace - last 60 seconds", "recent diagnostic events"
        ]
        return phrases.contains { n.contains(TextSim.norm($0)) }
    }

    /// Reject OCR blocks that are mostly counters, coordinates, timestamps, or visual noise.
    /// Keep short natural fragments such as "Rem:" and "p-" because dialogue is often split.
    private func isUsefulOCRText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let visible = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        let punctuation = text.unicodeScalars.filter {
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
        }.count
        guard letters >= 2, visible > 0 else { return false }
        if digits >= 5 && digits > letters { return false }
        // Preserve short dialogue and stylized speech while rejecting severe OCR noise.
        if visible >= 8 && Double(punctuation) / Double(visible) > 0.48 { return false }

        let normalized = TextSim.norm(trimmed)
        // ReplayKit's privacy sheet is not dialogue. Match phrase combinations, not
        // generic words that may legitimately appear in subtitles.
        let systemOverlayPhrases = [
            "everythingonyourscreenincludingnotifications",
            "enabledonotdisturbtopreventunexpectednotifications"
        ]
        if systemOverlayPhrases.contains(where: { normalized.contains($0) }) { return false }
        return true
    }

    /// With a chosen source language, skips blocks that are clearly written in another language.
    private func plausiblySource(_ text: String) -> Bool {
        guard sourceCode != "auto", text.count >= 8 else { return true }
        let rec = NLLanguageRecognizer()
        rec.processString(text)
        let hyp = rec.languageHypotheses(withMaximum: 3)
        guard let top = hyp.max(by: { $0.value < $1.value }), top.value > 0.8 else { return true }
        let src = Locale.Language(identifier: sourceCode).languageCode
        let ps = hyp.filter { Locale.Language(identifier: $0.key.rawValue).languageCode == src }.map(\.value).max() ?? 0
        return ps > 0.15
    }

    /// Removes lines that are the floating window's own text without suppressing
    /// unrelated subtitles elsewhere on screen.
    private func removeOwnOutput(_ lines: [OCRLine]) -> [OCRLine] {
        var mine: [OCRLine] = []
        var rest: [OCRLine] = []
        for line in lines {
            let normalized = TextSim.norm(line.t)
            if normalized.count >= 3 {
                let outputOverlap = TextSim.containment(of: line.t, in: renderedGrams)
                let sourceOverlap = TextSim.containment(of: line.t, in: sourceGrams)
                let exactOutputFragment = normalized.count >= 8 && renderedNorm.contains(normalized)

                // A source line can share names and short phrases with its translation
                // (for example, "Itadori e Yuta" vs "Itadori and Yuta"). Protect a
                // strong match to the currently displayed original before testing
                // translation overlap, otherwise the PiP feedback filter can delete
                // the first source line and make the selected subtitle oscillate
                // between a complete sentence and its remaining lines.
                let matchesCurrentSource = normalized.count >= 8 && sourceOverlap >= 0.82
                let center = CGPoint(x: line.x, y: line.y)
                let liesInKnownPiPRegion = pipRegions.contains { $0.contains(center) }
                if matchesCurrentSource && (!showOriginal || !liesInKnownPiPRegion) {
                    rest.append(line)
                    continue
                }

                // Common short words can overlap by chance. Require a longer fragment
                // and a stronger score before treating OCR as our own rendered text.
                let fuzzyOutputFragment = normalized.count >= 10 && outputOverlap >= 0.62
                let strongOutputMatch = normalized.count >= 6 && outputOverlap >= 0.78
                let matchesTranslation = exactOutputFragment || fuzzyOutputFragment || strongOutputMatch
                let matchesDisplayedOriginal = showOriginal && matchesCurrentSource && liesInKnownPiPRegion
                if matchesTranslation || matchesDisplayedOriginal {
                    mine.append(line)
                    continue
                }
            }
            rest.append(line)
        }

        if !mine.isEmpty {
            // Cluster matching lines spatially; never create one screen-sized rectangle
            // from matches that happen to occur in different subtitle bubbles.
            var clusters: [[OCRLine]] = []
            for line in mine {
                if let index = clusters.firstIndex(where: { cluster in
                    cluster.contains { abs($0.x - line.x) <= 0.26 && abs($0.y - line.y) <= 0.16 }
                }) {
                    clusters[index].append(line)
                } else {
                    clusters.append([line])
                }
            }
            pipRegions = clusters.map { cluster in
                var region = CGRect.null
                for line in cluster {
                    let width = max(0.02, min(line.w ?? 0.25, 0.8))
                    region = region.union(CGRect(x: line.x - width / 2, y: line.y - line.h / 2,
                                                 width: width, height: max(line.h, 0.015)))
                }
                return region.insetBy(dx: -0.025, dy: showOriginal ? -0.09 : -0.035)
            }
            pipRegionStamp = Date()
        }

        // Do not suppress OCR solely because it falls inside a remembered PiP rectangle.
        // The overlay can overlap genuine source dialogue, and OCR boxes can be taller/wider
        // than the actual glyphs. Remove only lines with a textual match to rendered output
        // above; target-language filtering is the secondary guard against remaining feedback.
        if Date().timeIntervalSince(pipRegionStamp) >= 8 {
            pipRegions.removeAll()
        }
        return rest
    }

    /// Removes near-identical OCR observations only when their boxes overlap spatially.
    /// Identical dialogue at a separate position is kept here so Movie candidate ranking
    /// can compare both regions and select one; games/comics do not use this extra filter.
    private func dedupeOCRLines(_ lines: [OCRLine]) -> [OCRLine] {
        var kept: [OCRLine] = []
        for line in lines {
            let n = TextSim.norm(line.t)
            guard !n.isEmpty else { continue }
            let duplicate = kept.firstIndex { existing in
                let en = TextSim.norm(existing.t)
                guard !en.isEmpty, TextSim.similar(n, en, 0.86) else { return false }
                let w1 = max(existing.w ?? 0.08, 0.01)
                let w2 = max(line.w ?? 0.08, 0.01)
                let xOverlap = min(existing.x + w1 / 2, line.x + w2 / 2)
                    - max(existing.x - w1 / 2, line.x - w2 / 2)
                let yOverlap = min(existing.y + existing.h / 2, line.y + line.h / 2)
                    - max(existing.y - existing.h / 2, line.y - line.h / 2)
                let overlapX = xOverlap / max(0.01, min(w1, w2))
                let overlapY = yOverlap / max(0.01, min(existing.h, line.h))
                return overlapX >= 0.45 && overlapY >= 0.25
            }
            if let duplicate {
                let old = kept[duplicate]
                let oldQuality = old.t.count + Int((old.w ?? 0) * 20)
                let newQuality = line.t.count + Int((line.w ?? 0) * 20)
                if newQuality > oldQuality { kept[duplicate] = line }
            } else {
                kept.append(line)
            }
        }
        return kept
    }

    private func dedupe(_ lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines {
            let normalized = TextSim.norm(line)
            guard !normalized.isEmpty else { continue }
            let duplicateIndex = out.firstIndex { existing in
                let existingNorm = TextSim.norm(existing)
                guard !existingNorm.isEmpty else { return false }
                let shortCount = min(normalized.count, existingNorm.count)
                let longCount = max(normalized.count, existingNorm.count)
                let containment = Double(shortCount) / Double(max(1, longCount))
                return TextSim.similar(line, existing, 0.78)
                    || (shortCount >= 8 && containment >= 0.78
                        && (normalized.contains(existingNorm) || existingNorm.contains(normalized)))
            }
            if let duplicateIndex {
                if line.count > out[duplicateIndex].count { out[duplicateIndex] = line }
            } else {
                out.append(line)
            }
        }
        return out
    }

    private func enqueue(_ blocks: [String]) {
        let joined = blocks.joined(separator: "\n")
        guard joined != lastHandled else { return }
        // Ignore small OCR jitter without changing the accepted baseline. Updating
        // lastHandled for a rejected candidate can make later real changes look stale.
        if TextSim.similar(joined, lastHandled, 0.92) { return }
        lastHandled = joined
        queued = blocks
        if !busy { Task { await drain() } }
    }

    private func handleClear() {
        guard autoClear, showing else { return }
        delayedClearWork?.cancel()
        let delay = textHoldDuration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.showing else { return }
            self.showing = false
            self.lastHandled = ""
            self.original = ""
            self.translated = ""
            self.renderedGrams = self.placeholderGrams
            self.renderedNorm = TextSim.norm("Waiting for screen text… Listening…")
            self.sourceGrams = []
            self.pip.render(original: "", translated: "Listening…", showOriginal: false)
            self.recordDiagnostic("Cleared vanished text after " + String(format: "%.1f", delay) + " seconds")
        }
        delayedClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Re-run translation on the most recently recognized text without restarting capture.
    func retranslateLast() {
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Nothing to re-translate yet"
            return
        }
        lastHandled = ""
        enqueue([original])
    }

    /// Retranslate the latest source text after evicting cached model output.
    func retranslateLastFresh() {
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Nothing to retry yet"
            return
        }
        let count = cache.count
        cache.removeAll()
        lastHandled = ""
        status = "Retrying without cached output (cleared \(count) entries)…"
        enqueue([original])
    }

    /// Clear cached translations when diagnosing a suspicious or stale result.
    func clearTranslationCache() {
        let count = cache.count
        cache.removeAll()
        status = "Translation cache cleared (\(count) entries)"
    }

    /// Clear the current floating-window result while keeping screen capture running.
    func clearCurrentTranslation() {
        showing = false
        lastHandled = ""
        original = ""
        translated = ""
        renderedGrams = placeholderGrams
        renderedNorm = TextSim.norm("Waiting for screen text… Listening…")
        sourceGrams = []
        pip.render(original: "", translated: "Listening…", showOriginal: false)
        status = "Output cleared — capture is still running"
    }

    /// Reject text that is probably already in the requested output language.
    /// This must be deliberately more sensitive than source-language detection:
    /// the PiP overlay is English in a Portuguese→English session, and letting even
    /// one overlay block through creates a feedback loop where the translation is
    /// repeatedly translated as if it were source dialogue.
    private func isTargetLanguage(_ s: String) -> Bool {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Very short fragments are too ambiguous to classify safely.
        guard text.count >= 12 else { return false }
        let target = Locale.Language(identifier: targetCode).languageCode
        guard let target else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        let targetProbability = hypotheses.reduce(0.0) { partial, item in
            partial + (Locale.Language(identifier: item.key.rawValue).languageCode == target ? item.value : 0)
        }
        let strongestNonTarget = hypotheses
            .filter { Locale.Language(identifier: $0.key.rawValue).languageCode != target }
            .map(\.value)
            .max() ?? 0

        // With a manually selected source language, compare the detector's evidence
        // against that source too. The old 0.58 threshold missed the reported case:
        // English led at 0.36 while Portuguese was not a credible hypothesis, so the
        // English instruction passed filtering and was sent to Portuguese → English.
        let source = Locale.Language(identifier: sourceCode).languageCode
        let sourceProbability = hypotheses.reduce(0.0) { partial, item in
            partial + (Locale.Language(identifier: item.key.rawValue).languageCode == source ? item.value : 0)
        }
        let sourceIsExplicitAndDifferent = sourceCode != "auto" && source != target
        let targetLeadsClearly = targetProbability >= strongestNonTarget * 1.5
        let contradictsChosenSource = !sourceIsExplicitAndDifferent || sourceProbability < targetProbability * 0.60

        guard targetProbability >= 0.32,
              targetLeadsClearly,
              contradictsChosenSource else { return false }
        trace("LANGUAGE FILTER EVIDENCE",
              "classify as target-language feedback; target=\(targetCode) score=\(String(format: "%.2f", targetProbability)); source=\(sourceCode) score=\(String(format: "%.2f", sourceProbability)); text=\(text)")
        return true
    }

    private func drain() async {
        busy = true
        defer { busy = false }
        // Keep rapid subtitle changes readable without processing stale intermediate text.
        while queued != nil {
            let minimum = max(0, min(4, ud.object(forKey: "minDisplay") as? Double ?? 0))
            let wait = minimum - Date().timeIntervalSince(lastShowDate)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let latest = queued else { break }
            queued = nil
            await process(latest)
        }
    }

    // MARK: Translation
    private func detectSource(_ text: String) -> Locale.Language? {
        if sourceCode != "auto" { return Locale.Language(identifier: sourceCode) }
        let rec = NLLanguageRecognizer()
        rec.processString(text)
        let hypotheses = rec.languageHypotheses(withMaximum: 5)
        let useLock = (UserDefaults.standard.object(forKey: "langLock") as? Bool) ?? true
        if useLock, let lockedLang {
            let probability = hypotheses[NLLanguage(rawValue: lockedLang)] ?? 0
            if probability > 0.10 || text.count < 12 {
                languageMismatchCount = 0
                return Locale.Language(identifier: lockedLang)
            }
            languageMismatchCount += 1
            if languageMismatchCount >= 3 {
                self.lockedLang = nil
                languageDetectionHistory.removeAll()
                languageMismatchCount = 0
                recordDiagnostic("Automatic language lock released after repeated contradictory evidence")
            } else {
                return Locale.Language(identifier: lockedLang)
            }
        }
        // Prefer an installed language pack only when the model's evidence is ambiguous.
        let installed = Set(languages.filter { langStatus[$0.code] == .installed }.map {
            $0.code == "zh" ? NLLanguage.simplifiedChinese : NLLanguage(rawValue: $0.code)
        })
        var dominant = rec.dominantLanguage
        if let best = hypotheses.filter({ installed.contains($0.key) }).max(by: { $0.value < $1.value }),
           best.value > 0.15 {
            dominant = best.key
        }
        guard let detected = dominant else { return nil }
        if useLock {
            let code = Locale.Language(identifier: detected.rawValue).minimalIdentifier
            languageDetectionHistory.append(code)
            if languageDetectionHistory.count > 6 { languageDetectionHistory.removeFirst() }
            if languageDetectionHistory.count >= 4,
               let winner = Dictionary(grouping: languageDetectionHistory, by: { $0 })
                    .max(by: { $0.value.count < $1.value.count }),
               winner.value.count >= 4 {
                lockedLang = winner.key
                recordDiagnostic("Automatic language locked to \(winner.key)")
            }
        }
        return Locale.Language(identifier: detected.rawValue)
    }

    private func pairStatus(_ src: Locale.Language, _ target: Locale.Language) async -> LanguageAvailability.Status {
        if sourceCode != "auto", let s = langStatus[sourceCode] { return s }
        return await LanguageAvailability().status(from: src, to: target)
    }

    /// Splits a block into sentences so each is translated on its own (better quality, cacheable).
    private func splitSentences(_ text: String) -> [String] {
        guard text.count > 160 else { return [text] }
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        var out: [String] = []
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let s = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return true }
            if s.count < 4, let last = out.popLast() { out.append(last + " " + s) } else { out.append(s) }
            return true
        }
        return out.isEmpty ? [text] : out
    }

    private func process(_ rawBlocks: [String]) async {
        let t0 = Date()
        // Normalize common OCR substitutions before language scoring and translation.
        // Keep raw OCR available in diagnostics; cleaned text is used only for translation.
        let blocks = rawBlocks
        lastTranslationError = "None"
        lastTranslationInput = blocks.joined(separator: "\n")
        trace("OCR CLEANUP", "raw=\(rawBlocks.joined(separator: " | "))")
        trace("OCR CLEANUP", "cleanup is applied per block according to the Clean up OCR mistakes setting")
        trace("TRANSLATION START", "\(blocks.count) block(s); target=\(targetCode); input:\n" + blocks.enumerated().map { "#\($0.offset + 1) \($0.element)" }.joined(separator: "\n"))
        let target = Locale.Language(identifier: targetCode)

        var sentences: [[String]] = []          // per block
        var done: [[String?]] = []              // translated sentence, nil = still to translate
        var pending: [String: [(block: Int, index: Int, text: String)]] = [:]
        var srcLangs: [String: Locale.Language] = [:]
        var translatedAny = false

        let cleanOCR = (UserDefaults.standard.object(forKey: "cleanOCR") as? Bool) ?? true
        let expandSlang = (UserDefaults.standard.object(forKey: "slang") as? Bool) ?? true
        let detectSpeakers = (UserDefaults.standard.object(forKey: "speakerDetect") as? Bool) ?? true
        let neverWords = (UserDefaults.standard.string(forKey: "neverTranslate") ?? "")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let sourceFixes = (UserDefaults.standard.string(forKey: "sourceFixes") ?? "")
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { return nil }
                let from = pair[0].trimmingCharacters(in: .whitespaces)
                let to = pair[1].trimmingCharacters(in: .whitespaces)
                return from.isEmpty ? nil : (from, to)
            }
        let glossary = (UserDefaults.standard.string(forKey: "glossary") ?? "")
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { return nil }
                let from = pair[0].trimmingCharacters(in: .whitespaces)
                let to = pair[1].trimmingCharacters(in: .whitespaces)
                return from.isEmpty ? nil : (from, to)
            }

        var protectedTokens: [[(String, String)]] = []
        for (bi, rawText) in blocks.enumerated() {
            var text = cleanOCR ? TextIntel.cleanOCR(rawText) : rawText
            for (from, to) in sourceFixes {
                text = text.replacingOccurrences(of: from, with: to, options: [.caseInsensitive])
            }
            // Evaluate the OCR text independently even when the user selected a
            // source language. detectSource() intentionally honors that setting,
            // so using its return value as detector evidence would simply repeat
            // the configured language and fail to catch English mistakenly sent as pt.
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
            let sourceEvidence = hypotheses.reduce(0.0) { score, item in
                score + (Locale.Language(identifier: item.key.rawValue).languageCode
                         == Locale.Language(identifier: sourceCode).languageCode ? item.value : 0)
            }
            let targetEvidence = hypotheses.reduce(0.0) { score, item in
                score + (Locale.Language(identifier: item.key.rawValue).languageCode
                         == target.languageCode ? item.value : 0)
            }
            let evidenceSummary = hypotheses.sorted { $0.value > $1.value }.map {
                "\(Locale.Language(identifier: $0.key.rawValue).languageCode?.identifier ?? $0.key.rawValue)=\(String(format: "%.2f", $0.value))"
            }.joined(separator: ", ")
            trace("SOURCE DETECTION EVIDENCE",
                  "Block #\(bi + 1); setting=\(sourceCode); target=\(targetCode); sourceScore=\(String(format: "%.2f", sourceEvidence)); targetScore=\(String(format: "%.2f", targetEvidence)); hypotheses=[\(evidenceSummary)]; text=\(text)")

            // The configured source language must not override clear evidence that
            // OCR captured text already in the target language. Short fragments remain
            // ambiguous, so only apply this guard to sufficiently informative text.
            if sourceCode != "auto", sourceCode != targetCode, text.count >= 12,
               targetEvidence >= 0.32, targetEvidence >= sourceEvidence * 1.5 {
                trace("SOURCE DETECTION REJECT",
                      "target language is more likely than configured source; not sending this block through translation: \(text)")
                sentences.append([text])
                done.append([text])
                protectedTokens.append([])
                continue
            }

            guard let src = detectSource(text), src.languageCode != target.languageCode else {
                sentences.append([text]); done.append([text]); protectedTokens.append([]); continue
            }
            let id = src.minimalIdentifier
            lastDetectedLanguage = Locale.current.localizedString(forIdentifier: id) ?? id
            srcLangs[id] = src
            trace("SOURCE DETECTION", "Block #\(bi + 1) source=\(id), target=\(targetCode); text=\(text)")

            if expandSlang {
                text = TextIntel.expandSlang(text, lang: src.languageCode?.identifier ?? id)
            }
            let dialogue = detectSpeakers ? TextIntel.splitDialogue(text) : [(label: String?.none, text: text)]
            // Keep separate speakers on separate lines and protect their labels so
            // the translator cannot rename, translate, or merge them into dialogue.
            let labels = dialogue.compactMap { $0.label }
            let dialogueText = dialogue.map { segment in
                segment.label.map { "\($0): \(segment.text)" } ?? segment.text
            }.joined(separator: "\n")
            // Protect user-specified terms and speaker labels, then restore exact spelling.
            let protected = TextIntel.protect(dialogueText, words: Array((neverWords + labels).prefix(20)))
            protectedTokens.append(protected.tokens)
            text = protected.text
            // Do not split ordinary multi-sentence dialogue into isolated fragments.
            // Short fragments lose grammatical context and can be translated in the
            // wrong order. Only split unusually long OCR dumps to keep requests bounded.
            let parts = text.count <= 900 ? [text] : splitSentences(text)
            sentences.append(parts)
            var row: [String?] = []
            for (si, part) in parts.enumerated() {
                if protected.tokens.isEmpty, let hit = cache["\(id)>\(targetCode)|\(part)"] {
                    row.append(hit); translatedAny = true; cacheHits += 1
                    trace("CACHE HIT", "Block #\(bi + 1) part #\(si + 1): \(part) → \(hit)")
                } else {
                    row.append(nil)
                    pending[id, default: []].append((bi, si, part))
                    trace("CACHE MISS", "Block #\(bi + 1) part #\(si + 1) queued for Apple Translation; \(id) → \(targetCode); text=\(part)")
                }
            }
            done.append(row)
        }

        var failed = false
        for (id, items) in pending {
            guard let src = srcLangs[id] else { continue }
            let availability = await pairStatus(src, target)
            if availability == .unsupported { status = "\(id) → \(targetCode) isn't supported"; failed = true; continue }
            if availability == .supported { status = "Language pack missing – open the Languages tab" }
            var out = await translateBatch(items.map { $0.text }, source: src, target: target,
                                           installed: availability == .installed)
            if out == nil || out?.count != items.count {
                // Claude's main branch has a useful resilience improvement: one bad
                // sentence should not make an otherwise valid batch disappear.
                // Retry each item independently before reporting a translation failure.
                trace("BATCH RETRY", "batch failed for \(id) → \(targetCode); retrying \(items.count) item(s) individually")
                var recovered = [String?](repeating: nil, count: items.count)
                for (index, item) in items.enumerated() {
                    if let single = await translateBatch([item.text], source: src, target: target,
                                                          installed: availability == .installed),
                       single.count == 1,
                       !single[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        recovered[index] = single[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                if recovered.allSatisfy({ $0 != nil }) {
                    out = recovered.compactMap { $0 }
                    trace("BATCH RETRY", "individual retry recovered all \(items.count) item(s)")
                } else {
                    failed = true
                    translationFailures += 1
                    lastTranslationError = "Translation batch and individual retry failed for \(id) → \(targetCode)"
                    trace("TRANSLATION FAILURE", lastTranslationError)
                    continue
                }
            }
            guard let results = out, results.count == items.count else {
                failed = true
                translationFailures += 1
                lastTranslationError = "Translation returned incomplete results for \(id) → \(targetCode)"
                continue
            }
            translatedAny = true
            for (k, it) in items.enumerated() {
                let result = results[k].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !result.isEmpty else {
                    failed = true
                    translationFailures += 1
                    lastTranslationError = "Empty translation result for \(id) → \(targetCode)"
                    continue
                }
                // Never cache an unchanged response when language evidence says the
                // OCR text is already in the target language. That is a detection
                // problem, not a valid translation to persist and replay.
                if TextSim.norm(result) == TextSim.norm(it.text), isTargetLanguage(it.text) {
                    failed = true
                    lastTranslationError = "Unchanged target-language text was returned as a translation"
                    trace("SUSPICIOUS RESULT", "\(it.text) was returned unchanged; skipped cache write")
                    continue
                }
                done[it.block][it.index] = result
                // Cached placeholder-based translations can restore the wrong
                // speaker/name if a later block uses the same placeholder token.
                if it.block < protectedTokens.count, protectedTokens[it.block].isEmpty {
                    cache["\(id)>\(targetCode)|\(it.text)"] = result
                }
                trace("TRANSLATION RESULT", "Block #\(it.block + 1) part #\(it.index + 1); \(id) → \(targetCode); source=\(it.text); output=\(result)")
            }
        }
        if cache.count > 600 { cache.removeAll() }

        guard translatedAny else {
            if failed && lastTranslationError == "None" { lastTranslationError = "No translated output returned" }
            status = failed ? "Translation failed – check diagnostics and language packs"
                            : "Text is already in the target language"
            return
        }
        // Never silently present source-language fragments as if they were translated.
        // If one required batch fails, a mixed original/translated output is more
        // misleading than keeping the last known-good translation on screen.
        if failed {
            status = "Translation incomplete — keeping previous result. Retry or check language packs."
            return
        }
        var outBlocks: [String] = []
        for (bi, row) in done.enumerated() {
            var parts: [String] = []
            for (si, v) in row.enumerated() { parts.append(v ?? sentences[bi][si]) }
            var restored = TextIntel.restore(parts.joined(separator: " "), tokens: bi < protectedTokens.count ? protectedTokens[bi] : [])
            for (from, to) in glossary {
                restored = restored.replacingOccurrences(of: from, with: to, options: [.caseInsensitive])
            }
            outBlocks.append(restored)
        }
        translateMs = Date().timeIntervalSince(t0) * 1000
        let finalOutput = outBlocks.joined(separator: "\n")

        // Translation is asynchronous. While a request is awaiting Apple's translation
        // framework, newer video frames can enqueue a different subtitle. Never let the
        // older request overwrite the newer scene (the visible rapid "correct → wrong"
        // oscillation). Only publish results that still match the latest accepted OCR.
        let processedInput = blocks.joined(separator: "\n")
        guard lastHandled == processedInput else {
            discardedStaleCount += 1
            recordDiagnostic("Discarded stale translation result")
            status = "Discarded stale translation — newer screen text is being processed"
            return
        }

        lastOutputQuality = Self.outputQuality(source: processedInput, output: finalOutput)
        capturePhase = "Translation complete"
        recordDiagnostic("Translation complete: \(processedInput.count) source chars, \(finalOutput.count) output chars")
        trace("PUBLISHED OUTPUT", "quality=\(lastOutputQuality); output:\n\(finalOutput)")
        status = "\(srcLangs.keys.sorted().joined(separator: "+")) → \(targetCode) ✓"
        show(processedInput, finalOutput)
    }

    /// Translates many sentences in one call.
    private func translateBatch(_ texts: [String], source: Locale.Language, target: Locale.Language,
                                installed: Bool) async -> [String]? {
        if #available(iOS 26.0, *), installed {
            let k = "\(source.minimalIdentifier)>\(targetCode)"
            if directSession == nil || directKey != k {
                directSession = TranslationSession(installedSource: source, target: target)
                directKey = k
            }
            guard let session = directSession else { return nil }
            let r = await runBatch(session, texts)
            if r == nil { directSession = nil }
            return r
        }
        return await translateLegacy(texts, source: source, target: target)
    }

    private func runBatch(_ session: TranslationSession, _ texts: [String]) async -> [String]? {
        guard !texts.isEmpty else { return [] }
        let reqs = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        guard let res = try? await session.translations(from: reqs), res.count == texts.count else { return nil }
        var out = [String?](repeating: nil, count: texts.count)
        for result in res {
            guard let id = result.clientIdentifier, let index = Int(id),
                  out.indices.contains(index), out[index] == nil else { return nil }
            let translated = result.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else { return nil }
            out[index] = translated
        }
        // Do not let a missing/duplicate client identifier shift or scramble results.
        guard out.allSatisfy({ $0 != nil }) else { return nil }
        return out.compactMap { $0 }
    }

    /// Conservative warning signal for clearly truncated or empty outputs.
    /// This is diagnostic only: translated word order legitimately differs by language.
    private static func outputQuality(source: String, output: String) -> String {
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let dst = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, !dst.isEmpty else { return "Suspicious: empty text" }
        let srcWords = src.split(whereSeparator: { $0.isWhitespace }).count
        let dstWords = dst.split(whereSeparator: { $0.isWhitespace }).count
        if dst.count < 3 { return "Suspicious: very short output" }
        if srcWords >= 6 && dstWords <= 2 { return "Review: output may be truncated" }
        if dst.count > max(1200, src.count * 8) { return "Review: output unusually long" }
        return "No obvious truncation detected"
    }

    private func show(_ text: String, _ result: String) {
        // Final guard immediately before changing the UI/history. OCR can still produce
        // a truncated source after earlier stabilization (for example, if its wording
        // differs just enough to pass the first filter). Keep the complete current line
        // when a fresh candidate is only its ending fragment.
        let currentNorm = TextSim.norm(original)
        let incomingNorm = TextSim.norm(text)
        let currentIsFresh = showing && Date().timeIntervalSince(lastShowDate) < 2.0
        let incomingLooksTruncated = currentNorm.count >= incomingNorm.count + 8
            && incomingNorm.count >= 8
            && Double(incomingNorm.count) / Double(max(1, currentNorm.count)) < 0.82
            && currentNorm.contains(incomingNorm)
        if currentIsFresh && incomingLooksTruncated {
            trace("DISPLAY STABILIZATION", "Prevented truncated source from replacing display/history (current=\(currentNorm.count) chars, incoming=\(incomingNorm.count) chars)")
            recordDiagnostic("Kept current translation; incoming OCR looked like a truncated ending fragment")
            return
        }

        delayedClearWork?.cancel()
        delayedClearWork = nil
        original = text
        translated = result
        showing = true
        lastShowDate = Date()
        if history.first?.original != text {
            history.insert(HistoryItem(original: text, translated: result), at: 0)
            if history.count > 100 { history.removeLast() }
            if speakEnabled { speak(result) }
            if (ud.object(forKey: "haptics") as? Bool) ?? false {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
        renderedGrams = TextSim.grams(result).union(placeholderGrams)
        renderedNorm = TextSim.norm(result) + TextSim.norm("Waiting for screen text… Listening…")
        sourceGrams = TextSim.grams(text)
        pip.setSize(windowSize.size)
        pip.style = pipStyle
        pip.render(original: text, translated: result, showOriginal: showOriginal)
    }

    private func speak(_ s: String) {
        let voices = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "pt": "pt-BR", "en": "en-US", "es": "es-ES",
                      "fr": "fr-FR", "de": "de-DE", "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR", "ru": "ru-RU",
                      "ar": "ar-SA", "tr": "tr-TR", "hi": "hi-IN", "id": "id-ID", "nl": "nl-NL", "pl": "pl-PL",
                      "th": "th-TH", "vi": "vi-VN", "uk": "uk-UA"]
        speech.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: s)
        u.voice = AVSpeechSynthesisVoice(language: voices[targetCode] ?? targetCode)
        speech.speak(u)
    }

    // iOS 18 path (needs the hosted .translationTask view in RootView)
    private func translateLegacy(_ texts: [String], source: Locale.Language, target: Locale.Language) async -> [String]? {
        let requestID = UUID()
        return await withCheckedContinuation { (cont: CheckedContinuation<[String]?, Never>) in
            legacyRequestID = requestID
            legacyContinuation = cont
            pendingTexts = texts
            if var c = legacyConfig, c.source == source, c.target == target {
                c.invalidate(); legacyConfig = c
            } else {
                legacyConfig = .init(source: source, target: target)
            }
            Task {
                try? await Task.sleep(for: .seconds(10))
                guard self.legacyRequestID == requestID else { return }
                self.finishLegacy(nil)
            }
        }
    }
    func runLegacy(_ session: TranslationSession) async {
        finishLegacy(await runBatch(session, pendingTexts))
    }
    private func finishLegacy(_ r: [String]?) {
        guard let continuation = legacyContinuation else { return }
        legacyContinuation = nil
        legacyRequestID = UUID()
        continuation.resume(returning: r)
    }

    // MARK: Languages / downloads
    func loadLanguages() async {
        let supported = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        var items: [LangItem] = []
        for l in supported {
            let code = l.minimalIdentifier
            guard seen.insert(code).inserted else { continue }
            items.append(LangItem(code: code, name: Locale.current.localizedString(forIdentifier: code) ?? code))
        }
        if !items.isEmpty { languages = items.sorted { $0.name < $1.name } }
        await refreshStatus()
    }

    func refreshStatus() async {
        let target = Locale.Language(identifier: targetCode)
        let av = LanguageAvailability()
        var out: [String: LanguageAvailability.Status] = [:]
        for l in languages {
            out[l.code] = await av.status(from: Locale.Language(identifier: l.code), to: target)
        }
        langStatus = out
    }

    func download(_ code: String) {
        let src = Locale.Language(identifier: code)
        let tgt = Locale.Language(identifier: targetCode)
        if var c = downloadConfig, c.source == src, c.target == tgt {
            c.invalidate(); downloadConfig = c
        } else {
            downloadConfig = .init(source: src, target: tgt)
        }
    }
    func runDownload(_ session: TranslationSession) async {
        try? await session.prepareTranslation()
        await refreshStatus()
    }

    // MARK: Test
    func runTest() {
        let samples = ["en": "Hello, how are you today?", "pt": "Olá, como você está hoje?",
                       "es": "Hola, ¿cómo estás hoy?", "fr": "Bonjour, comment allez-vous aujourd'hui ?",
                       "de": "Hallo, wie geht es dir heute?", "it": "Ciao, come stai oggi?",
                       "ja": "こんにちは、今日はお元気ですか？", "ko": "안녕하세요, 오늘 어떠세요?",
                       "zh": "你好，你今天好吗？", "ru": "Привет, как дела сегодня?"]
        var key = Locale.Language(identifier: sourceCode == "auto" ? "en" : sourceCode).languageCode?.identifier ?? "en"
        if key == (Locale.Language(identifier: targetCode).languageCode?.identifier ?? "") { key = "es" }
        lastHandled = ""
        status = "Testing…"
        enqueue([samples[key] ?? samples["en"]!])
    }

    static let fallbackLanguages: [LangItem] = [
        ("en","English"),("es","Spanish"),("fr","French"),("de","German"),("it","Italian"),
        ("pt","Portuguese"),("ru","Russian"),("ja","Japanese"),("ko","Korean"),
        ("zh-Hans","Chinese (Simplified)"),("zh-Hant","Chinese (Traditional)"),("ar","Arabic"),
        ("tr","Turkish"),("hi","Hindi"),("id","Indonesian"),("nl","Dutch"),("pl","Polish"),
        ("th","Thai"),("vi","Vietnamese"),("uk","Ukrainian")
    ].map { LangItem(code: $0.0, name: $0.1) }
}

// MARK: - Loopback server (extension ⇄ app, UDP on 127.0.0.1)
final class LoopbackServer {
    private var listener: NWListener?
    private var peer: NWConnection?
    private let queue = DispatchQueue(label: "loopback.server")
    var onPacket: ((Packet) -> Void)?
    var onState: ((Bool) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private var retryWork: DispatchWorkItem?
    private var isStopping = false
    private var retryCount = 0
    private var startInProgress = false

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    private func startOnQueue() {
        // TranslatorEngine.init() and scenePhase=.active can both request startup.
        // Never bind a second listener while the existing one is starting or alive:
        // cancelling and immediately rebinding the same UDP port can produce EADDRINUSE.
        guard listener == nil, !startInProgress else {
            onDiagnostic?("Duplicate listener start ignored; listener already exists or is starting")
            return
        }
        startInProgress = true
        retryWork?.cancel()
        retryWork = nil

        guard let port = NWEndpoint.Port(rawValue: Loopback.port) else {
            onState?(false)
            onDiagnostic?("Invalid UDP port: \(Loopback.port)")
            scheduleRetry()
            return
        }
        do {
            let l = try NWListener(using: .udp, on: port)
            l.newConnectionHandler = { [weak self] c in
                guard let self else { return }
                c.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    if case .failed(let error) = state {
                        self.onDiagnostic?("UDP peer failed: \(error)")
                    }
                }
                c.start(queue: self.queue)
                self.peer?.cancel()
                self.peer = c
                self.onDiagnostic?("UDP peer accepted")
                self.receive(on: c)
            }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.retryCount = 0
                    self.onState?(true)
                    self.onDiagnostic?("UDP listener ready on port \(port.rawValue)")
                case .failed(let error):
                    self.onState?(false)
                    self.onDiagnostic?("UDP listener failed: \(error)")
                    self.listener = nil
                    self.startInProgress = false
                    self.scheduleRetry()
                case .cancelled:
                    if !self.isStopping {
                        self.listener = nil
                        self.startInProgress = false
                        self.onState?(false)
                        self.onDiagnostic?("UDP listener cancelled unexpectedly")
                        self.scheduleRetry()
                    }
                case .waiting(let error):
                    self.onDiagnostic?("UDP listener waiting: \(error)")
                default:
                    break
                }
            }
            listener = l
            l.start(queue: queue)
            startInProgress = false
            onDiagnostic?("UDP listener start requested on port \(port.rawValue)")
        } catch {
            startInProgress = false
            onState?(false)
            onDiagnostic?("Could not create UDP listener on port \(port.rawValue): \(error)")
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard retryWork == nil else { return }
        retryCount += 1
        let delay = min(15.0, pow(2.0, Double(min(retryCount - 1, 4))))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWork = nil
            self.startOnQueue()
        }
        retryWork = work
        onDiagnostic?("UDP listener retry \(retryCount) scheduled in \(Int(delay))s")
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.retryWork?.cancel()
            self.retryWork = nil
            self.isStopping = true
            self.retryWork?.cancel()
            self.retryWork = nil
            self.listener?.stateUpdateHandler = nil
            self.listener?.cancel()
            self.listener = nil
            self.peer?.cancel()
            self.peer = nil
            self.startInProgress = false
            self.isStopping = false
            self.onState?(false)
            self.onDiagnostic?("UDP listener stopped by app")
        }
    }

    /// Sends settings back to the capture extension.
    func send(_ cfg: Config) {
        guard let data = try? JSONEncoder().encode(cfg) else { return }
        queue.async { [weak self] in
            self?.peer?.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            if let data, let p = try? JSONDecoder().decode(Packet.self, from: data) {
                DispatchQueue.main.async { self?.onPacket?(p) }
            }
            if error == nil { self?.receive(on: c) }
        }
    }
}
