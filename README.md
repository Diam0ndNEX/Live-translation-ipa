# ScreenLingo

A native iOS screen translator built with SwiftUI, Apple Vision OCR, and Apple's on-device Translation framework.

## What it does

- Reads text from screen broadcasts using ReplayKit and Vision OCR.
- Translates recognized text on-device with supported Apple language packs.
- Shows translated text in a floating Picture-in-Picture window.
- Offers source/target language selection, OCR regions, speed presets, and display styles.
- Keeps a local translation history on the device, with separate copy actions for original and translated text.

## Build an unsigned IPA

1. Run the **Build unsigned IPA** workflow from the Actions tab.
2. Download the `ScreenLingo-ipa` artifact after the workflow succeeds.
3. Sideload the IPA using your preferred iOS sideloading tool.

The app targets iOS 18 or later. Translation language availability depends on Apple's supported language pairs and installed packs.

## Privacy

Screen OCR and translation are handled on-device. Translation history is stored locally in app preferences and is not uploaded by this project.

## Development

The project is generated from `project.yml` using XcodeGen. The app and ReplayKit broadcast extension share packet/config models in `Shared/Shared.swift`.
