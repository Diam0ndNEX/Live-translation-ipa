import Foundation

enum InitialWarmupSamples {
    static func units(source: String) -> [String]? {
        let base = Locale.Language(identifier: source).languageCode?.identifier ?? source
        if base == "zh", source.contains("Hant") { return ["你好。", "我們需要弄清楚這裡發生了什麼。"] }
        let samples: [String: [String]] = [
            "en": ["Hello.", "We need to find out what happened here."],
            "pt": ["Olá.", "Precisamos descobrir o que aconteceu aqui."],
            "es": ["Hola.", "Tenemos que descubrir qué pasó aquí."],
            "fr": ["Bonjour.", "Nous devons découvrir ce qui s’est passé ici."],
            "de": ["Hallo.", "Wir müssen herausfinden, was hier passiert ist."],
            "it": ["Ciao.", "Dobbiamo scoprire cosa è successo qui."],
            "ja": ["こんにちは。", "ここで何が起きたのか調べなければなりません。"],
            "ko": ["안녕하세요.", "여기서 무슨 일이 있었는지 알아봐야 합니다."],
            "zh": ["你好。", "我们需要弄清楚这里发生了什么。"],
            "ru": ["Привет.", "Нам нужно выяснить, что здесь произошло."],
            "ar": ["مرحبًا.", "نحتاج إلى معرفة ما حدث هنا."],
            "tr": ["Merhaba.", "Burada ne olduğunu öğrenmemiz gerekiyor."],
            "hi": ["नमस्ते।", "हमें पता लगाना होगा कि यहाँ क्या हुआ।"],
            "id": ["Halo.", "Kita perlu mencari tahu apa yang terjadi di sini."],
            "nl": ["Hallo.", "We moeten uitzoeken wat hier is gebeurd."],
            "pl": ["Cześć.", "Musimy dowiedzieć się, co się tutaj stało."],
            "th": ["สวัสดี", "เราต้องหาว่าเกิดอะไรขึ้นที่นี่"],
            "vi": ["Xin chào.", "Chúng ta cần tìm hiểu chuyện gì đã xảy ra ở đây."],
            "uk": ["Привіт.", "Нам потрібно з'ясувати, що тут сталося."]
        ]
        return samples[base]
    }
}

struct InitialWarmupPolicy {
    private(set) var attempted: Set<String> = []
    private(set) var completed: Set<String> = []
    private var attempts: [String: Int] = [:]
    private var retryAfter: [String: Date] = [:]
    private(set) var totalAdmissions = 0
    static let maxAttempts = 64
    static let maxAttemptsPerPair = 3
    static let retryCooldown: TimeInterval = 30

    static func strategies(for system: TranslationSystem) -> [RequestedTranslationStrategy] {
        switch system {
        case .legacy: return []
        case .hybridRecovery: return [.appleDefault, .lowLatency]
        case .lowLatency: return [.lowLatency]
        }
    }

    private static func key(source: String, target: String, strategy: RequestedTranslationStrategy) -> String {
        source + ">" + target + "|" + strategy.rawValue
    }

    mutating func claim(source: String, target: String, strategy: RequestedTranslationStrategy,
                        now: Date = Date()) -> Bool {
        let key = Self.key(source: source, target: target, strategy: strategy)
        guard !completed.contains(key),
              totalAdmissions < Self.maxAttempts,
              attempts[key, default: 0] < Self.maxAttemptsPerPair,
              now >= (retryAfter[key] ?? .distantPast) else { return false }
        attempts[key, default: 0] += 1
        totalAdmissions += 1
        attempted.insert(key)
        retryAfter[key] = now.addingTimeInterval(Self.retryCooldown)
        return true
    }

    mutating func finish(source: String, target: String, strategy: RequestedTranslationStrategy,
                         succeeded: Bool, now: Date = Date()) {
        let key = Self.key(source: source, target: target, strategy: strategy)
        guard attempted.contains(key) else { return }
        if succeeded {
            completed.insert(key)
            retryAfter.removeValue(forKey: key)
        } else {
            retryAfter[key] = now.addingTimeInterval(Self.retryCooldown)
        }
    }

    func skippedReason(source: String, target: String, strategy: RequestedTranslationStrategy,
                       now: Date = Date()) -> String {
        let key = Self.key(source: source, target: target, strategy: strategy)
        if completed.contains(key) { return "A previous model warm-up succeeded for this pair and strategy; no repeated request was made." }
        if totalAdmissions >= Self.maxAttempts || attempts[key, default: 0] >= Self.maxAttemptsPerPair {
            return "The initial warm-up attempt budget was reached; live translation remains available."
        }
        if let retry = retryAfter[key], now < retry {
            return "An earlier warm-up was interrupted or failed. A bounded retry is allowed after the cooldown."
        }
        return "Initial warm-up was deferred by current model or power conditions."
    }
}

struct InitialWarmupEvent: Codable {
    let id: UUID
    let system: TranslationSystem
    let testMode: String
    let source: String
    let target: String
    let strategy: RequestedTranslationStrategy
    let phase: String
    let monotonicTime: Double
    let durationMs: Double?
}

/// Backend lifetime is independent of whether a subtitle has already selected a result.
struct TranslationBackendActivity: Equatable {
    enum Kind: Int { case preparation, speculative, confirmed, warmup }
    enum Stage { case checkingLanguages, preparingSessions, waitingForSlot, running, cancelling }
    struct Job: Equatable {
        let id: UUID
        let kind: Kind
        let source: String
        let target: String
        let strategy: RequestedTranslationStrategy
        var stage: Stage
        var since: Date
    }
    private(set) var jobs: [UUID: Job] = [:]

    mutating func begin(kind: Kind, source: String, target: String, strategy: RequestedTranslationStrategy,
                        stage: Stage, now: Date = Date()) -> UUID {
        // Only the latest preparation/waiter per lane matters; real calls remain until return.
        jobs = jobs.filter { $0.value.kind != kind || $0.value.stage == .running || $0.value.stage == .cancelling }
        let id = UUID()
        jobs[id] = Job(id: id, kind: kind, source: source, target: target, strategy: strategy, stage: stage, since: now)
        return id
    }
    mutating func advance(_ id: UUID, to stage: Stage, now: Date = Date()) {
        guard var job = jobs[id], job.stage != stage else { return }
        job.stage = stage; job.since = now; jobs[id] = job
    }
    mutating func end(_ id: UUID) { jobs.removeValue(forKey: id) }

    var executing: Bool { jobs.values.contains { $0.stage == .running || $0.stage == .cancelling } }
    func liveReadiness(_ evidence: TranslationReadiness) -> TranslationReadiness {
        var value = evidence
        if value.languages == .working { value.languages = .pending }
        if value.sessions == .working { value.sessions = .pending }
        if value.execution == .working { value.execution = .pending }
        if value.execution == .complete { value.execution = .idle }
        for job in jobs.values {
            switch job.stage {
            case .checkingLanguages: value.languages = .working
            case .preparingSessions: value.sessions = .working
            case .running, .cancelling: value.execution = .working
            case .waitingForSlot: break
            }
        }
        return value
    }
    var current: Job? {
        jobs.values.sorted {
            func priority(_ job: Job) -> Int {
                if job.stage == .cancelling { return 0 }
                if job.kind == .confirmed { return 4 }
                if job.kind == .speculative { return 3 }
                if job.kind == .warmup { return 1 }
                return 2
            }
            let lhs = priority($0), rhs = priority($1)
            return lhs == rhs ? $0.since > $1.since : lhs > rhs
        }.first
    }
    var activity: TranslationActivity? {
        guard let job = current else { return nil }
        let title: String
        let strategy = job.strategy == .lowLatency ? "Low latency" : "Apple default"
        switch job.stage {
        case .checkingLanguages: title = "Checking installed languages"
        case .preparingSessions: title = "Preparing translation sessions"
        case .waitingForSlot: title = "Waiting for translation resources"
        case .running: title = job.kind == .warmup ? "Running initial warm-up" : (job.kind == .speculative ? "Translating ahead" : "Translating confirmed text")
        case .cancelling: title = "Waiting for cancelled model work to return"
        }
        return TranslationActivity(title: title, detail: "\(job.source) → \(job.target) · requested \(strategy) · \(jobs.count) active operation\(jobs.count == 1 ? "" : "s")",
            phase: .working, since: job.since)
    }

    static func idle(capture: Bool, ownInterfaceVisible: Bool, modelObserved: Bool) -> TranslationActivity {
        if capture && ownInterfaceVisible {
            return TranslationActivity(title: "Capture connected · ScreenLingo visible", detail: "This app's own screen is excluded. Switch to your video or another app to translate its captions.", phase: .waiting)
        }
        if capture {
            return TranslationActivity(title: "Watching for the next caption", detail: "No model request is running. Translation starts when new text needs it.", phase: .waiting)
        }
        return TranslationActivity(title: "Waiting for capture", detail: modelObserved ? "Previous model execution is recorded below. Start capture for new translations." : "Sessions can be prepared before capture; real model execution starts when text needs translation.", phase: .waiting)
    }
}

/// Observed preparation milestones. Completion means evidence, never elapsed time.
struct TranslationReadiness: Equatable {
    enum Step { case pending, working, complete, blocked, idle }
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
        else if execution == .idle { title = "Idle · previous model request recorded"; phase = .waiting }
        else if sessions == .idle { title = "Session recheck pending"; phase = .waiting }
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
        case "speculation_match_unfinished": title = "Finishing matching early translation"; detail = "Checking the matching result before launching recovery"
        case "hybrid_hedged_recovery": title = "Racing confirmed recovery"; detail = "Keeping the Apple Default request alive while Low Latency translates confirmed text"
        case "hybrid_obsolete_speculation_draining": title = "Recovering corrected text"; detail = "Ignoring earlier text while preserving its warmed translation session"
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
