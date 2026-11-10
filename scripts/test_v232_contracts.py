#!/usr/bin/env python3
"""ScreenLingo 2.3.2 source contracts: the in-app Diagnostics tabs show the 2.3 data. UI and read-only accessors only."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
dash = (root / "App/DiagnosticsDashboard.swift").read_text()
diag = (root / "App/Diagnostics.swift").read_text()
shared = (root / "Shared/Shared.swift").read_text()
project = (root / "project.yml").read_text()

assert "func enqueuePathCount(_ reason: String) -> Int" in diag and '"pip_enqueue_" + reason' in diag
assert "var confirmedSupersededAges: Summary" in diag
assert "private var enqueuePathCard" in dash and "enqueuePathCard\n            pipelinePage" in dash
for name in ("memory_hit", "speculation_match_ready", "speculation_match_in_flight", "confirmed_fresh",
             "fresh_text_changed", "recovery_success"):
    assert f'"{name}"' in dash, name
assert "stats.supersededConfirmedInFlight" in dash and "stats.supersededConfirmedNotStarted" in dash
assert "private var abSwitchLine" in dash and "Hint(abSwitchLine)" in dash
for flag in ("legacyConfirmedOwnLane", "refreshAvailabilityInBackground", "hybridRelaxedBackoff", "hybridShorterGuard"):
    assert f"TranslationHotPathAB.{flag}" in dash, flag
assert "Bypassed means" in dash

assert 'static let version = "2.3.2"' in shared and "static let build = 109" in shared
assert project.count('"2.3.2"') == 3 and project.count('"109"') == 3
for old in ('("2.3.2", "Build 109:', '("2.3.1", "Build 108:', '("2.3.0", "Build 107:'):
    assert old in shared, old
print("v2.3.2 source contracts passed: path card, supersession split, switches line, bypassed note, version")
