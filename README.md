# ScreenLingo 0.8.0

Major overhaul built on the complete main-branch integration, with on-device translation and iOS 18 support. The preceding ScreenLingo branch and its IPA remain available separately.

## New in this release

- Home launchpad for live capture, text/photo translation, visual capture area and session controls.
- Workspace for typing, pasting, importing text files and recognizing photos/screenshots on device. Large photos are downsampled with orientation preserved. Workspace OCR pauses live reading and restores it on dismissal.
- Focus reader with persistent text size, selectable text, centered alignment, original-text toggle, speech, sharing, freeze/resume and hideable controls.
- Visual capture-area editor with full-screen, subtitle and middle-band shortcuts.
- Library with search across original/translated text and notes, saved entries, date filters, multi-selection, detail pages, translation cards and deletion undo.
- TXT, spreadsheet-safe CSV and JSON exports; JSON backup restore with duplicate-ID protection.
- Session counters, optional timed pause, timer restart and recovery controls.
- Private sessions, diagnostic text controls and storage erasure. Private sessions skip new history entries and disk memory writes.
- OCR confidence and correction controls, idle backoff, thermal adaptation and low-power safeguards.
- Background memory persistence is serialized so Clear cannot be undone by an older pending save.
- Dedicated Lyrics preset that stays in Movie mode; existing subtitle grouping and stale-output safeguards remain active.
- Clear language-download success/failure messages.

Version is **0.8.0 (37)** as requested. This intentionally changes the marketing version from the prior integration's 1.5.0; build number increases and bundle identifiers stay the same. Signing tools that enforce marketing-version ordering may require reinstalling the IPA.

## Build and validation

The `codex/screenlingo-v0.8.0` branch builds an unsigned IPA in GitHub Actions. CI runs focused Swift regression checks, compiles both targets and verifies app/extension versions and identifiers before packaging `ScreenLingo-ipa`.

Local macOS regression checks:

```sh
swiftc Shared/Shared.swift Shared/PipelineSafety.swift Shared/OCRGrouping.swift Shared/ExportFormat.swift Tests/main.swift -o /tmp/screenlingo-tests
/tmp/screenlingo-tests
```

For device testing, cover Portuguese to English Movie subtitles, scrolling lyrics, freeze/resume, manual translation while capture is running, photo rotation, importing/exporting history, deletion undo, private sessions, timed pause and background/foreground recovery. CI compilation does not establish ReplayKit/PiP or Apple Translation runtime quality on a physical device.
