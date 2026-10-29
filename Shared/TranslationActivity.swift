import Foundation

/// User-visible work, not an assertion about Apple's effective model or residency.
struct TranslationActivity: Equatable {
    enum Phase { case waiting, working, ready, attention }
    let title: String
    let detail: String
    let phase: Phase
    var since: Date? = nil

    static func preparation(_ message: String, busy: Bool) -> Self {
        if busy { return Self(title: "Preparing translation sessions", detail: "Checking installed languages and session readiness", phase: .working) }
        if message.hasPrefix("Languages and sessions ready") {
            return Self(title: "Sessions ready", detail: "Languages installed · waiting for text. Model residency is not measured.", phase: .ready)
        }
        return Self(title: message.contains("unavailable") || message.contains("requires") || message.contains("needs iOS") ? "Translation needs attention" : "Waiting for translation resources",
                    detail: message, phase: message.contains("unavailable") || message.contains("requires") || message.contains("needs iOS") ? .attention : .waiting)
    }

    static func event(_ reason: String, now: Date = Date()) -> Self? {
        let title: String
        let detail: String
        var phase = Phase.working
        switch reason {
        case "confirmed", "memory_lookup_start": title = "Checking saved translations"; detail = "Compatible memory can bypass model inference"
        case "speculation_admitted", "speculative_enqueue", "speculative_model_submitted": title = "Translating ahead"; detail = "Preparing a result while OCR confirms the source"
        case "speculation_ready": title = "Early translation prepared"; detail = "Waiting for the source to be confirmed"; phase = .ready
        case "speculation_failed": title = "Waiting for confirmed text"; detail = "Early work failed; confirmed text can still be translated"; phase = .waiting
        case "speculation_match_unfinished": title = "Finishing matching early translation"; detail = "Sharing the existing request; no duplicate translation"
        case "recovery_enqueue", "confirmed_model_submitted": title = "Translating confirmed text"; detail = "Working on the current confirmed source"
        case "same_strategy_retry": title = "Retrying translation"; detail = "The requested strategy is unchanged"
        case "hybrid_default_fallback": title = "Trying Apple default fallback"; detail = "Low-latency recovery was unavailable or failed"
        case "pip_enqueue_memory_hit": title = "Saved translation reused"; detail = "Complete result sent to the floating window"; phase = .ready
        case "pip_enqueue_speculation_match_ready", "pip_enqueue_speculation_match_in_flight": title = "Early translation reused"; detail = "Confirmed result sent to the floating window"; phase = .ready
        case "display_failed": title = "Translation could not be displayed"; detail = "Check the floating window and capture controls"; phase = .attention
        case "unsupported_os", "unsupported_or_uninstalled_pair": title = "Translation unavailable"; detail = "Check language downloads and the selected translation system"; phase = .attention
        default:
            if reason.hasPrefix("recovery_decision_") { title = "Recovering confirmed text"; detail = "Using the confirmed source for a fresh translation" }
            else if reason.hasPrefix("pip_enqueue_") { title = "Translation completed"; detail = "Complete result sent to the floating window"; phase = .ready }
            else { return nil }
        }
        return Self(title: title, detail: detail, phase: phase, since: now)
    }
}
