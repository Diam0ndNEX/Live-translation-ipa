import Foundation

enum SourceLanguageOrigin: String, CaseIterable {
    case selected, detected, locked
    var title: String {
        switch self { case .selected: return "Selected"; case .detected: return "Auto-detected"; case .locked: return "Language lock" }
    }
}

/// Counts confirmed source blocks, including manually selected and locked sources.
/// Speculative inputs and target-language passthroughs are recorded by neither caller nor counter.
struct SourceLanguageUsage {
    private(set) var counts: [String: Int] = [:]
    private(set) var origins: [SourceLanguageOrigin: Int] = [:]
    mutating func record(_ language: String, origin: SourceLanguageOrigin) {
        guard !language.isEmpty, language != "auto", language != "–" else { return }
        counts[language, default: 0] += 1
        origins[origin, default: 0] += 1
    }
}
