import Foundation

enum TranslationTestMode: String {
    case normal, freshRequests, temporaryMemory

    init(freshRequests: Bool, temporaryMemory: Bool) {
        self = freshRequests ? .freshRequests : (temporaryMemory ? .temporaryMemory : .normal)
    }
    var allowsReuse: Bool { self != .freshRequests }
    var allowsSpeculation: Bool { self != .freshRequests }
    var allowsPersistentTranslations: Bool { self == .normal }
    var allowsHistoryInsertion: Bool { self != .temporaryMemory }
}

/// Process-owned reference storage; never Codable and never written to disk.
/// Switching banks does not copy their dictionaries or clear the temporary bank.
struct ExactCaptionResult {
    let translated: String
    let sentences: Int
}

enum ExactCaptionIdentity {
    static func key(blocks: [String], source: String, target: String, rules: String) -> String? {
        guard source != "auto", !source.isEmpty, !target.isEmpty, !blocks.isEmpty else { return nil }
        // Preserve raw wording AND block boundaries. No normalized/fuzzy caption reuse.
        let framed = blocks.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return PipelineSafety.cacheKey(source: source, target: target, text: framed,
                                       protectedWords: [], rules: rules)
    }
}

enum ModelQueueOwner: String {
    case scheduling, confirmed, speculative
}

final class TranslationRAMBank {
    private(set) var captions: [String: ExactCaptionResult] = [:]
    private var captionOrder: [String] = []
    func retainCaption(key: String, result: ExactCaptionResult) {
        guard !result.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if captions[key] == nil { captionOrder.append(key) }
        captions[key] = result
        if captionOrder.count > 64 { captions.removeValue(forKey: captionOrder.removeFirst()) }
    }
    func clear() {
        values.removeAll(); specKeys.removeAll(); savedKeys.removeAll(); confirmedKeys.removeAll()
        speculativeOrigins.removeAll(); use.removeAll(); captions.removeAll(); captionOrder.removeAll()
        speculationWindow = SpeculativeWorkWindow(); clock = 0
    }
    var values: [String: String] = [:]
    var specKeys = Set<String>()
    var savedKeys = Set<String>()
    var confirmedKeys = Set<String>()
    var speculativeOrigins: [String: UInt64] = [:]
    var speculationWindow = SpeculativeWorkWindow()
    var use: [String: UInt64] = [:]
    var clock: UInt64 = 0
}

final class ProcessTranslationMemory {
    let normal = TranslationRAMBank()
    let temporary = TranslationRAMBank()
    func bank(for mode: TranslationTestMode) -> TranslationRAMBank {
        mode == .temporaryMemory ? temporary : normal
    }
}

/// Only exact request identity authorizes keeping obsolete speculative model work.
/// The eventual caption must still independently assemble all of its current units.
enum ExactModelWorkPolicy {
    static func sharedUnits(inFlight: Set<String>, required: Set<String>,
                            workContext: Int?, currentContext: Int, reuseAllowed: Bool) -> Int {
        guard reuseAllowed, workContext == currentContext,
              inFlight.isSubset(of: required) else { return 0 }
        return inFlight.intersection(required).count
    }
}
