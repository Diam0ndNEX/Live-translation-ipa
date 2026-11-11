import Foundation

/// Controlled comparison is permitted only for matching diagnostic boundaries,
/// device OS, settings and adequate sample counts. It is not a causal claim.
struct DiagnosticPerformanceComparison {
    let comparable: Bool
    let reason: String
    let p95Changes: [String: Double]
    let medianChanges: [String: Double]
    let meanChanges: [String: Double]
    let p90Changes: [String: Double]
    /// Differences that are shown but never block a comparison (thermal path, start state, window size, ...).
    let notes: [String]

    /// 2.2.1 (D3): two runs are comparable when these settings are equal. Everything else that differs is a note.
    /// Before 2.2.1 the whole settings dictionary had to match, which included the end thermal state and the
    /// starting RAM entries, so almost every comparison was withheld.
    static let cohortKeys = [
        "mode", "speed", "stability", "area", "customY0", "customY1", "translationTestMode",
        "effectiveRapidTextTracking", "effectiveJoinAdjacentText", "effectiveActiveTextFocus",
        "pixelConfirmation", "eventDrivenOCR", "fastOCR", "legacySharedSession",
        "hotPathAB", "availabilityRefreshAB", "legacyOwnLaneAB", "heartbeatAB", "armedDeferAB",
        // 2.5.0: the switches that change timing or what is read. A run saved before 2.5.0 has none of them (off).
        "captureWarmAB", "trustedBandAB", "headStartAB", "quietRewarmAB",
        "detailedCollection", "performanceTier",
        "focusedCaptionOCR", "strictCaptionIdentity", "cjkSingleCharacters", "liveWarmupLegacy"
    ]
    static let noteKeys = [
        "thermalStart", "thermalEnd", "thermalMax", "appRequestedCaptureIntervalMs", "appRequestedCaptureEdgePx",
        "startingRAMEntries", "winSize", "showOriginal"
    ]

    /// The cohort keys whose values differ between two runs (a missing value counts as "–").
    static func cohortMismatches(_ a: DiagnosticSessionExport, _ b: DiagnosticSessionExport) -> [String] {
        cohortKeys.filter { (a.settings[$0] ?? "–") != (b.settings[$0] ?? "–") }
    }

    static func differenceNotes(_ a: DiagnosticSessionExport, _ b: DiagnosticSessionExport) -> [String] {
        var notes = noteKeys.compactMap { key -> String? in
            let x = a.settings[key] ?? "–", y = b.settings[key] ?? "–"
            return x == y ? nil : "\(key): \(x) -> \(y)"
        }
        if a.appVersion != b.appVersion { notes.append("app version: \(a.appVersion) -> \(b.appVersion)") }
        return notes
    }

    init(baseline: DiagnosticSessionExport, current: DiagnosticSessionExport) {
        notes = Self.differenceNotes(baseline, current)
        // 2.5.0: runs of the removed Hybrid Recovery mode stay readable but are never compared.
        if baseline.translationModes?.isRemovedMode == true || current.translationModes?.isRemovedMode == true {
            comparable = false
            reason = "One of the runs used Hybrid Recovery, which was removed in 2.5.0; it is kept for reading and is not compared"
            p95Changes = [:]
            medianChanges = [:]; meanChanges = [:]; p90Changes = [:]
            return
        }
        guard let baselineModel = baseline.hardwareModel, !baselineModel.isEmpty,
              baselineModel == current.hardwareModel,
              baseline.systemVersion == current.systemVersion,
              baseline.measurementBoundary == current.measurementBoundary,
              Self.cohortMismatches(baseline, current).isEmpty
        else {
            comparable = false
            let mismatches = Self.cohortMismatches(baseline, current)
            reason = mismatches.isEmpty
                ? "Hardware model, OS or measurement boundaries differ or are unavailable; comparison withheld"
                : "Settings that change the result differ (" + mismatches.joined(separator: ", ") + "); comparison withheld"
            p95Changes = [:]
            medianChanges = [:]; meanChanges = [:]; p90Changes = [:]
            return
        }
        var differences: [String: Double] = [:]
        var medians: [String: Double] = [:], means: [String: Double] = [:], p90s: [String: Double] = [:]
        func change(_ before: Double?, _ after: Double?) -> Double? {
            guard let before, let after, before.isFinite, before > 0, after.isFinite else { return nil }
            return 100 * (after - before) / before
        }
        for name in baseline.distributions.keys.sorted() {
            guard let before = baseline.distributions[name],
                  let after = current.distributions[name],
                  before.count >= 20, after.count >= 20,
                  let baselineP95 = before.p95, baselineP95 > 0,
                  let currentP95 = after.p95, currentP95.isFinite else { continue }
            differences[name] = 100 * (currentP95 - baselineP95) / baselineP95
            medians[name] = change(before.p50, after.p50)
            means[name] = change(before.mean, after.mean)
            p90s[name] = change(before.p90, after.p90)
        }
        p95Changes = differences
        medianChanges = medians; meanChanges = means; p90Changes = p90s
        comparable = !differences.isEmpty
        reason = comparable ? "Comparable settings; different subtitles may affect results"
            : "At least 20 samples per session are required to compare p95"
    }
}
