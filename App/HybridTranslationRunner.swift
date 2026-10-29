import Foundation
import Translation

/// Called only by the engine's serialized live drain. It never writes memory,
/// presents text, requests downloads or starts a concurrent quality request.
@MainActor
final class HybridTranslationRunner {
    private var session: TranslationSession?
    private var key = ""
    private var epoch = UUID()
    private(set) var status = "Fast model not prepared"

    func reset() {
        epoch = UUID()
        if #available(iOS 26.0, *) { session?.cancel() }
        session = nil; key = ""
    }

    func translate(_ texts: [String], source: Locale.Language, target: Locale.Language,
                   isCurrent: @escaping @MainActor () -> Bool,
                   onSubmitted: @MainActor () -> Void) async -> [String]? {
        guard #available(iOS 26.4, *), !texts.isEmpty, isCurrent(), !Task.isCancelled else { return nil }
        let revision = epoch
        let identity = TranslationModelMemoryPolicy.sessionKey(source: source.minimalIdentifier,
            target: target.minimalIdentifier, lowLatency: true)
        if session == nil || key != identity {
            let availability = await LanguageAvailability(preferredStrategy: .lowLatency).status(from: source, to: target)
            guard revision == epoch, isCurrent(), !Task.isCancelled else { return nil }
            guard availability == .installed else {
                status = availability == .unsupported ? "Fast model does not support this pair" : "Prepare fast language packs in Translation settings"
                return nil
            }
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
            key = identity
        }
        guard let current = session else { return nil }
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        do {
            onSubmitted()
            let responses = try await current.translations(from: requests)
            let result = PipelineSafety.orderedTranslations(responses.map { ($0.clientIdentifier, $0.targetText) }, count: texts.count)
            guard revision == epoch else { return nil }
            if result == nil, session === current { session = nil }
            status = result == nil ? "Fast preview incomplete; using Apple default" : "Fast model ready"
            return result
        } catch {
            if session === current { session = nil }
            status = Task.isCancelled ? "Fast preview superseded" : "Fast model unavailable; using Apple default"
            return nil
        }
    }
}
