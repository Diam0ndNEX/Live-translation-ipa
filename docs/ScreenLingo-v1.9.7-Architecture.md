# ScreenLingo v1.9.7 — pinned baseline, owners, alternatives and acceptance

**Parent:** `3721d616ce4dbfd2dc7891d4f968c83efbe8da26` on `codex/screenlingo-v1.9.6-hybrid-contention` (draft PR #29, passing CI #41166347423). **New branch:** `codex/screenlingo-v1.9.7-three-mode-gains`; draft PR #30 against v1.9.6. **No main or source-branch modifications.** v1.9.6 build 78 IPA retained as fallback, including reference SHA. This file describes experimental source code, not established device speed.

## Device baseline (unpaired, nominal)
See [frozen baseline](ScreenLingo-v1.9.7-Baseline.json). Legacy **543.5/918.6ms** P50/P95 (n92), Hybrid **530.1/1068.2ms** (n83), standalone LL **248.1/440.3ms** (n86), all first recognized OCR→PiP enqueue. P90, paired fingerprints, session-level intervals, device temperatures and ground-truth accuracy for v1.9.7 are **unavailable**. Per-caption timing medians overlap; never add stage P50s. The requested raw 1.9.6 diagnostic archives are named in the baseline but were not attached to this implementation turn; the explicit aggregate measurements supplied by the user are the evidentiary source.

## Async owners and cancellation

```text
ReplayKit extension process: recognitionLock (one Vision request at a time), capture/config epoch,
  SubtitleTracker (independent reads), signal sample, UDP packet; no text ever stored in app diagnostics
  ↘ app transport/CandidateValidity: capture session, candidate revision, filtered source fingerprint
  ↘ TranslatorEngine @MainActor:
      Legacy: generation/context revision → confirmed high-priority single serial drain →
        SpeculativeSessionOwner (physical lease through real return) / confirmed Default warm session
      Hybrid: ThreeModeCoordinator atomic current/committed latch →
        ModeTranslationService speculative Apple Default lane + independent LL recovery lane
      LL: same coordinator with two LL lanes; never enters Legacy drain
      Memory: process-owned temporary RAM or normal SQLite actor with independent confirmation gate
      PiPRenderer: complete ordered caption, exact candidate/session/rules guards, frame enqueue
```

`Task.cancel()` requests cancellation; it does not free physical lease ownership. Hybrid's `lane.busy` persists until Apple's call really returns, including the 4-second logical timeout. Legacy speculative owner likewise only releases on the awaited physical result. Cached exact key bytes and SQLite schema are unchanged; Fresh Requests never reuse; Temporary Memory never persists. A confirmed caption never displays speculative text until independently confirmed and exact identity matches.

## Isolated experimental variants — predicted critical-path effects, not measured savings

**Legacy L0 vs L1:**
L0 is v1.9.6 admission order. L1 (`SCREENLINGO_REFERENCE_LEGACY_ADMISSION` absent) checks the configured OCR confidence/letters gate before charging the bounded adaptive speculation opportunity budget. It additionally allows a maximum of 3/4 high-confidence probes when at least 2 of the last 16 independently confirmed model predictions were used and saved-memory dominance is absent. Model-busy and one-job serial ownership are unchanged. Predicted reduction: additional exact speculative units ready at confirmation; could be zero, or negative from excess work. Counters separately log low confidence, low yield, saved memory, busy physical lane and duplicate OCR. With insufficient matched device evidence, **L1 remains UNVERIFIED** and can be compiled out.

**Standalone LL F0 vs F1:**
F0 retains normal v1.9.6 capture cadence. F1 (default; `SCREENLINGO_REFERENCE_CAPTURE_CADENCE` absent) allows an optional due-soon OCR pass at >= max(120ms, real prior Vision service, 72% of planned interval), only when rapidTextTracking AND skipUnchanged are enabled, nominal/fair effective policy is full and there is no independent Cool/Low Power/resource pressure. It samples a bounded 24×24 (or user-enabled ROI 48×24) signal no more often than 65ms, requires a changed visual signature, keeps regular cadence on non-changes, and never changes Vision image resolution, confidence, correction, OCR read count, language or translation strategy. False visual change may cost CPU/battery; it never confirms text or suppresses the normal pass. Predicted maximum common-case gain is only the difference between normal and due-soon capture start (roughly tens of ms on a 220ms base), not a proven 25+ms P50. The existing standalone LL plan-cache A/B flag remains `SCREENLINGO_REFERENCE_LL_PLAN` and its ~0.2ms build time is NOT being advertised as a major win.

**Hybrid H2 vs H2+ (plus H0/H1):**
v1.9.6 variants remain H0 reference195 (`SCREENLINGO_HYBRID_REFERENCE`), H1 recoveryFirst (`SCREENLINGO_HYBRID_RECOVERY_FIRST`), H2 evidenceBounded (default). The new H2+ preflight gate gives an unsubmitted matching Apple Default request at most **25ms** to produce a valid complete cached result before starting independent confirmed LL recovery; a physically submitted matching Default retains the original bounded hedge and can still win. Missing LL assets retain Default fallback. Under identical source evidence, a 400ms expected unsubmitted Default wait could reduce by up to ~375ms, but spec pending and session availability are significant confounders. `SCREENLINGO_REFERENCE_HYBRID_PREFLIGHT` is reserved for isolated revert of this new preflight behavior without changing H0/H1/H2. No H3 residual-cooldown policy is enabled without actual event-level evidence.

**Shared confirmed memory F0/H0 vs F1/H2+:**
`ThreeModeCoordinator` performs an independent exact confirmed RAM/SQLite probe once and provides its immutable result to the recovery/fallback resolve path. `SCREENLINGO_REFERENCE_CONFIRMED_PROBE` restores v1.9.6's duplicate probe for isolated A/B. A mismatched revision, changed work epoch, changed source/rules or capture reset clears it. Predicted saved time is a repeated memory lookup (often small for Temporary RAM, potentially larger for SQLite); it cannot change approved memory keys or final PiP identity.

## Residual Hybrid tail is NOT explained by overlap-at-admission=0

The new service correlator distinguishes: LL began with a concurrent Default busy lane; LL began within 1.5s after a same-language-pair Default physically returned; and LL began without either observation. It logs `backend_apple_call_entered`, `backend_apple_call_returned`, Default-to-LL gap, post-Default LL service, no-recent-overlap service, and unexplained >800ms service. These are **logical app observations**, not true hardware residency. A cancelled physical call still occupies the lane until actual return. There is no false hardware-parallelism claim.

## Thermal and content-preset contract

Nominal and Fair map to `full_performance`. Serious→protected, Critical→emergency. User Cool Mode, iOS Low Power and actual workload/memory backpressure are separate. Both F1 and Legacy L1 are driven by the existing independent feature toggles, not Movie/Game/Comic/Lyrics names. Custom presets retain rapidTextTracking, joinAdjacentText and activeTextFocus individually. Only the original user-intended rapid-text and unchanged-image toggles permit the extra visual-change wake; disabling them leaves the normal schedule unchanged.

## A/B evidence and release gates

Keep the actual v1.9.6 5-minute PT→EN Balanced/Movie/Temporary/nominal reference build as L0/H0/F0. Isolate each feature, counterbalance on the same iPhone and clip, >=3 **independent paired sessions** per mode and thermal cohort where physically attainable. Include Normal Memory, Temporary Memory and Fresh Requests as distinct cohorts. Compare P50/P90/P95 and bootstrap sessions/blocks rather than pretending subtitles are independent. Report checksum, fingerprint match coverage, missing dialogue, flicker/visual evaluation, battery/thermal, memory migrations and latency P95; reject any candidate that worsens P95 or correctness. This draft contains no real v1.9.7 device trials or quality footage, so **Legacy UNVERIFIED, Hybrid UNVERIFIED, LL UNVERIFIED**. No release, merge or v2.0.0 label.
