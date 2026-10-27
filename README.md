# ScreenLingo v1.3.0 · build 43

This release upgrades recognition, candidate tracking, speculative work, memory, presentation and diagnostic accounting. It preserves Fast/Balanced/Sharp and the fixed Instant/Normal/Careful read controls. New strategies are in **Settings → Smart pipeline**, saved with presets and backups.

## Behavior and controls

| Control | Default | Behavior |
|---|---|---|
| Auto reading preset | Available | Adapts detail/frequency from recent confidence, text height, OCR cost, motion, empty reads and unchanged text |
| Adaptive detail in Balanced | On | Uses 1000-pixel detail for exceptionally clear large text; requests up to 2000 for small/uncertain text; Fast/Sharp retain their base profiles |
| Confidence-aware confirmation | Off | Optional immediate release for exceptionally clear text; uncertain text receives further checks; a configurable deadline requires two matching, sufficiently confident reads |
| Subtitle tracking | On | Tracks the complete visible subtitle/lyric group by content, geometry and lifetime; a changed candidate invalidates older pending work |
| Merge duplicate copies | On | Coalesces duplicate whole regions and keeps a stable spatial anchor; repeated lyric rows within a region remain intact |
| Selective pre-translation | On | Declines early text below the configurable confidence floor; existing Translate ahead remains the master control |
| Stable caption transitions | On | Cancels superseded work where supported and prevents outdated candidates from storing results or reaching PiP; the previous valid caption remains until replacement/normal auto-clear |
| Smart Cool controller | On | Applies when Cool Mode is enabled; changes frequency before detail and permits only exceptionally clear speculation under nominal thermal/low workload conditions |
| Automatic recovery | On | Resets source evidence after repeated engine failures; missing packs are surfaced, not treated as evidence of a wrong language |

The fixed-pipeline button disables adaptive detail/confirmation, tracking, duplicate merging, selective speculation, stable transitions and Smart Cool behavior. It leaves the safety fixes and versioned persistence active. Auto always adapts; select Fast/Balanced/Sharp for fixed-profile comparison.

Runtime pressure/frequency changes no longer reset OCR confirmation. Language, crop, rotation, recognition rules and explicit capture revisions still require fresh confirmation. Automatic OCR stays multilingual and never inherits a hard translation-language lock. Target languages cannot acquire a source lock.

## Memory and work accounting

- Session cache, saved-memory retrieval and speculative hits are separate sentence counters. A saved entry's first retrieval is a saved-memory hit; later reuse is session cache.
- Persistent memory uses a versioned envelope in Application Support. Rule fingerprints namespace the cache for source clean-up, slang, protected names, speaker splitting, glossary and source fixes; source/target and protected token context remain part of each key.
- Only confirmed non-private input with an explicit or sufficiently confident source can promote an entry to persistent storage. Unconfirmed speculative results remain session-only. Failed/empty responses are never stored.
- Previous unversioned cache files are left untouched and are not trusted as rule-versioned entries. Clearing memory invalidates in-flight work and uses actor-serialized revisions to prevent stale saves restoring cleared entries.
- Speculative pipeline attempts/completions/discards and model request counts are separate from sentence-level cache hits. Elapsed discarded work includes pipeline processing; completed but unconsumed entries may still be useful later and are not automatically called wasted.

## Diagnostics

Simple collection keeps summaries and lightweight work counters. Detailed collection adds bounded graph samples, events and a 300-entry per-candidate lifecycle log (first arrival, confirmation, processing, cache origin, readiness, supersession and frame enqueue). The Pipeline page and CSV expose it without exporting source sentences. Collection/view controls stay in the sliders menu beside the three dots.

Confidence, recognition/confirmation reasons, unchanged/cadence/paused frame skips, empty reads and contrast retry counts are included. Instrumented recorder self-time is measured separately for simple and detailed collection; nested calls are not double-counted. It excludes asynchronous chart rendering, OCR and translation, and different workloads must not be treated as a controlled overhead benchmark.

PiP timing ends at sample-buffer enqueue. Physical display presentation is not measured. Translation APIs support cancellation cooperatively; obsolete results are rejected even if a model finishes after cancellation. The iOS 18 hosted bridge releases cancelled requests instead of holding confirmed work behind its timeout. Prewarming snapshots its language pair before any suspension to prevent old-session reuse after a target change.

## Evidence and verification

The available 14:39 v1.2.0 export recorded an English source lock with English as the target, seven rotation attempts and two capture interruptions. Source sentences were omitted, so it does not establish semantic accuracy or the cause of capture interruptions. A newer Auto export was requested but was not attached when this upgrade began; no new device performance or heat improvements are claimed from that earlier trace.

CI compiles and runs the existing pipeline/grouping/export/timing/language checks plus adaptive detail, confirmation, candidate identity, duplicate-region, privacy, rule-versioning and real memory persistence/revision checks, then builds the iOS app and ReplayKit extension and verifies both bundle versions. Repeatable on-device video comparisons are still needed to quantify recognition coverage, latency and thermal/battery changes.
