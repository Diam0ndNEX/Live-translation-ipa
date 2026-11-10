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

# ---- Stop and start again: one run per capture, nothing from the old run carried over ----
engine = (root / "App/TranslatorEngine.swift").read_text()
def body(src, start, end):
    i = src.index(start); return src[i:src.index(end, i)]
clear = body(diag, "private func clearCollection()", "\n    // MARK: Packets from the extension")
# every per-run store added in 2.3.x, plus the checkpoint cost fixed here, is reset when a run ends
for name in ("legacyModeContexts.removeAll()", "legacyModeContextOrder.removeAll()", "modeEventCounts.removeAll()",
             "modelTimingSamples = [:]", "queueWaitSamples = [:]", "memoryOutcomes = [:]", "s = Stats()",
             "lastCheckpointCaptureMs = nil", "checkpointCaptureMicros = 0", "clearSpeakers()", "diagnosticSessionID = UUID()"):
    assert name in clear, name
end_run = body(diag, "func endRun(reason: String)", "func saveRunNow")
assert "activeRun = nil" in end_run and "clearCollection()" in end_run
assert end_run.index("sessionSnapshot()") < end_run.index("clearCollection()"), "snapshot is taken before the collection is cleared"
# the three ways a run ends, and the one way a new run begins
handle = body(engine, "private func handle(_ incoming: Packet)", "if frames != p.frames")
assert 'diag.endRun(reason: "captureStopped")' in handle and 'diag.endRun(reason: "newCaptureSession")' in handle
assert 'diag.endRun(reason: "heartbeatTimeout")' in engine
assert "if !wasAlive {" in engine and "diag.beginRun(); refreshModeDiagnosticEpoch()" in engine
assert "func beginRun()" in diag and 'endRun(reason: "newRunStarted")' in body(diag, "func beginRun()", "private func startRunState()")
print("v2.3.2 stop/start contracts passed")
