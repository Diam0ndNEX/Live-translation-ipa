import Foundation

/// Observed preparation milestones. Completion means evidence, never elapsed time.
struct TranslationReadiness: Equatable {
    enum Step { case pending, working, complete, blocked }
    enum Preparation { case checkingLanguages, languagesInstalled, languagesUnavailable, creatingSessions, checkingSessions, sessionsReady, sessionsWaiting, unavailable }
    var languages = Step.pending
    var sessions = Step.pending
    var execution = Step.pending
    var source = ""
    var target = ""
    var explanation = "Preparation has not run for this selection."
    var activeSince: Date?
    var completedAt: Date?
    var durationMs: Double?
    var executionLabel = "Model request"

    mutating func prepare(_ stage: Preparation, now: Date = Date()) {
        switch stage {
        case .checkingLanguages:
            languages = .working; explanation = "Checking installed language support"
        case .languagesInstalled:
            languages = .complete; explanation = "Required language assets are installed"
        case .languagesUnavailable:
            languages = .blocked; explanation = "Install the selected language pair in Languages"
        case .creatingSessions:
            sessions = .working; explanation = "Preparing the requested session handles"
        case .checkingSessions:
            sessions = .working; explanation = "Waiting for Apple's session-readiness check"
        case .sessionsReady:
            sessions = .complete; explanation = execution == .complete ? "Sessions are available; the last successful execution is recorded below." : "Sessions are available. First model execution is still unmeasured."
        case .sessionsWaiting:
            sessions = .pending; explanation = "Languages are installed; sessions are not ready yet"
        case .unavailable:
            sessions = .blocked; explanation = "The requested strategy is unavailable on this system"
        }
        if languages == .working || sessions == .working {
            if activeSince == nil { activeSince = now }
        } else if execution != .working { activeSince = nil }
    }

    mutating func beginExecution(label: String, now: Date = Date()) {
        execution = .working; executionLabel = label; activeSince = now
        explanation = "iOS is executing the request; any model-loading time is included"
    }

    mutating func finishExecution(success: Bool, milliseconds: Double?, now: Date = Date()) {
        execution = success ? .complete : .blocked
        activeSince = nil
        if success {
            languages = .complete; sessions = .complete
            durationMs = milliseconds; completedAt = now
            explanation = "A model request completed successfully. Continued model residency is unknown."
        } else {
            if sessions == .working { sessions = .pending }
            explanation = "The model request failed or timed out; it is not ready evidence"
        }
    }

    var activity: TranslationActivity {
        let title: String
        let phase: TranslationActivity.Phase
        if execution == .working { title = executionLabel; phase = .working }
        else if languages == .blocked || sessions == .blocked || execution == .blocked { title = "Translator needs attention"; phase = .attention }
        else if languages == .working || sessions == .working { title = "Preparing translator"; phase = .working }
        else if sessions == .complete && execution == .complete { title = "Ready · model request verified"; phase = .ready }
        else if sessions == .complete { title = "Configured · first model run pending"; phase = .waiting }
        else { title = "Waiting for preparation"; phase = .waiting }
        return TranslationActivity(title: title, detail: explanation, phase: phase, since: activeSince)
    }
}

/// User-visible work, not an assertion about Apple's effective model or residency.
struct TranslationActivity: Equatable {
    enum Phase { case waiting, working, ready, attention }
    let title: String
    let detail: String
    let phase: Phase
    var since: Date? = nil

    static func event(_ reason: String, now: Date = Date()) -> Self? {
        let title: String
        let detail: String
        var phase = Phase.working
        switch reason {
        case "confirmed", "memory_lookup_start": title = "Checking saved translations"; detail = "Compatible memory can bypass model inference"
        case "speculation_admitted": title = "Preparing early caption"; detail = "Checking reuse while OCR confirms the source"
        case "speculative_enqueue": title = "Waiting for early translation resources"; detail = "Early work is queued; model execution has not started yet"
        case "speculative_model_submitted": title = "Translating ahead"; detail = "Preparing a result while OCR confirms the source"
        case "speculation_ready": title = "Early translation prepared"; detail = "Waiting for the source to be confirmed"; phase = .ready
        case "speculation_failed": title = "Waiting for confirmed text"; detail = "Early work failed; confirmed text can still be translated"; phase = .waiting
        case "speculation_match_unfinished": title = "Finishing matching early translation"; detail = "Sharing the existing request; no duplicate translation"
        case "recovery_enqueue": title = "Waiting for confirmed translation resources"; detail = "Confirmed work is queued; model execution has not started yet"
        case "confirmed_model_submitted": title = "Translating confirmed text"; detail = "Working on the current confirmed source"
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
