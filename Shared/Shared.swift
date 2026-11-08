// ScreenLingo – Shared
import Foundation

enum AppVersion {
    static let version = "2.2.3"
    static let build = 106
    static var full: String { "v\(version) (build \(build))" }
    // Newest first. Add a line here each time you bump the version.
    static let changelog: [(String, String)] = [
        ("2.2.3", "Build 106: first latency step. New optional switch Refresh language check in background (Advanced > Experimental features > A/B test variants; off by default; applies from the next session). When on, the cached language-pack check is refreshed in the background while nothing is translating, so the one translation per 30 seconds that used to pay about 40 ms for that check no longer does. Same translations either way. Fast OCR was already a switch in Experimental features and is unchanged. Two more off-by-default Hybrid-only switches: Hybrid relaxed backoff (skips 4 instead of 8 early Apple Default requests after unused ones) and Hybrid shorter switch guard (1.0 s guard window and 120 ms settling instead of 1.5 s and 220 ms). A third switch, Legacy confirmed own lane (iOS 26 and later), lets a confirmed caption start without waiting for a cancelled early translation to finish. Diagnostics now keep up to 6000 events instead of 2400. OCR, confirmation and the model choice are untouched; Hybrid still uses the Apple Default model for early work. Not compiled or run when written; the effect is unmeasured and unverified. No speed claims."),
        ("2.2.2", "Build 105: the floating window can open again. Since the 2.1.0 rebuild nothing put its video layer on screen, so every \"Open floating window\" button did nothing without saying why; the layer now lives at the app root, a failed start says why in a notice and in Diagnostics (pip_start_* events), and leaving the app during a live session opens the window by itself when that setting is on. Large-text and small-phone layout fixes: the compose bar sits in the page at accessibility sizes instead of covering Start capture, the status line puts the mode on its own line, the language pair stays on one line when it fits, the Library empty state no longer covers the Recent/Saved switch and its rows stack, Diagnostics attention buttons go under their text, Settings values sit under their titles, the Reading area page scrolls, and long titles no longer cut off. Not compiled or run when written; the PiP fix and the layouts are unverified until the build is installed and tried on a device. No speed claims: nothing in the translation hot paths changed."),
        ("2.2.1", "Build 104: fixes for lost or wrong state (history saves, typing mode, stale toasts), Test Run integrity (manual entries no longer count as capture, thermal and no-timing labels), richer Diagnostics (settings that differ between runs are named, new counters), Settings and Translate now agree with each other, single Chinese/Japanese/Korean characters can be translated, and memory-store timing is recorded. Run-time switches for the A/B variants are under Experimental features and apply from the next session. Not compiled or run when written; speed effects are unmeasured until Diagnostics from all three modes exist."),
        ("2.2.0", "Build 103: Start capture and the floating window are now two separate buttons on Translate (one tap used to do both, and iOS may refuse to open the window while the capture sheet is coming up); \"Show window\" appears if capture runs without it. Also small fixes on Translate and the compose bar. The mode chips now say when a new mode only starts with the next session; picking the same photo twice works again; any plain text file can be imported (not only .txt), files over 25 MB are refused with a message, and an unreadable file gets a plain explanation. Library notes are saved 0.6 s after you stop typing instead of on every key. The capture extension keeps listening for settings after a receive error (it used to stop for the rest of the broadcast). Translation engine untouched. Not compiled or run on a device by Claude; speed unverified."),
        ("2.1.11", "Build 102: the last full-width blurred bars are gone. Focus mode has a plain top row and a floating bottom card, Onboarding's Done button sits on the page, and the Settings summary card is a normal card. UI only, engine untouched. Not compiled or run on a device by Claude; speed unverified."),
        ("2.1.10", "Build 101: Translate is no longer bare. The preparation card is back (current step, warm-up progress, Languages / Session / Model run progress bars, runtime conditions), the Start button has slow ripples, and a small waveform moves while the live caption is being read or translated. All motion stops with Reduce Motion. UI only, engine untouched. Not compiled or run on a device by Claude; speed unverified."),
        ("2.1.9", "Build 100: Translate keeps the same layout in every state (language pair, mode chips, menus, scenes, test row and recent stay on screen while capturing); idle-only buttons that did nothing are hidden until they can work (Hold, Copy, Listen need a translation; Pause, Session need a session); the live screen gets a stop button; the waiting placeholder is small instead of a big empty box; the compose bar is a floating card with no black strip; Library's Recent/Saved switch scrolls with the list instead of sitting on a blurred slab. UI only, engine untouched. Not compiled or run on a device by Claude; speed unverified."),
        ("2.1.8", "Build 99: top bars use a soft fade instead of the hard blurred band; Translate has its own header (no system bar) with three mode chips, capsule menus for content, speed and area, and no dead Pause tile while idle; the tab bar no longer shrinks into a lone bubble; Diagnostics page chips scroll with the page instead of sitting in a pinned slab; Right now hides when nothing is captured and no longer repeats Idle; Memory counters read as words. UI only, engine untouched. Not compiled or run on a device by Claude; speed unverified."),
        ("2.1.7", "Build 98: no app behaviour change. The UI screenshot workflow now runs on every claude/ branch push (one iPhone, default text size) and also captures Settings > Appearance, so the screens can be checked without a computer. Not compiled or run on a device by Claude; speed unverified."),
        ("2.1.6", "Build 97: every Settings sub-page gets the same row treatment: translucent surface rows, bolder section headers, a selection tick on every switch, a springy accent swatch row and a full-width Reset tile. Not compiled or run on a device by Claude; speed unverified."),
        ("2.1.5", "Build 96: the Languages sheet rows animate and give feedback on selection (bounced check, press feel, capsule Get buttons and recent-pair chips); Diagnostics charts animate as samples arrive. Settings sub-pages keep the shared grouped page and glow. Not compiled or run on a device by Claude; speed unverified."),
        ("2.1.4", "Build 95: the Start button hit area now fills the whole circle (the system picker's inner button used to stay small), so a tap anywhere starts capture and the floating window. Translate shows Start capture, Pause or Resume, Floating window and Session tiles again; the toolbar is one More menu. Library detail uses rounded surfaces. Not compiled or run on a device by Claude; speed unverified."),
        ("2.1.3", "Build 94: every screen gets the same treatment. Diagnostics pages, the Translate controls, test row, recent list and live caption sit on rounded surfaces over a grouped background; Library, the Languages sheet, the Session and Tune sheets, Focus settings, Scenes and Onboarding share the grouped page with the soft accent glow. Not run on a device by Claude; speed unverified."),
        ("2.1.2", "Build 93: the whole app gets more life. Settings is rebuilt as colour-tile rows in rounded groups (Translation, Reading, Floating caption, Look and feel, Device and data, Advanced) under a summary of your current setup, without the oversized system buttons; every settings page has tighter rows. A soft accent glow sits behind Translate, Diagnostics and Settings, the Diagnostics page chip slides between pages with a haptic tick, pages fade in, rows spring when pressed, and the mode picker ticks. Not run on a device by Claude; speed unverified."),
        ("2.1.1", "Build 92: refinement after owner feedback on build 91. Diagnostics gets its page chips back, pinned under the title (Live, Speed, Timeline, Pipeline, Language, Device, Memory, Test runs, Log), and the Live page again shows what is read and shown, the pipeline strip, test evidence, session counters and the system. Idle Diagnostics is neutral, not red. Translate shows the Legacy, Hybrid and Low Latency picker with its note, Content, Speed and Area menus, and the three-mode test row again. Library rows are smaller and the blank band above the list is gone. Diagnostics buttons are normal-size and 'Go to Live' now says 'Open Translate'. Not run on a device by Claude; speed unverified."),
        ("2.1.0", "Build 91: the interface is rebuilt, not restyled. Four tabs: Translate (idle, starting, live, paused and attention are one screen with the language pair as the title, a Start button, the live caption, Focus mode and a compose bar for typed, photo and file text), Library (Saved and Recent), Diagnostics (one answer first, then lenses as their own pages) and Settings (one grouped list in five groups, with a live preview of the floating caption). Languages is a sheet from the pair. Onboarding is one screen with three live checks. The Start button morphs into the live header, Translate and Focus mode turn to landscape, wide screens get one 640 pt column, and Settings search finds single settings. Old screens and card components are deleted. Settings keys and stored data are unchanged; the only engine edit is one status message. Not run on a device by Claude; speed unverified."),
        ("2.0.0", "Build 90: fixes a Swift syntax error in the More sheet (an extra brace) that stopped the CI build of builds 88 and 89. No other change. Not compiled or run on a device."),
        ("2.0.0", "Build 89: nothing left in the old look. Buttons, cards, section headers, banners, toasts, language pickers and list rows are restyled for the whole app (larger corners, shadows, tinted actions, gradient primary button). Every Settings page opens with a header, Presets is a card screen with tap-to-apply tiles, Translation memory, Test runs, Run detail, Test report and the Simulator use the same list style, and diagnostic captions are larger. Not compiled or run on a device; no translation, capture or scheduling code changed; speed unverified."),
        ("2.0.0", "Build 88: every remaining screen redesigned. Reader has a status pill, the original in a card and a bottom control bar. Text & photos has an Original card with Photo, File, Paste and Clear tools and a larger translation. Capture area puts the shape picker first, shows what percent it reads, folds sliders away and pins Use this area to the bottom. Library has a segmented filter, richer rows and Translation/Original cards. Status and More have a headline, quick-action tiles and tool tiles. Test runs rows and the Test card show median and P95 per system as tiles. Simulator and Memory lead with number tiles. Not compiled or run on a device; no translation, capture or scheduling code changed; speed unverified."),
        ("2.0.0", "Build 87: interface rework after owner feedback. Diagnostics is a tab again (Live, Library, Languages, Diagnostics, Settings) and opens on the live numbers, with nothing hidden behind the Advanced switch and pages (Live, Speed, Timeline, Pipeline, Language, Device, Memory, Test runs, Log) one tap away. Live has a larger preview, one big start button, labelled actions and a mode picker that explains the selected mode. Settings is a card grid. Languages shows From/Into and a Download button on each row. Onboarding has a progress bar. Not compiled or run on a device; no translation, capture or scheduling code changed."),
        ("2.0.0", "Build 86: developer screens redesigned and narrowed. The Diagnostics dashboard, Test Runs, Translation memory, Pipeline simulator, Diagnostics settings and the Preset editor no longer redraw on every engine change; they read small snapshots instead. Key numbers come first and the rest is under Advanced. No setting, default or stored format changed; no translation, capture or scheduling code changed. Not measured: redraw or speed effects."),
        ("2.0.0", "Build 85: complete UI/UX overhaul. Four tabs (Live, Library, Languages, Settings) with typed navigation; one design system with System/Dark/Light and Dynamic Type; a Live screen without long scrolling plus Status, More and Test sheets; pair-first Languages with explicit actions and download state; Library with one Select mode, Filter and More menu, Undo and a Text & photos entry; a guided setup that checks the language pack and the floating window; Focus reader options in one sheet; a Capture area preview with draggable edges; one toast/banner queue; narrow view-model observation so live captions do not redraw whole screens. The translation engine, scheduling and settings keys are unchanged. Not compiled or measured on a device; speed unverified."),
        ("2.0.0", "Build 84: Test Runs. One run per broadcast in one translation system, grouped into named tests. Runs are saved automatically (30 s or longer, with captions) or on Save run, with a typed result (saved, skipped with a reason, or failed) instead of silent no-ops. Runs are stored as compressed files outside the translation-memory database, with 60-second crash checkpoints, recovered runs after a force-quit, and retention (pinned kept, newest 40, 100 MB). New Home Test card, Test Runs list and detail, and a report that names test, run label, end reason and completeness. Fixed the mode report being sanitized twice (session_* counters read zero) and five Hybrid timing metrics being dropped from exports. New setting Save test runs replaces Keep diagnostic sessions; old saved sessions are imported once. Not compiled or measured on a device; speed unverified."),
        ("2.0.0", "Build 83: rebuilt critical path for all modes. OCR: pixel-verified confirmation (a subtitle is confirmed when its text pixels stay unchanged for the normal confirmation time, replacing the second OCR read), event-driven OCR (no reads while a shown subtitle is unchanged, an immediate read when it changes), and an experimental Fast OCR. Legacy: confirmed translations reuse the warm prediction session. Hybrid: model switch guard (recover with Apple Default next to Apple Default work, Low Latency otherwise; no parallel second model). Low Latency/Hybrid: the confirmation memory probe reuses the first-sighting result. Home: mode switch, Save run, Clear test memory, Export test report. Diagnostics: one-file test report, new OCR/Legacy/Hybrid metrics, previously missing v1.9.9 events. Every change has an Experimental Features toggle. Device speed unverified."),
        ("1.9.9", "Build 82: correct cross-strategy Hybrid language-pair proximity tracking; benchmark a bounded 220ms post-Default Low Latency settling interval, with explicit request timing and source-context diagnostics. Limit optional visual-wake OCR to two early reads per second during motion, without changing regular OCR cadence or independent confirmation. Legacy v1.9.8 queue and Nominal/Fair policies preserved; device speed acceptance pending."),
        ("1.9.8", "Build 81: restore conservative matching speculation waits and bounded physical Default drain before Hybrid Low Latency recovery, discard obsolete unstarted Legacy speculation on confirmed OCR, and allow visual-change-triggered early OCR with Skip Unchanged Frames disabled. Nominal/Fair both remain full-performance states; device validation pending."),
        ("1.9.7", "Build 80 conservative hot path: avoid repeated caption Unicode normalization, temporary array construction and single-unit duplicate memory bookkeeping. Keeps all scheduling, OCR, translation strategy and output contracts unchanged; device speed still unverified."),
        ("1.9.7", "Three-mode latency experiments: bounded visually-triggered earlier OCR, smarter Legacy credible speculation, no duplicate confirmed LL/Hybrid memory probe, and Hybrid residual recovery tracing."),
        ("1.9.6", "Internal Hybrid contention-aware scheduling, generation-safe shared speculation ownership, and bounded candidate plan reuse for Low Latency and Legacy."),
        ("1.9.4", "Build 76: make rapid-text OCR, adjacent-fragment joining and active-text focus independent of Movie/Game/Comic presets, with custom preset switches and safe migration. Retains faster confirmation, exact-memory reuse, improved model handoff, and corrected diagnostics. Device speed still requires verification."),
        ("1.9.3", "Restore next-caption speculation in Hybrid/Low Latency, prevent false adaptive backoff, and unify live Diagnostics timing, counts, reset, reports and traces."),
        ("1.9.2", "Hybrid contention guard, adaptive backoff, exact-key session reuse across stale model completions, warm-up/session lifecycle metrics and regression tests."),
        ("1.9.1", "Hybrid scheduling: adaptive speculative admission with bounded recovery waits, avoids repeated session-readiness checks while translating, 30-second installed-language status cache, strategy overlap/dispatch metrics, safe identical-PiP hold reuse, and comparable full-session diagnostics. Real-device speed and quality acceptance pending."),
        ("1.9.0", "Build 71: strategy-aware language availability and download decisions, clear partial Hybrid readiness, refreshed mode switch state, no false requests for already-installed packs."),
        ("1.9.0", "Build 70: distinguish current sessions from historical model responses across app and mode switches; avoid claiming a model remains loaded; retry interrupted initial warm-up with bounded cooldown and clear skip reasons."),
        ("1.9.0", "Three explicit translation systems built on tested 1.7.2: Legacy, opt-in Hybrid Recovery and Low Latency. Separate result selection, strategy-safe session cache, next-capture settings and correlated diagnostics. Device acceptance pending."),
        ("1.9.0", "Separate reusable speculative-session ownership allows explicit obsolete-model preemption while protecting the warm confirmed session; cancelled sessions cannot be reused; exact growing captions can also share confirmed in-flight work; confirmed batches expose completed exact units to queued full-caption assembly and retry only unfinished units after incomplete batches. Complete exact RAM captions can bypass an occupied model lane without waiting for whole-caption repetition; shared complete-result assembly preserves speaker labels, protected words and glossary; saved-reuse-aware speculative backoff with recovery probes; recent fragments rejected before active-work cancellation; confirmed handoff priority at drain boundaries; explicit bypass/backoff accounting. Device performance validation pending."),
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
    var kind: String   // "ping" | "ocr" | "clear"
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
    var earlyVisualWakes: Int? = nil
    var earlyVisualWakesSuppressed: Int? = nil // 2.2.1 (D11)
    var totalEmptyOCRPasses: Int? = nil
    var lastVisualChangeAt: Double? = nil
    var effectiveOCRIntervalMs: Double? = nil
    var captureSessionID: String? = nil
    var firstSeenMonotonic: Double? = nil
    var sentMonotonic: Double? = nil
    /// v2.0.0: packets over 8,000 bytes and failed loopback sends, so
    /// Diagnostics can show whether large UDP datagrams are being lost.
    var largePackets: Int? = nil
    var sendErrors: Int? = nil
    /// v2.0.0: pixel-verified confirmations, pixel checks that fell back to
    /// OCR, OCR passes skipped while a confirmed caption was unchanged, and
    /// OCR passes started immediately because its text pixels changed.
    var pixelConfirmations: Int? = nil
    var pixelRejections: Int? = nil
    var watchSkippedOCR: Int? = nil
    var watchTriggeredOCR: Int? = nil
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
    var rapidTextTracking: Bool? = nil  // independent of preset name; movieMode is a backwards-compatible alias
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
    var focusedCaptionOCR: Bool? = nil
    var strictCaptionIdentity: Bool? = nil
    /// v2.0.0 G1/G2/G3. Nil (older app) means off.
    var pixelConfirmation: Bool? = nil
    var eventDrivenOCR: Bool? = nil
    var fastOCR: Bool? = nil
    /// 2.2.1 (E13): allow a one-character CJK line through the OCR filter. Nil (older app) means off.
    var cjkSingleCharacters: Bool? = nil
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
