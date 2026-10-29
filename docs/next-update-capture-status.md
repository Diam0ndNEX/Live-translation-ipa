# Next update: visible capture status in Live

Requested after v1.7.2 build 58 testing instructions. This is a planned feature,
not included in the already built v1.7.2 IPA.

## User-visible requirement

Make it immediately clear in the Live tab whether screen capture actually started.
Show a prominent icon, short status label and color together; never rely on color
alone or on the translation/model warm-up status. Keep the indicator visible even
when optional Home status/details sections are hidden.

Suggested states:
- Gray: Not capturing.
- Amber: Waiting for capture / Connected, waiting for first frame.
- Green: Capture active (frame receipt confirmed, connection still alive).
- Amber/red: Capture connection lost, with a restart action.
- Translation paused or output frozen: separate explanatory label; neither implies
  that iOS screen capture itself stopped.

## Evidence and implementation notes

App/HomeView.swift already has subtle state text and a mint stateColor based on
engine.captureAlive, plus a broadcast-control label. Improve that existing surface
instead of adding redundant status panels.

TranslatorEngine.handle marks captureAlive from incoming extension packets;
tick currently expires the connection after five seconds without packets.
Do not declare successful capture merely because the broadcast picker was opened,
permission was requested, language packs are ready, or the model warmed up.
Distinguish connection acknowledgement from confirmed video-frame receipt.
No OCR text is required for successful capture. Static content and own-app OCR
suppression must not falsely report capture failure.

## Acceptance

- Broadcast not started/cancelled: never shows active.
- Extension connected before first video frame: visibly waiting.
- First confirmed video-frame receipt: visibly active.
- Fresh heartbeats preserve connection status during static/no-text content.
- Stop/timeout/disconnect: active indicator clears using the existing heartbeat
  boundary, with an understandable explanation.
- Paused translation and frozen output remain distinguishable from capture state.
- Accessible text/SF Symbol, VoiceOver label and sufficient contrast.
- No persistent captured text, images or extra high-frequency polling.
