# ScreenLingo

ScreenLingo is a native iOS screen translator built with SwiftUI, Apple Vision OCR, and Apple's on-device Translation framework.

## Highlights

- Live screen text capture through a ReplayKit broadcast extension.
- On-device OCR and translation with supported Apple language packs.
- Floating Picture-in-Picture translation window.
- Dedicated modes for subtitles, games/apps, and comics, with Movie mode able to translate aligned multi-row lyrics together.
- Configurable OCR area and Fast / Balanced / Sharp performance profiles.
- Adjustable OCR confidence threshold and optional language-aware recognition correction.
- Customizable PiP size, appearance, text size, and optional original-text display.
- Optional speech output, pause, automatic clearing, and local translation history.
- Live diagnostics for OCR latency, translation latency, frame counts, extension memory, thermal state, Low Power Mode, and battery.
- Local-only privacy controls with automatic history retention (7/30/90 days or forever).
- Searchable translation history with starred entries and text/CSV export.
- Custom ScreenLingo app icon and consistent app/extension version metadata.

## Identity

- Display name: `ScreenLingo`
- Bundle identifier: `com.diam0ndnex.screenlingo`
- Broadcast extension identifier: `com.diam0ndnex.screenlingo.broadcast`
- Version: `1.4.7` (build `35`)

The bundle identifier has changed from the previous placeholder ID. iOS treats it as a different app identity; to replace an older installation cleanly, uninstall the old Screen Translator build first. This may remove its local app data, so export anything important before uninstalling.

## Build an unsigned IPA

1. Open the **Actions** tab.
2. Run **Build ScreenLingo IPA**.
3. When it succeeds, download the `ScreenLingo-ipa` artifact.
4. Sign and install the IPA using your preferred sideloading tool.

The workflow generates the icon asset from `App/ScreenLingoIcon.svg`, generates the Xcode project with XcodeGen, builds the app and broadcast extension, then packages the unsigned IPA.

## Privacy and limitations

OCR and translation are handled on-device using Apple frameworks. Language-pair availability depends on iOS and installed language packs. ScreenLingo cannot guarantee identical accuracy for every font, animation, language pair, or game UI; use Sharp for small text and Fast for lower latency.

Translation history and settings are stored locally on-device. History can be automatically pruned after 7, 30, or 90 days, or retained indefinitely. Text and CSV exports are created locally; review exported files before sharing because they may contain recognized screen text. Diagnostic reports can redact recognized text. This project does not send recognized text to a third-party translation server.

## Development

The Xcode project is generated from `project.yml`. The app and ReplayKit extension share packet/config models in `Shared/Shared.swift`. Version metadata in `Shared/Shared.swift` and `project.yml` must stay synchronized.
