# ScreenLingo 0.9.0 (38)

Screen translation on device, with a redesigned Live screen and a new screen-and-translation icon. Built on the complete 0.8.0 workspace, reader, library and settings; previous branches and main remain unchanged.

## Interface

The Live screen now centers on the language pair, preview and capture controls. Readiness guidance appears before capture starts; output actions disable when unavailable. Quick settings and diagnostic details collapse to keep the main screen focused. Text/photo translation, the area editor, presets, recent pairs and session controls remain directly reachable. Library, Languages, Activity and Settings use native navigation. Accent changes no longer recreate the tab hierarchy.

## Latency work without reducing recognition quality

- OCR is scheduled from the start of its previous pass. The old code always waited another entire interval after OCR completed. The accuracy level, resolution, confidence thresholds and confirmation count are unchanged. Thermal, low-memory and power protections remain enabled.
- Exactly repeated sentence requests are coalesced within a language batch. Responses are expanded back into their original positions. Different protected-name mappings never share requests or cache entries; no fuzzy translation-result reuse is introduced.
- Bounded caching reuses identical language-recognition evidence without changing the source-language decision rules.
- PiP keeps its prepared immutable pixel buffer and format for heartbeat frames, while creating a fresh timestamped sample buffer. A new text frame gets a fresh image buffer. Font fitting searches the same size grid with fewer measurements.
- The translated frame is prepared before synchronous history saving and optional speech/clipboard effects.
- Warm-up is throttled and isolated from active work. The warmed session is reused only while idle and in the same settings context.
- Timing now includes the confirmation window from first OCR sighting to frame enqueue. A separate Session breakdown identifies recognition, delivery/filtering, queue, processing and rendering. Actual display and source-video timing are outside this measurement.

## Verification

CI runs regression checks for request identity and order, protected words, subtitle grouping, partial-OCR handling, export and crop rules, scheduling and font-search equivalence. A synthetic repeated-sentence fixture requires 1,200 inputs to use 120 unique requests while reconstructing identical output. This is a duplicate-heavy fixture, not a claim of a 90% speedup for all videos.

The workflow builds the unsigned IPA, verifies both bundle versions, then runs the interface on an iPhone simulator and uploads an actual screenshot plus the generated icon. Download `ScreenLingo-ipa`, unzip it, then sign the IPA. The simulator preview does not verify physical-device ReplayKit/PiP or translation quality.

No on-device speedup percentage is claimed. Compare the Session timing breakdown under the same language pair, video, speed profile and thermal state to measure the improvement on your phone.

Local macOS pure regression checks:

```sh
swiftc Shared/Shared.swift Shared/PipelineSafety.swift Shared/OCRGrouping.swift Shared/ExportFormat.swift Shared/LatencyTools.swift Tests/main.swift -o /tmp/screenlingo-tests
/tmp/screenlingo-tests
```
