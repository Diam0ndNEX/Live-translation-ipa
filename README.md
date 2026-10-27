# ScreenLingo 1.0.0 (39)

## Waiting and display latency

Translation work no longer waits behind minimum display time. It starts as soon as confirmed input reaches the queue. Readable mode schedules only the remaining hold after translation finishes, without blocking the processing queue. Immediate mode has no optional readability hold. Both keep complete-result validation, OCR confirmation, source filtering, protected terms and stale-result checks. Existing nonzero minimum-display preferences migrate to Readable mode.

A pending result is cancelled on newer accepted OCR, language/settings changes, clear, pause or freeze. Timing metadata is captured with the result so delayed presentation does not inherit a later packet's timings.

The old diagnostics chart computed “Waiting & display” by subtracting unrelated average translation and transfer times from average total time. That remainder also contained OCR, confirmation and other work. Version 1.0 replaces it with matched displayed-result records for confirmation, final OCR, delivery/filtering, queue, processing, optional readability hold and frame preparation. CSV and text reports include these stages. Total ends at frame enqueue; it does not measure physical screen presentation.

## New settings

Four grouped settings pages cover timing/responsiveness, caption layout, reader/workspace, and feedback/storage. Controls include immediate/readable display, minimum visible time, translate-ahead, idle heartbeat, caption weight/alignment/spacing/padding/scale/original-text allocation/speaker colour, reader font/spacing/width, photo OCR resolution/automatic translation, Live timing visibility/expanded panels, haptic strength, clipboard format, speech interruption, history capacity, translation-memory capacity and diagnostic sample capacity. Caption and timing preferences participate in presets and backup.

Defaults retain previous OCR accuracy, resolution, confirmation count and translation model. Optional photo resolution changes are explicit user choices, separate from live capture. A heartbeat repeats an idle frame; fresh translations always enqueue immediately.

## Memory

The memory API reports the extension's remaining per-process allowance, not free phone RAM. iOS may change that allowance. Stable headroom is expected with bounded buffers and temporary-image cleanup. It is not a score that should reach 100 MB. The diagnostics and storage screens link Apple's API explanation.

## Build and checks

The `codex/screenlingo-v1.0.0` branch runs Swift regression checks, builds both iOS targets, verifies versions/identifiers and uploads `ScreenLingo-ipa`. Unzip it before signing. Main and previous release branches remain unchanged.

The iPhone simulator screenshot is now an optional manual workflow input. The 0.9 UI was successfully launched and captured, and the user confirmed its appearance on device. Normal IPA builds avoid repeating the expensive simulator startup.

Regression checks cover request identities/order/failures, protected-name isolation, subtitle grouping, partial input, CSV/crop rules, OCR cadence, font-size equivalence, overlapping readability holds and pending-result invalidation. Physical-device speed and translation quality still need like-for-like testing with the same video, language pair, settings and thermal state. No universal speedup percentage is claimed.
