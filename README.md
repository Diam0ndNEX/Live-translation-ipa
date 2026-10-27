# ScreenLingo

On-device screen translation for iOS 18 and later, with ReplayKit capture, Apple Translation language packs and a floating Picture in Picture window.

## Version 1.5.0 (36)

This branch incorporates the complete main-branch app at `a91907a`: the redesigned Home, language library, reader, custom presets, configurable interface, file-based sharing, detailed diagnostics, translation memory and translate-ahead.

ScreenLingo keeps its bundle identifier, app name, smaller text option, history migration, starred entries and retention settings. Integration fixes protect against partial OCR replacing complete subtitles, stale asynchronous results, malformed translation batches, overlapping hosted translation requests and frozen output being cleared. Movie mode keeps aligned lyric rows and joins adjacent subtitle fragments while comic bubbles remain separate. Frame skipping no longer delays the second OCR pass needed for confirmation.

## Build

Push this branch (`codex/screenlingo-v0.7.0`) or run **Build ScreenLingo IPA** manually in GitHub Actions. The workflow runs focused Swift regression checks, builds the app, verifies app/extension identity and version metadata, and uploads `ScreenLingo-ipa`.

For local macOS builds, generate the icon with `scripts/make_icon.py` (Pillow required), run `xcodegen generate`, then build the `ScreenLingo` scheme. The app and extension versions are set in `project.yml` and `Shared/Shared.swift` and checked against the packaged product by CI.

Regression checks on macOS:

```sh
swiftc Shared/Shared.swift Shared/PipelineSafety.swift Shared/OCRGrouping.swift Tests/main.swift -o /tmp/screenlingo-tests
/tmp/screenlingo-tests
```

## Device checks

Download the source/target packs in Languages, start capture from Home, and switch to the video. Test Portuguese to English in Movie mode with several visible lyric rows, a scrolling row change and two-line subtitles. Freeze should preserve the window until resumed; Pause should reject unfinished translation work. Changing the target language during translation must not show the previous pair's result. Confirm history, stars and saved settings survive an upgrade using the same signing identity.

An iOS build and device tests are required to verify Apple's Translation, ReplayKit and PiP runtime behavior; syntax checks alone do not establish those outcomes.
