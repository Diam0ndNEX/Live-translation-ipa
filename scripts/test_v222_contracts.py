#!/usr/bin/env python3
"""ScreenLingo 2.2.2 source contracts: the floating window can start, and its failures are visible.

Nothing here compiles or runs the app. It guards the source shape of the fixes so a later edit cannot quietly undo them.
"""
from pathlib import Path
from sources import read_source
root = Path(__file__).resolve().parent.parent
read = lambda path: (root / path).read_text()
pip = read_source("PiPRenderer")
engine = read_source("TranslatorEngine")
app = read_source("ScreenTranslatorApp")
diagnostics = read_source("Diagnostics")
archive = read_source("DiagnosticArchive")
translate = read_source("TranslateScreen")

# P1: the video layer is mounted once, at the root, and is not hidden (iOS refuses PiP for a hidden layer).
assert "PiPHost(layer: model.engine.pip.displayLayer)" in app
assert "struct PiPHost: View" in pip and ".allowsHitTesting(false)" in pip and "isHidden" not in pip.split("struct PiPHost")[1]
# The Translate screen must not draw the old preview box (R1/R2 in test_ui_layout_rules.py).
assert "PiPPreview" not in translate and "PiPHost" not in translate

# P2: start() says why, the engine records why it gave up, and the audio session error is no longer swallowed.
assert "enum PiPStartResult" in pip and "func start() -> PiPStartResult" in pip
assert "try? s.setActive(true)" not in engine and "pip_audio_session_failed" in engine
for code in ("pip_start_unsupported", "pip_start_not_possible", "pip_start_not_hosted", "pip_start_failed", "pip_audio_session_failed"):
    assert code in engine, code
    assert code in diagnostics, code
    assert archive.count(code) == 2, code
assert "pip.onStartFailed" in engine and "onStartFailed?()" in pip
assert "Stay on Translate and tap Start again." not in engine

# P3: automatic start from inline is off by default and follows the live session.
assert "canStartPictureInPictureAutomaticallyFromInline = false" in pip
assert "pip.setAutomaticStart(captureAlive && flag(\"autoOpenPiP\", true))" in engine

# L1: accessibility-size layouts.
assert "typeSize.isAccessibilitySize" in translate and "ComposeBar(engine: engine, composing: $composing)" in translate
assert "minimumScaleFactor(0.7)" in translate
assert ".font(.title.bold())" in read_source("LanguagePairTitle")
assert "primaryLine" in read_source("PhaseHeader")
assert "typeSize.isAccessibilitySize" in read_source("SettingsKit")
assert "typeSize.isAccessibilitySize" in read_source("LibraryScreen") and ".overlay { if items.isEmpty { emptyState } }" not in read_source("LibraryScreen")
assert "typeSize.isAccessibilitySize" in read_source("DiagnosticsDashboard")
assert "typeSize.isAccessibilitySize" in read_source("AreaEditor") and "typeSize.isAccessibilitySize" in read_source("OnboardingView")

# V: the current version (2.2.3 build 106, since the 2.2.3 update) in the three places the CI checks; the 2.2.2 changelog
# entry must stay.
shared = read_source("Shared"); project = read("project.yml")
assert 'static let version = "2.3.4"' in shared and "static let build = 111" in shared
assert project.count('"2.3.4"') == 3 and project.count('"111"') == 3
assert '("2.2.2", "Build 105:' in shared
print("v2.2.2 source contracts passed: PiP host, start reasons, diagnostics codes, automatic start, large-text layouts, version")
