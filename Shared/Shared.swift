// Screen Translator – Shared – v0.11.0
import Foundation

enum AppVersion {
    static let version = "1.8.0"
    static let build = 59
    static var full: String { "v\(version) (build \(build))" }
    // Newest first. Add a line here each time you bump the version.
    static let changelog: [(String, String)] = [
        ("1.8.0", "Memory-first subtitle scheduling: bounded saved-unit lookups bypass busy model work; exact RAM captions avoid idle scheduling delay; waiting confirmed captions receive completed speculative units; measured blocking budgets preserve recovery probes; warm session ownership transfers between serialized lanes; prominent frame-confirmed capture status with stop/lost/waiting states; strict paired normal/temporary performance acceptance. Device performance acceptance pending."),
        ("1.7.2", "Separate reusable speculative-session ownership allows explicit obsolete-model preemption while protecting the warm confirmed session; cancelled sessions cannot be reused; exact growing captions can also share confirmed in-flight work; confirmed batches expose completed exact units to queued full-caption assembly and retry only unfinished units after incomplete batches. Complete exact RAM captions can bypass an occupied model lane without waiting for whole-caption repetition; shared complete-result assembly preserves speaker labels, protected words and glossary; saved-reuse-aware speculative backoff with recovery probes; recent fragments rejected before active-work cancellation; confirmed handoff priority at drain boundaries; explicit bypass/backoff accounting. Device performance validation pending."),
        ("1.7.1", "Process-only temporary-memory test toggle with speculation; independent normal RAM and saved history; exact assembled-caption reuse around obsolete model work; queue-owner and speculative-unit accounting; corrected bypass/miss labels and complete diagnostic allowlists."),
        ("1.7.0", "Normal-model performance: recover completed obsolete work, coalesce durable sentence writes, avoid redundant memory writes and reuse indexed lookup statements. Exclude own-app interface OCR and reset acquisition across app switches. Independent model timing samples and reproducible performance acceptance tooling."),
        ("1.5.0", "Restored speculative head starts and recovered exact completed work; stable localhost capture transport; successful OCR fallback resets; disposable warm-up and idle model cancellation; fewer duplicate database health queries; protected-name, photo-workspace and private-history fixes; median/mean/P90/P95 comparisons and continuity evidence. Retains selective legacy cleanup."),
        ("1.4.7", "Selective deletion of unvalidated legacy records; exported validation inventory and exclusions; candidate-linked confirmed/speculative model timings and preemption counters; stronger bounded backoff for sustained ineffective speculation."),
        ("1.4.6", "Legacy-validation inventory, explicit skip reasons and rescan control; automatic scans recover after language/rule/database/model availability changes. Failed tentative batches yield retries to confirmed translation."),
        ("1.4.5", "Faster independent confirmation reads under nominal load, reusable accurate OCR requests and PiP buffers, representative startup warm-up, rolling diagnostic-independent speculation control, bounded confirmed handoff and stage-by-stage latency evidence."),
        ("1.4.4", "Predictive on-device warm-up for recently confirmed Auto source, bounded speculative workload, confirmed-caption continuity, tail-latency instrumentation, and memory-validation observability."),
        ("1.4.3", "Faster legacy validation: 24-item automatic batches, up to 48 on demand, controlled parallel model sessions, adaptive cooldown, atomic SQLite batch commits, progress and live-capture preemption."),
        ("1.4.2", "Conservative lazy validation of legacy memory using independently confirmed translations, startup and subtitle continuity improvements, and richer diagnostics for tail latency and memory validation."),
        ("1.4.1", "Improved rapid-subtitle detection, reduced idle OCR delay in Movie mode, protected confirmed text from speculative cancellation, prioritized confirmed translation and expanded privacy-safe diagnostics."),
        ("1.4.0", "Universal Translation Memory 2.0 development candidate: SQLite-backed persistence and migration, memory management and diagnostics. Release acceptance remains pending."),
        ("1.3.0", "Adaptive Auto/Balanced recognition, optional confidence-aware confirmation, spatial subtitle tracking, selective cancellable speculation and stable candidate-aware presentation. Versioned rule-aware memory in Application Support, separate cache origins, smarter Cool Mode and detailed subtitle/workload diagnostics with measured recorder self-time. Fixed runtime pressure changes resetting OCR confirmation."),
        ("1.2.1", "Fixed Automatic locking to the target language and feeding its lock back into OCR. Explicit sources bypass language-guess vetoes, confident language changes route immediately, and speculative reads cannot alter locks. Fresh OCR after language changes, uncased-script rotation protection and a toolbar menu for diagnostic collection."),
        ("1.2.0", "Session speaker labels no longer require diagnostic export consent. Added Cool mode, independent diagnostic collection switches and clearer automatic language-lock guidance."),
        ("1.1.0", "Fixed source-language graphs for selected and locked sources. Diagnostics now distinguish selected, detected and locked input, record foreground/background transitions, and export source counts and runtime context. Removed the memory explanation."),
        ("1.0.0", "Nonblocking readability holds: translation works before optional display waits, and stale pending results are cancelled safely. Replaced residual waiting/display estimates with matched stage measurements. Added timing, caption layout, reader/photo, feedback and storage controls; clarified per-process memory headroom. Existing OCR quality and confirmation defaults remain unchanged."),
        ("0.9.0", "New screen-and-translation icon and redesigned Live interface. Start-based OCR cadence removes redundant waiting while preserving accuracy and confirmation passes. Exact request coalescing, bounded language-evidence caching, faster font fitting, reusable heartbeat frames and display-before-history ordering reduce repeated work. Added honest first-sighting-to-enqueue timing and protected-name cache isolation."),
        ("0.8.0", "Major workspace overhaul: photo/text translation, visual capture-area editor, focus reader, session controls, searchable history with notes, CSV/JSON export and restore, undo deletion, private sessions, OCR tuning and idle power saving."),
        ("Early development", "Integrated the latest main redesign, custom presets, diagnostics charts, translation memory and translate-ahead. Preserved ScreenLingo identity, small text, lyric rows and fragment protection. Fixed stale output, batch validation, frozen output and legacy timeouts."),
        ("0.11.0", "Faster translation with identical wording: translate-ahead (starts translating on first sight, shows when confirmed), warm translator, translation memory kept between launches, cached language-pack check. Sharing now goes through real files (fixes the endless Loading…)."),
        ("0.10.0", "Diagnostics rebuilt: Simple view (health score, plain-language fixes with one-tap buttons, live feed) and Detailed view with 7 pages. Real charts for speed, delay, frames per second, memory, temperature and battery, histograms, a session timeline of Live / Paused / Idle with event markers, translations per minute, a pipeline funnel and filter breakdown, language and cache charts, a searchable filterable event log, CSV export and a shareable report."),
        ("0.9.0", "Redesigned app. Custom presets (save, edit, duplicate, reorder, start-up preset) with icons and colours. New Home with live status badge, quick tiles and recent language pairs. Reader view, share-as-image, toasts, onboarding, keep-screen-awake, auto-copy, speech speed, saved history with search, stars and day groups, accent colours, Home sections you can hide, settings search and per-page reset."),
        ("0.8.0", "Fixes reversed sentence order (auto-detects upside-down frames and rotates them, or pick the rotation manually). Context layer: speaker names kept, chat slang expanded, OCR clean-up, noise filter, language lock, never-translate words. Live Diagnostics tab. 30+ new options, profiles, backup, history search + stars."),
        ("0.7.0", "App icon. Correct version shown when signing (was 1.0). Big new Settings screen: custom OCR area, ignore small text, ignore list, glossary, stability, floating-window font, hold time, auto-open. Quick presets (Movie/Game/Comic), setup checklist, export history."),
        ("0.6.0", "Fixes mixed-up sentence order: text is grouped into blocks (bubble vs background), each block read in proper order and translated sentence by sentence in one batch. Ignores background text in another language. Floating-window appearance + text size, speak translation aloud."),
        ("0.5.0", "Much faster: OCR only reads your chosen area at reduced size, with the source language as a hint. Stops reading its own floating window (learns where it is). Speed presets, translation cache, auto-clear when text ends, pause, history tab, live OCR/translate timing + memory in diagnostics."),
        ("0.4.1", "Start section has a visible broadcast icon + separate floating-window button. Fixed build error."),
        ("0.4.0", "Stronger OCR (all languages, contrast fallback, stability check). Smart area. Auto-detect favors installed languages. Shows what OCR reads."),
        ("0.3.0", "Fixed PiP not starting, retries + error messages, redesigned UI, swap button, languages grouped by ready/available."),
        ("0.2.0", "No more App Group. Language pickers, pack downloads, modes, OCR area, window size, diagnostics, test button."),
        ("0.1.0", "First version.")
    ]
}

enum Loopback { static let port: UInt16 = 48721 }

struct OCRLine: Codable {
    var t: String      // text
    var x: Double      // normalized mid X
    var y: Double      // normalized mid Y of the FULL frame (0 = bottom, 1 = top)
    var h: Double      // normalized height (full frame)
    var w: Double?     // normalized width
    var confidence: Double? = nil
}

/// Extension → app
struct Packet: Codable {
    var kind: String   // "ping" | "ocr" | "clear" | "stopped"
    var version: String
    var frames: Int
    var lines: [OCRLine]
    var ocrMs: Double?
    var memFreeMB: Double?
    var ts: Double?        // when the extension sent it (seconds since 1970)
    var rev: Int?          // settings revision the extension was using
    var bufW: Int?
    var bufH: Int?
    var orient: Int?       // raw RPVideoSampleOrientationKey value
    var cropW: Int?
    var cropH: Int?
    var passes: Int?       // OCR passes so far
    var skipped: Int?      // unchanged frames skipped
    var stable: Bool?      // false = first sighting (translate ahead), nil/true = confirmed
    var firstSeenAt: Double? = nil
    var readStartedAt: Double? = nil
    var candidateID: String? = nil
    var recognitionReason: String? = nil
    var confirmationReason: String? = nil
    var unchangedSkipped: Int? = nil
    var cadenceSkipped: Int? = nil
    var pausedSkipped: Int? = nil
    var emptyReads: Int? = nil
    var retryCount: Int? = nil
    // Numeric metadata only; retained across ping packets even when OCR sees no text.
    var visualChanges: Int? = nil
    var totalEmptyOCRPasses: Int? = nil
    var lastVisualChangeAt: Double? = nil
    var effectiveOCRIntervalMs: Double? = nil
    var captureSessionID: String? = nil
}

/// App → extension (sent back over the same localhost link)
struct Config: Codable, Equatable {
    var lang: String       // "auto" or a language code (used as OCR language hint)
    var y0: Double         // OCR area, 0 = bottom
    var y1: Double         // 1 = top
    var maxEdge: Double    // longest image side OCR works at (smaller = faster)
    var interval: Double   // minimum seconds between OCR passes
    var paused: Bool
    var stability: Int?    // how many identical reads before text is sent (1 = instant)
    var rot: Int?          // extra clockwise quarter-turns applied to the frame (0...3)
    var rev: Int?          // bumps whenever rot changes so stale packets can be ignored
    var boost: Int?        // 0 = off, 1 = only when nothing is found, 2 = always
    var skipUnchanged: Bool?
    var subtitleAwareChangeDetection: Bool? = nil
    var speculate: Bool?   // send an early "first sighting" so the app can translate ahead
    var confidence: Double? = nil
    var correction: Bool? = nil
    var idleBackoff: Bool? = nil
    var movieMode: Bool? = nil
    var captureDiagnostics: Bool? = nil
    var adaptiveOCR: Bool? = nil
    var adaptiveConfirmation: Bool? = nil
    var subtitleTracking: Bool? = nil
    var confirmationDeadline: Double? = nil
    var smartCool: Bool? = nil
    var pressure: Bool? = nil
    var selectiveSpeculation: Bool? = nil
    var speculationConfidence: Double? = nil
    var detailCeiling: Double? = nil
    var confirmationBurst: Bool? = nil
    var appInterfaceVisible: Bool? = nil
}

/// Keeps the old memory context exactly unchanged unless a genuinely
/// different user-selected model strategy is active.
enum TranslationModelMemoryPolicy {
    static func rulesContext(base: String, lowLatency: Bool) -> String {
        lowLatency ? base + "\u{1F}translationStrategy=lowLatency" : base
    }
}

enum TextSim {
    static func norm(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

    static func grams(_ s: String) -> Set<String> {
        let c = Array(norm(s))
        if c.isEmpty { return [] }
        if c.count == 1 { return [String(c)] }
        return Set((0..<(c.count - 1)).map { String(c[$0...($0 + 1)]) })
    }

    /// Jaccard similarity of character bigrams (tolerates small OCR differences).
    static func similar(_ a: String, _ b: String, _ threshold: Double = 0.85) -> Bool {
        if a == b { return true }
        if a.isEmpty || b.isEmpty { return false }
        let x = grams(a), y = grams(b)
        let uni = x.union(y).count
        return uni > 0 && Double(x.intersection(y).count) / Double(uni) >= threshold
    }

    /// Fraction of `a`'s bigrams that appear in `set`.
    static func containment(of a: String, in set: Set<String>) -> Double {
        let g = grams(a)
        if g.isEmpty { return 0 }
        return Double(g.intersection(set).count) / Double(g.count)
    }
}

