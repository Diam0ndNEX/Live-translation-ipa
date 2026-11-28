# ScreenLingo

Live screen translation for iPhone and iPad. ScreenLingo reads the text on your screen (subtitles in YouTube, Netflix, games or any app), translates it on the device with Apple's Translation framework, and shows the translation in a floating Picture-in-Picture window over the other app.

Current version: **2.7.2 (build 133)**. Changes per version: the changelog in `Shared/Shared.swift`.

## How it works
1. Start capture in the app. A screen broadcast (ReplayKit extension) sends frames to the app.
2. The app reads the text with on-device OCR and waits until a caption is stable.
3. The caption is translated on the device (no server) and saved in translation memory, so repeated lines are instant.
4. The translation appears in the floating window, which stays on top of the app you watch.

## Translation modes
- **Legacy:** Apple's default translation model. Best wording.
- **Low Latency:** Apple's faster model (iOS 26.4 and later). Lower delay; wording can differ.

## Install
1. Open the **Actions** tab, choose the newest green **build** run on `main`.
2. Download the `ScreenLingo-ipa` artifact and unzip it.
3. Install `ScreenLingo.ipa` with TrollStore (the IPA is unsigned).

Needs iOS 18 or later; Low Latency needs iOS 26.4. Language packs are downloaded in the app under Languages.

## Diagnostics
The app measures every caption from its first OCR sighting to the floating window and can export a report (Diagnostics tab). Reports are metadata only unless you turn on flagged-caption text. For crashes or freezes, use the `.ips` files from Settings > Privacy & Security > Analytics & Improvements > Analytics Data.

## Repository
| Folder | What is in it |
|---|---|
| `App/` | The app: engine, UI, diagnostics, memory |
| `BroadcastExtension/` | The screen capture extension (OCR input) |
| `Shared/` | Code used by both, version and changelog |
| `Tests/` | Swift test programs run by CI |
| `scripts/` | Python and shell checks run by CI |
| `docs/` | Specifications per version; start at [docs/README.md](docs/README.md) |

## Development
- `main` is the current version. New work goes on `claude/screenlingo-v<version>` with a draft pull request into `main`.
- Every update gets a new version in `Shared/Shared.swift` and `project.yml`, and a `docs/v<version>-specification.md`.
- Read [docs/structure-guidelines.md](docs/structure-guidelines.md) before changing code.
- Before pushing: run every `scripts/test_*.py` and `python3 scripts/test_structure_docs.py --write`.
- GitHub Actions builds the IPA and runs all checks. Green CI means it compiles and the checks pass; it is not proof of speed or translation quality. Speed claims need Diagnostics data from the same video in both modes on the same device.

Older release notes (1.2 to 1.9.3): [docs/history/README-release-notes-1.x.md](docs/history/README-release-notes-1.x.md).
