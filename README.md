# ScreenLingo 1.1.0 (40)

## Changes

- Fixed the empty language graph when a source is explicitly selected. Confirmed source inputs now count for selected, automatically detected and locked source languages. Chart labels distinguish usage from detection; a selected Portuguese source is never reported as an automatic detection.
- Speculative sightings and target-language passthroughs do not inflate the language counters. Reset clears language and selection-mode totals together.
- Reports and CSV exports include source-language and source-choice counts. Text reports include configured source, last source used, app phase, PiP state, packet/sample times and capture settings.
- Foreground, inactive and background transitions are recorded alongside the existing capture/PiP events, making future background traces easier to interpret.
- Removed the requested memory explanation from the interface and report.

Translation selection, source filtering, OCR quality and rotation behavior retain the 1.0 implementation.

## How diagnostic graphs get their data

The ReplayKit extension counts incoming video frames, OCR passes/skips and OCR durations and sends timestamped packets to the main app over localhost UDP. The app records packet delivery, processing, source usage, caching and presentation timings during the real pipeline. A timer samples the iOS battery, thermal and process-memory APIs every two timer ticks while the app is executing. Swift Charts draws the bounded arrays of samples; opening the diagnostics screen is not required to collect them.

The project uses the Audio/AirPlay/Picture in Picture background mode with the visible PiP translation window. Live Activities are not the mechanism that runs the translator. Background execution remains controlled by iOS: if the app is suspended, its timers and graph collection stop executing until it resumes. ReplayKit's broadcast extension has its own lifecycle. A pre-1.1 trace cannot establish foreground/background timing because those transitions were not recorded.

## Supplied v1.0 trace

Across 143 paired displayed results, average total time was 878 ms: confirmation 148 ms, final OCR 113 ms, delivery/filtering 90 ms, queue 260 ms, processing 282 ms, readability hold about 0 ms and frame preparation 1.4 ms. The trace recorded no translation failures and no capture drops, but six automatic rotation attempts. Without source text or images, the export cannot establish whether those rotations or the translated wording were correct.

## Build and verification

The `codex/screenlingo-v1.1.0` branch builds the unsigned IPA after focused Swift regression checks and verifies both bundle versions. Main and previous branches remain unchanged. The simulator preview remains an optional manual workflow input.

Regression coverage includes manually selected Portuguese, automatic detection, locked sources, unresolved-source placeholders, reconciled counters and reset, alongside the existing pipeline, timing, grouping, export and stale-output checks. Physical-device verification is still needed to confirm the new counters and lifecycle events during a broadcast.
