# ScreenLingo v1.9.6 — architecture, hypotheses and acceptance

**Source** v1.9.5 build 77, commit `39d4046f5718f46367eea54edc577526884960a6`. **Branch** `codex/screenlingo-v1.9.6-hybrid-contention`. **PR** #29 is draft, targeted at the v1.9.5 branch. No merge to main.

## Observed baseline

See [frozen aggregate baseline](ScreenLingo-v1.9.6-Baseline.json). The v1.9.5 device sample P50/P95 first-recognized-OCR to PiP enqueue is **Legacy 498/871 ms (n92)**, **Hybrid 677/1374 ms (n79)**, **Low Latency 249/461 ms (n83)**. The 1.9.2 Hybrid 355/539ms result is an uncontrolled historical target. Timing refers to PiP sample-buffer enqueue, not physical visibility. No v1.9.6 device run is available in this branch.

## Core assumptions and uncertainty

- Apple `TranslationSession` may coordinate resource use between logically separate sessions. **Two app-side occupied lanes do not prove two physically independent hardware model runs.** Slow LL calls sometimes coincide with Default work and sometimes do not.
- A requested `.lowLatency` or Apple Default strategy is not an observable guarantee of a specific physical model. `isReady` is not proof of residency. `cancel()` can invalidate a session before the underlying call unwinds; a logical timeout does not free the physical lease.
- Stable source and exact v4 rule/protected-word key bytes must remain compatible with SQLite 2.0 and Temporary Memory. Reuse is **never** permission to display a tentative caption.
- Fair and nominal are the same **full_performance** app tier. Explicit Cool Mode, Low Power and genuinely measured resource pressure are separate.

## State diagrams

All modes:
```text
ReplayKit frame -> visual change -> Vision OCR -> independent confirmation reads
               -> stable/tentative Packet with send monotonic clock
               -> UDP loopback -> app receive -> source routing -> caption identity
               -> exact preparation keys -> strategy-safe RAM/SQLite -> model or exact hit
               -> complete ordered result -> candidate/session/rules acceptance -> PiP enqueue
```

Hybrid:
```text
tentative -> full identity and prepared plan -> optional Default speculative lease
                 |                     |
                 |  Apple API running   +-> completes -> compatible volatile cache
                 |                      (no display without confirmed exact match)
confirmed -> fresh source evidence + exact identity -> independent memory probe
                 | complete -> display immediately
                 + matching Default ready -> display
                 + matching running -> bounded A/B/C wait -> earliest complete result wins
                 + mismatch / rejected / timeout -> LL confirmed recovery lane
                                      | no LL pack -> bounded Default fallback
                                      | LL wins -> stale Default ignored while call drains
                                      | Default wins -> LL output ignored while call drains
```

Legacy:
```text
tentative -> low-priority speculative single drain -> SpeculativeSessionOwner lease
confirmed -> exact whole-caption RAM bypass (no model) or single confirmed drain
          -> safe in-flight matching work/coalesced completed units
          -> confirmed Default session -> fully assembled PiP
```
The single Legacy drain remains separate from Hybrid's independent LL lane. Cancelled speculative work retains session ownership until actual awaited return. Exact-unit preparation is cached in a bounded 12-entry, context-keyed RAM cache, retaining source/protected words/speaker semantics and original request ordering.

Standalone Low Latency:
```text
tentative OCR -> fresh source routing -> bounded exact plan cache -> LL speculative lane
independent confirmed OCR -> fresh source routing -> exact same candidate/layout?
                                   | yes -> reuse immutable units and keys
                                   | no  -> rebuild and validate
                              -> memory / matching LL speculative result
                              -> confirmed LL same-strategy recovery only if necessary
                              -> complete current result -> PiP
```
The mode plan cache has four entries; keys include capture session, candidate, source/target, system, exact blocks, layout (text + coordinates), rotation, capture config revision, rule fingerprint and context epoch. Confidence/stability is **not** reused: OCR gates still run on both independent reads. The source-language decision is repeated for confirmed evidence, so new automatic-language evidence can invalidate the tentative plan.

## Shared Apple Default execution and ownership

`Shared/SharedTranslationWork.swift` centralizes canonical v2/v3/v4 exact-context keys, missing-unit coalescing, bounded preparation reuse and `AppleDefaultLeaseState`. Both `Shared/SpeculativeSessionOwner.swift` (Legacy) and `App/ModeTranslationService.swift` (Hybrid) now use the shared physical lease state contract. The adapters intentionally hold separate `TranslationSession` instances and outer scheduling: routing Hybrid's LL fast lane into Legacy's single drain would sacrifice valid fast-lane wins. The shared lease records cancellation independently from actual return, gates session reuse and prevents a second request while occupied. Reset makes even a successful late completion unreusable. This is a shared ownership contract, **not** a claim that the underlying Apple frameworks share model instances.

## Hybrid internal-only variants

- **A `reference195`**: v1.9.5 matching wait and admission predicate for comparison.
- **B `recoveryFirst`**: same matching wait; blocks *new* Default speculation when confirmed LL demand is awaiting availability/queued or physically executing; leaves already-running matching work eligible to win.
- **C `evidenceBounded`** (code default): B's confirmed-priority gate, and bounded matching hedges based on a finite sample of completed Default/LL service times, current speculative elapsed time and measured contention feedback. Limits matching wait to at most 580 ms under contention; retained useful/waste feedback and no unlimited retries. Near-ready matching Default may win before LL starts; verified fast LL without recent contention can be dispatched directly. Any incomplete/mismatched output is never selected. The policy is unchanged by the string 'fair'.

A/B/C are internal experiment labels; they are not a new user-facing preset or persistent setting. Source tests and fake service-time cases validate bounded decisions. No policy guarantees physical concurrency or an end-to-end speedup.

## Monotonic instrumentation

The ReplayKit extension now adds an optional monotonic packet-send timestamp; the app computes transport timing from the same boot uptime where available and retains backwards compatibility with old packets. The app also measures exact plan built vs reused, confirmed-to-PiP, committed-result-to-PiP and commit-to-PiP separately. Existing metadata-only candidate+revision+SHA256 fingerprint event traces track request submissions, availability, queues, inferred logical overlap, service and stale rejection. Diagnostic ring overflow has an explicit counter; bounded aggregate distributions continue after ring eviction. ZIP keeps allowlisted numeric stage metrics, never raw OCR, protected words, translation text or coordinates.

## Gates and experimental interpretation

Deterministic fake mode tests and the real Xcode build are correctness and software-overhead gates, not device latency evidence. The separate baseline L0/F0/H0 is the original immutable commit; proposed L1/F1/H2 are reviewed against that commit. Run at least three counterbalanced 5-minute PT→EN captures per mode/build under matched settings and compare normalized hashed fingerprints by nominal and fair cohorts. Report P50/P90/P95, sample count, paired uncertainty, number of memory hits, model/queue distribution, real logical overlap and residual service, and wrong/partial/blank subtitle counts confirmed against manual or video ground truth. The synthetic 20–25ms overhead-injection tests verify instrumentation sensitivity; they do not demonstrate production CPU savings.

Release status is **NOT YET VALIDATED** for Legacy, Hybrid and standalone Low Latency until those device comparisons establish material improvements without correctness, memory or P95 regressions. The v1.9.5 release branch and main remain untouched. The PR stays draft.
