# ScreenLingo v1.9.9 — Retrospective and experiment validation

**Source**: v1.9.8 build 81, commit `c04465b89734e1d6715f9364f033f10089e40747`.
**Branch**: `codex/screenlingo-v1.9.9-recovery-evidence`. Do not edit `main`.

## Historical branches inspected

- `codex/screenlingo-v1.9.2-hybrid-reliability` (`bb53d33f`) — historical Hybrid P50/P95 ~355/539 ms, under earlier workload conditions. Its much simpler speculative-admission feedback did **not** guarantee protection from simultaneous Apple strategies. Do not wholesale transplant old admission code.
- `codex/screenlingo-v1.9.5-full-performance` (`39d4046f`) — Legacy P50 ~498 ms; not a direct Fair-thermal comparison.
- `codex/screenlingo-v1.9.6-hybrid-contention` (`3721d616`) — stronger Hybrid P50/P95 ~530/1068 ms, supported by late speculative admission checks and an evidence-bounded matching window.
- `codex/screenlingo-v1.9.8-three-mode-performance` (`c04465b8`) — Legacy 515/817 ms, Hybrid 587/1521 ms, Low Latency 242/441 ms at Fair. Nominal/Fair application parity was maintained.

## Root-cause evidence and v1.9.9 experiments

1. v1.9.8 tracked `lastFinishedPair = availabilityKey` with `availabilityKey` suffixed by `|appleDefault`, then checked it against the `|lowLatency` key. This can **never match between strategies**, so slow recoveries following Default completion were misclassified. Fix: retain the strategy-free source>target language-pair key and keep strategy-specific availability cache untouched.
2. Reanalysis of retained v1.9.8 Hybrid model-enter/return timestamps indicates approximately 15 LL recoveries starting within 150ms of the most recent Default model return were each ~880–980ms. Older gaps often have shorter recoveries. This is an observational correlation; hardware, Apple framework scheduling and scene states are not independently measured.
3. **Experimental, bounded 220ms post-Default settling** applies only when a Hybrid confirmed LL request has a same-language-pair recent Apple Default return. The wait is adaptive to elapsed time and never applies to standalone LL or Legacy. `SCREENLINGO_REFERENCE_HYBRID_EXIT_SETTLING` disables it for an A/B IPA. It can raise end-to-end latency if the Apple backend remains slow; do not claim a win without paired tests.
4. **Bound optional early visual wakes to two per one-second window** while keeping the ordinary OCR cadence, chosen ROI/detail, independent confirmation and confidence gates unchanged. This can reduce video-motion-triggered OCR excess but may reduce the extra early wake opportunities during very rapid scene changes; test subtitle-coverage and onset-to-PiP separately.
5. Preserve v1.9.8 Legacy queue and cache safety rather than replace its successful 817ms P95 with older scheduling. Do not alter SQLite cache-key bytes, session cancellation/ownership or existing Normal/Fair policy.

## Diagnostics required

Track `hybrid_previous_default_exit_gap_ms`, `hybrid_post_default_settlement_wait_ms`, `hybrid_recovery_post_default_service_ms`, `hybrid_slow_post_default_ms`, `hybrid_recovery_no_recent_overlap_service_ms`, `hybrid_cross_strategy_overlap`, `hybrid_default_drain_budget_exceeded`, and `earlyVisualWakes`. Compare distributions by actual session, pair, strategy, and thermal bucket. Do not equate logical lane flags with Apple hardware residency.

## Acceptance

- Native Swift and source tests, reference-variant compile, SQLite migrations, ReplayKit capture, iOS Release build, unsigned IPA.
- Real-device tests: same video/language/preset/ROI, equivalent memory state, three counterbalanced runs per mode in Nominal and Fair where feasible. Include Fresh Requests and Temporary Memory separately; screen-record subtitle coverage and PiP flicker.
- Target improved Hybrid P50 and P95 without increasing high-latency recoveries; preserve or improve Legacy 515/817 ms and Low Latency 242/441 ms against matched Fair reference. No reduced OCR coverage or changed quality thresholds.
- A successful CI build **does not** prove any performance improvement. Keep PR in draft until measured.
