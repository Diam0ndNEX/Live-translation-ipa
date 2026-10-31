# ScreenLingo v1.9.8 build 81: scope, evidence, and release gates

**Base:** v1.9.7 build 80, commit b455256420cac5a45c37f1d343681f727c4f519b (draft PR #31).
**Branch:** `codex/screenlingo-v1.9.8-three-mode-performance`; `main` and the v1.9.7 branch remain unchanged.

## Prior diagnostic evidence (not causal proof)

| Mode | v1.9.6 P50/P95 (ms) | v1.9.7 P50/P95 (ms) | Proposed v1.9.8 target (ms) |
| --- | --- | --- | --- |
| Legacy | 543/919 | 507/940 | <=475/850 |
| Hybrid Recovery | 530/1068 | 570/1497 | <=450/850 |
| Low Latency | 248/440 | 250/466 | <=225/410 |

Latency is first OCR sighting to PiP enqueue, not the subtitle's onscreen appearance. v1.9.7 logged renewed cross-strategy overlap and Hybrid confirmed service outliers, elevated Legacy queue time, and **zero** visual early wakes when `skipUnchanged` was off. Differences across recordings may include model state and memory workload.

## Changes

1. **Hybrid:** v1.9.7's shortened 25ms speculative matching preflight is removed; the already-bounded v1.9.6 matching wait is restored. Confirmed Low Latency now waits at most **450ms** for a physically busy Apple Default speculative lane to finish. Every poll verifies that the request is still eligible; if the budget expires, Low Latency can proceed and any overlap is recorded. This is intentional bounded protection, not a claim of independent hardware scheduling. No unbounded wait or premature release of session ownership.
2. **Legacy:** independently confirmed OCR drops superseded **unstarted** speculation from the serial pending queue. Previously active model work retains cancellation, context identity, and physical ownership safeguards. Existing confirmed RAM bypass remains intact.
3. **Recognition:** visual wake-up uses the configured rapid-text toggle instead of the unchanged-frame-skipping toggle. The extension retains a lightweight reference signature on normal OCR reads even if skipUnchanged and detailed diagnostics are off; a changed signature may pull a normal OCR pass forward. No visual comparison suppresses a due OCR when skipping is disabled. The OCR's configured ROI, resolution, confidence, correction and independent confirmation conditions do not change. More visual probes/false-positive OCR may increase energy; confirm on device.
4. **Thermals:** Nominal and Fair remain full-performance application tiers; only Serious or Critical trigger automatic thermal reductions. Cool Mode and actual resource pressure are independent opt-ins/conditions.

## Evidence and acceptance

- CI: native Swift pipeline and three-mode tests; source contract; transport, SQLite migration, diagnostic privacy, iOS Release app and ReplayKit extension, unsigned IPA artifact.
- Native unit tests validate bounded recovery drain policy, restoration of matching preflight, confirmed priority, and skip-independent OCR-wake policy. Source check verifies actual ReplayKit wiring.
- **Not yet established by code or CI:** all three modes' real-device speed, absence of flicker or missing subtitles, Apple model contention mechanism, thermal Fair hardware behavior, and exact user-visible PiP timing.
- Compare unchanged build 80 and build 81 on same device/video, same preset/ROI/languages, same skip setting, and matched Nominal and Fair cohorts. Do at least three counterbalanced runs per mode per condition with Normal Memory, Temporary Memory and Fresh-only recorded separately.
- Evaluate end-to-end P50/P90/P95, matched subtitle fingerprints, visually verified text coverage, screen recordings, per-lane service and queue times, `hybrid_physical_default_drain_wait_ms`, `hybrid_default_drain_budget_exceeded`, `hybrid_cross_strategy_overlap`, Legacy queue waits and `earlyVisualWakes`.
- Revert or revise any optimization that fails to improve all three modes without unacceptable P95, correctness, power or thermal regressions. Keep PR draft; passing compilation never proves performance targets.
