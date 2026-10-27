import Foundation

/// Optional work only; recognition accuracy, image size and confirmation rules stay unchanged.
struct RuntimePolicy {
    let coolMode: Bool
    let diagnosticsEnabled: Bool
    let detailedRequested: Bool
    var detailedDiagnostics: Bool { diagnosticsEnabled && detailedRequested }
    func captureInterval(_ configured: Double) -> Double {
        coolMode ? max(0.45, configured * 2) : configured
    }
    var allowsSpeculation: Bool { !coolMode }
    var allowsPrewarming: Bool { !coolMode }
}

/// Names are session-only; export consent is handled separately at the export boundary.
struct SpeakerSession {
    private(set) var names: [String] = []
    mutating func record(_ name: String, enabled: Bool, privateSession: Bool) {
        guard enabled, !privateSession else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }), names.count < 60 else { return }
        names.append(name)
        names.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
