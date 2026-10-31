# ScreenLingo v1.9.5 engineering audit and verification boundary

**Baseline:** v1.9.4 build 76, PR #27, `codex/screenlingo-v1.9.4-measured-reliability`.  
**Implementation:** `codex/screenlingo-v1.9.5-full-performance`, draft PR #28.  
**Boundary:** "latency" below is first OCR sighting to PiP sample-buffer enqueue. Actual onscreen display timing and translation correctness are not inferred.

## Reference measurements

| Mode | v1.9.3 P50/P95 ms | v1.9.4 P50/P95 ms | Interpretive limitation |
| --- | ---: | ---: | --- |
| Legacy | 550 / 1017 | 621 / 934 | v1.9.4 was fair; v1.9.3 nominal |
| Hybrid Recovery | 382 / 1409 | 496 / 1390 | mixed nominal/fair v1.9.4 cohorts |
| Low Latency | 232 / 442 | 241 / 451 | nominal in both compared runs |

Hybrid v1.9.4 nominal P50 = 385 ms (n=18) and fair P50 = 539 ms (n=49). These are not controlled proof of thermal causality. Hybrid Apple Default speculative P50 = 739 ms versus standalone Legacy 266 ms; confirmed Low Latency P50 = 49 ms, P95 = 1505 ms. Twelve observed Hybrid recovery-overlap samples distinguished ~1209 ms whole service median from ~303 ms simultaneous model-occupancy median. Different timestamps, resource contention, warm status, and backend availability may contribute; logical concurrency never proves separate physical execution.

## Actual execution and ownership

### Shared capture and OCR

`BroadcastExtension/SampleHandler.swift` receives ReplayKit frames, plans area and edge/cadence through `Shared/AdaptivePipeline.swift`, applies `Shared/SubtitlePerformancePolicy.swift` confirmation intervals and OCR recognition, and sends candidate/confirmed packets to the app. `App/TranslatorEngine.swift` receives through `App/LoopbackServer.swift`, enforces capture-session identity, subtitle selection, source-language routing, rules and candidate revision. Every mode retains independently confirmed OCR evidence and protected-name/line-grouping behavior.

### Legacy

`App/TranslatorEngine.swift` checks exact assembled-caption RAM, queues `enqueue`, serially drains through `drain`/`process`, prepares translation units, consults RAM and SQLite (`App/TranslationMemoryStore.swift`), coalesces compatible model work and calls `translateBatch`. `Shared/SpeculativeSessionOwner.swift` leases a separate speculative session; cancelled Apple work remains physically owned until the awaited request returns. `Shared/SharedTranslationWork.swift` now supplies the same canonical v2/v3/v4 exact-context unit key used by Hybrid without altering persisted memory bytes. Completed eligible result assembly proceeds to `schedulePresentation`, the PiP enqueue path. Legacy's serial drain and request/coalescing semantics were intentionally preserved.

### Hybrid Recovery

`App/TranslatorEngine.swift:handleModeCaption` prepares a `ModeCaption` with source, target, rules, ordered units, canonical exact-context keys, capture session and revision. `Shared/TranslationSystem.swift:ThreeModeCoordinator` admits a tentative Apple Default request and starts independent confirmed memory lookup after OCR confirmation. The `App/ModeTranslationService.swift` speculative and confirmed lanes retain separate `TranslationSession` objects and busy flags. A still-matching Apple Default completion can win over the Low Latency recovery hedge; otherwise confirmed recovery selects Low Latency when installed and may use a bounded installed-Apple-Default fallback. `ThreeModeCoordinator.commit` requires current identical candidate, complete output and winning selection before `selectModeResult` assembles it and schedules PiP.

Admitted speculation is rejected when a lane or warmup is physically busy; availability checks and lane waits can add latency. Cancellation and timeout invalidate display ownership, not necessarily the underlying operating-system request. `ModeTranslationService` records full confirmed model service, simultaneous speculative/confirmed occupancy, availability, dispatch, queue and session reuse separately.

The v1.9.4 `HybridAdmissionPolicy` used **full recovery duration** to issue a long speculative backoff when a threshold was exceeded. v1.9.5 instead consumes both full service and measured simultaneous overlap and applies bounded backoff only for substantive measured contention. A 900 ms recovery with 100 ms actual overlap has a different decision from one with 600 ms actual overlap. The policy also retains independent repeated-waste feedback and usefulness recovery.

### Low Latency

The same coordinator selects Low Latency for tentative and confirmed requests; the `ModeTranslationService` fast lane and existing installed-language/session-reuse logic are retained. The shared key planner adds no model calls, does not place Low Latency behind Legacy's drain, and does not change the Low Latency model strategy. No observed speedup is claimed; matched-device P50/P95 241/451 ms is the guardrail.

## Thermals and recognition features

`ThermalPerformancePolicy` is the shared policy contract:

| Thermal state | App tier | Automatic thermal reduction |
| --- | --- | --- |
| nominal | full_performance | none |
| fair | full_performance | none |
| serious | protected | allowed |
| critical | emergency | stronger protection allowed |

The extension's rapid confirmation, app's adaptive-pressure flag, Legacy Cool Mode eligibility, simulator and background legacy-validation caller now use the same protection threshold (serious/critical), without inferring workload or memory pressure from fair. Nominal and fair share one Hybrid timing-history cohort. Thermal metadata no longer participates in `ModeCaption` identity equality, so a thermal change does not revoke a valid caption. Active app capture configurations resync on a state transition. Explicit Cool Mode, iOS Low Power Mode, measured low-memory pressure and actual queued work have independent observable reason codes.

Custom Movie/Comic/Game/Lyrics presets continue to select `rapidTextTracking`, `joinAdjacentText` and `activeTextFocus` individually, including migrated presets. They are not permission gates for OCR algorithms.

## Test and instrumentation evidence

The source-parity CI gate, `Tests/main.swift` all-mode/all-preset simulated parity and thermal-transition assertions, `Tests/ThreeModes/main.swift` Hybrid overlap/admission and identity cases, and `Tests/DiagnosticArchive/main.swift` recovery finding/privacy checks are part of the proposed branch. `App/Diagnostics.swift` reports actual app-requested edge/interval and the current tier/reduction reasons. `App/DiagnosticArchive.swift` retains bounded metadata and flags sustained Hybrid long recovery and missing true-overlap measurements when supported by sample counts. Existing SQLite schema and key bytes are unchanged.

**Evidence not supplied by code or simulator:** hardware execution under nominal/fair, v1.9.5 physical model contention, paired v1.9.4/v1.9.5 speedups, on-screen PiP display times, completeness of unseen OCR lines or ground-truth translated accuracy. Full native CI and repeatable PT→EN video sessions (three or more counterbalanced runs per mode/build, plus fresh-only and normal-memory cohorts) are required before performance claims or release. The draft PR must not be merged until those gates are satisfied.
