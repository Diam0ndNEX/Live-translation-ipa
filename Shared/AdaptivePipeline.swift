import Foundation

struct RecognitionFeedback {
    var confidence = 0.0
    var textHeight = 0.0
    var processingMs = 0.0
    var failures = 0
    var unchangedSeconds = 0.0
    var motion = 0.0
}
struct RecognitionPlan {
    let edge: Double
    let interval: Double
    let reason: String
}
enum AdaptiveRecognition {
    static func plan(baseEdge: Double, interval: Double, enabled: Bool, cool: Bool,
                     pressure: Bool, feedback f: RecognitionFeedback, ceiling: Double = 2400) -> RecognitionPlan {
        var edge = baseEdge, cadence = interval, reason = "fixed preset"
        if enabled {
            if f.failures >= 2 || (f.confidence > 0 && f.confidence < 0.75) || (f.textHeight > 0 && f.textHeight < 0.022) {
                edge = max(baseEdge, 2000); reason = "small or uncertain text"
            } else if f.confidence >= 0.94 && f.textHeight >= 0.035 {
                edge = min(baseEdge, 1000); reason = "large clear text"
            } else { reason = "balanced detail" }
            if f.unchangedSeconds > 3 { cadence = max(cadence, 0.4); reason += "; unchanged" }
            if f.motion > 8 && f.unchangedSeconds < 1 { cadence = min(cadence, 0.22) }
        }
        if cool || pressure {
            // Reduce frequency before image detail; small text keeps its recognition resolution.
            cadence = max(cadence, max(cool ? 0.32 : 0.22, f.processingMs / 1000 * (cool ? 2.2 : 1.5)))
            if f.unchangedSeconds > 3 || f.failures >= 4 { cadence = max(cadence, cool ? 0.8 : 0.5) }
            reason += cool ? "; cool controller" : "; queue/thermal pressure"
        }
        return RecognitionPlan(edge: min(ceiling.isFinite ? max(320, ceiling) : 2400, min(2400, max(800, edge))), interval: min(1.5, max(0.1, cadence)), reason: reason)
    }
}

/// Tracks a whole visible subtitle/lyric group, preserving every row and its spatial identity.
struct SubtitleTracker {
    struct Decision {
        let id: Int
        let ready: Bool
        let duplicate: Bool
        let firstSeen: Double
        let reason: String
    }
    private var sequence = 0
    private var previous: [OCRLine] = []
    private var sent: [OCRLine] = []
    private var reads = 0
    private var first = 0.0
    private var lastSeen = 0.0
    private var lastSent = 0.0
    mutating func reset() { previous = []; sent = []; reads = 0; first = 0; lastSeen = 0; lastSent = 0 }
    static func sameText(_ a: [OCRLine], _ b: [OCRLine]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { TextSim.norm($0.t) == TextSim.norm($1.t) }
    }
    static func closePosition(_ a: [OCRLine], _ b: [OCRLine]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            abs($0.x - $1.x) <= 0.06 && abs($0.y - $1.y) <= max(0.035, max($0.h, $1.h))
        }
    }
    mutating func observe(_ lines: [OCRLine], at now: Double, required: Int, adaptive: Bool, spatial: Bool,
                          deadline: Double, minimumConfidence: Double, strictSource: Bool = false) -> Decision {
        let confidence = lines.map { $0.confidence ?? 0 }.min() ?? 0
        func sameSource(_ a: [OCRLine], _ b: [OCRLine]) -> Bool {
            if !strictSource { return Self.sameText(a, b) }
            return a.count == b.count && zip(a, b).allSatisfy {
                ConfirmedSourceIdentity.normalize($0.t) == ConfirmedSourceIdentity.normalize($1.t)
            }
        }
        let same = sameSource(lines, previous)
        let stablePosition = !spatial || Self.closePosition(lines, previous)
        let similar = lines.count == previous.count && zip(lines, previous).allSatisfy { TextSim.similar($0.t, $1.t, 0.94) }
        let priorConfidence = previous.map { $0.confidence ?? 0 }.min() ?? 0
        let continueConfirmation = reads > 0 && now - lastSeen <= 1.5 && stablePosition
            && (same || (!strictSource && adaptive && similar && confidence >= 0.9 && priorConfidence >= 0.9))
        // Content changes always receive a new work identity, even if confirmation can reuse strong nearby evidence.
        if reads == 0 || !same || !stablePosition || now - lastSeen > 1.5 { sequence += 1 }
        if continueConfirmation { reads += 1 } else { reads = 1; first = now }
        previous = lines; lastSeen = now
        let duplicate = sameSource(lines, sent) && (!spatial || Self.closePosition(lines, sent)) && now - lastSent < 3
        if duplicate { return Decision(id: sequence, ready: false, duplicate: true, firstSeen: first, reason: "unchanged subtitle") }
        let age = now - first
        // Immediate confirmation is opt-in and requires every line to be exceptionally clear.
        let instant = adaptive && required <= 2 && confidence >= 0.98 && lines.allSatisfy { $0.h >= 0.018 }
        let normal = reads >= max(1, required) && (!adaptive || confidence >= max(minimumConfidence, 0.72))
        // Deadline never releases a single uncertain sighting or bypasses the configured confidence floor.
        let timed = adaptive && reads >= 2 && stablePosition && age >= max(0.15, deadline) && confidence >= max(minimumConfidence, 0.65)
        let ready = instant || normal || timed
        if ready { sent = lines; lastSent = now }
        return Decision(id: sequence, ready: ready, duplicate: false, firstSeen: first,
                        reason: instant ? "high-confidence immediate" : (timed && !normal ? "confirmation deadline" : (normal ? "confirmed reads" : "awaiting confirmation")))
    }
}

enum SpeculationPolicy {
    static func credible(lines: [OCRLine], threshold: Double) -> Bool {
        !lines.isEmpty && lines.allSatisfy { ($0.confidence ?? 0) >= threshold }
            && lines.reduce(0) { $0 + $1.t.filter(\.isLetter).count } >= 6
    }
}

struct MemoryEnvelope: Codable {
    let version: Int
    let entries: [String: String]
    init(entries: [String: String]) { version = 4; self.entries = entries }
    var validated: [String: String] {
        guard version == 4 else { return [:] }
        return entries.filter { $0.key.hasPrefix("v4|") && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
struct SubtitleTrace: Identifiable {
    let id = UUID()
    let candidate: String
    let stage: String
    let time: Date
    let detail: String
}
struct RecorderCosts {
    private(set) var simpleMs = 0.0, detailedMs = 0.0
    private(set) var simpleCalls = 0, detailedCalls = 0
    mutating func record(ms: Double, detailed: Bool) {
        if detailed { detailedMs += max(0, ms); detailedCalls += 1 }
        else { simpleMs += max(0, ms); simpleCalls += 1 }
    }
}

extension Config {
    func resetsRecognition(comparedTo old: Config?) -> Bool {
        guard let old else { return true }
        return appInterfaceVisible != old.appInterfaceVisible || lang != old.lang || y0 != old.y0 || y1 != old.y1 || rev != old.rev || rot != old.rot
            || paused != old.paused || stability != old.stability || confidence != old.confidence
            || correction != old.correction || boost != old.boost || adaptiveConfirmation != old.adaptiveConfirmation
            || subtitleTracking != old.subtitleTracking
            || strictCaptionIdentity != old.strictCaptionIdentity || focusedCaptionOCR != old.focusedCaptionOCR
    }
}

struct SubtitleRegions {
    private var anchors: [String: (Double, Double)] = [:]
    mutating func deduplicated(_ blocks: [[OCRLine]]) -> [[OCRLine]] {
        var groups: [String: [[OCRLine]]] = [:]
        var order: [String] = []
        for block in blocks {
            let key = block.map { TextSim.norm($0.t) }.joined(separator: "|")
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(block)
        }
        var output: [[OCRLine]] = []
        for key in order {
            guard let copies = groups[key], let first = copies.first else { continue }
            func center(_ block: [OCRLine]) -> (Double, Double) {
                let n = Double(max(1, block.count))
                return (block.map(\.x).reduce(0,+)/n, block.map(\.y).reduce(0,+)/n)
            }
            var chosen = first
            if copies.count > 1, key.count >= 8, let anchor = anchors[key] {
                chosen = copies.min { a, b in
                    let p = center(a), q = center(b)
                    return abs(p.0-anchor.0)+abs(p.1-anchor.1) < abs(q.0-anchor.0)+abs(q.1-anchor.1)
                } ?? first
            }
            if key.count < 8 { output.append(contentsOf: copies) }
            else { output.append(chosen); anchors[key] = center(chosen) }
        }
        if anchors.count > 64 { anchors.removeAll(keepingCapacity: true) }
        return output
    }
}

enum MemoryRetentionPolicy {
    static func mayPersist(privateSession: Bool, selectedSource: Bool, confidence: Double, confirmed: Bool) -> Bool {
        confirmed && !privateSession && (selectedSource || confidence >= 0.65)
    }
}
enum CandidateValidity {
    static func isCurrent(_ work: String?, active: String?, enabled: Bool, allowLegacy: Bool = false) -> Bool {
        !enabled || (allowLegacy && work == nil) || work == active
    }
}

struct RotationBudget {
    private var attempt = 0
    private(set) var exhausted = false
    static func sufficientEvidence(vote: Double, samples: Int) -> Bool { vote < -6 && samples >= 3 }
    mutating func next() -> Int? {
        guard !exhausted else { return nil }
        let rotation = [2, 1, 3, 0][attempt]
        attempt += 1
        exhausted = attempt == 4
        return rotation
    }
    mutating func reset() { self = RotationBudget() }
}
struct LanguageContext {
    private(set) var text = ""
    private(set) var code = ""
    private var updated = -Double.infinity
    mutating func reset() { self = LanguageContext() }
    mutating func record(_ value: String, code language: String, confidence: Double, now: Double) {
        guard confidence >= 0.85, value.filter(\.isLetter).count >= 16 else { return }
        if code != language || now - updated > 8 { text = "" }
        if !text.contains(value) { text = String((text + " " + value).suffix(512)) }
        code = language; updated = now
    }
    func mayAssist(_ hypotheses: [String: Double], now: Double) -> Bool {
        guard !text.isEmpty, now - updated < 8 else { return false }
        let ranked = hypotheses.values.sorted(by: >)
        let first = ranked.first ?? 0, second = ranked.dropFirst().first ?? 0
        let support = hypotheses.filter { SourceLanguageRouter.sameLanguage($0.key, code) }.values.max() ?? 0
        return (first < 0.65 || first - second < 0.25) && support >= 0.15
    }
}
