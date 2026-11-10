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

# ---- Stop and start again: the run continues, nothing is cleared (2.3.2) ----
engine = (root / "App/TranslatorEngine.swift").read_text()
runviews = (root / "App/TestRunViews.swift").read_text()
store = (root / "App/TestRunStore.swift").read_text()
archive = (root / "App/DiagnosticArchive.swift").read_text()
def body(src, start, end):
    i = src.index(start); return src[i:src.index(end, i)]
# the three stop paths pause the run; none ends it
assert 'diag.pauseRun(reason: "captureStopped")' in engine
assert 'diag.pauseRun(reason: "heartbeatTimeout")' in engine
assert 'diag.pauseRun(reason: "newCaptureSession")' in engine
for gone in ('endRun(reason: "captureStopped")', 'endRun(reason: "heartbeatTimeout")', 'endRun(reason: "newCaptureSession")'):
    assert gone not in engine, gone
# only a mode change, a reset or a different mode ends a run
assert 'diag.endRun(reason: "modeChanged")' in engine
assert 'endRun(reason: "diagnosticsReset")' in diag and 'endRun(reason: "newRunStarted")' in diag
begin = body(diag, "func beginRun()", "private func startRunState()")
assert "if run.mode == modeActiveSystem { resumeRun(); return }" in begin, "same mode continues the run"
assert begin.index("resumeRun(); return") < begin.index("s = Stats()"), "resume returns before any zeroing"
resume = body(diag, "private func resumeRun()", "private func startRunState()")
for forbidden in ("clearCollection", "s = Stats()", "endRun", "modelTimingSamples", "modeEventCounts"):
    assert forbidden not in resume, forbidden
pause = body(diag, "func pauseRun(reason: String)", "private func resumeRun()")
for forbidden in ("clearCollection", "s = Stats()", "endRun", "activeRun = nil"):
    assert forbidden not in pause, forbidden
assert "store.save(meta: meta, snapshot: snapshot)" in pause and "previous?.label" in pause and "previous?.pinned" in pause
assert 'runSavingMode == "automatic"' in pause and "skipReason(for: meta)" in pause
# the gap is not part of the run
assert "pausedSeconds: Double = 0" in store and "- max(0, pausedSeconds)" in store
assert diag.count("pausedSeconds: pausedSeconds") >= 3
assert "pausedAt == nil, !checkpointInFlight" in diag, "no checkpoints while capture is off"
assert "diag.pausedSeconds" in dash and "diag.isRunPaused" in runviews
assert "pausedAt == nil || pauseReason == \"heartbeatTimeout\"" in diag, "a stop is not counted as a capture drop"
assert '"captureRestarts"' in diag and '"captureRestarts"' in archive and '"runPausedSeconds"' in archive
# a reset or a run end still clears everything, including the pause bookkeeping
clear = body(diag, "private func clearCollection()", "\n    // MARK: Packets from the extension")
for name in ("legacyModeContexts.removeAll()", "legacyModeContextOrder.removeAll()", "modeEventCounts.removeAll()",
             "modelTimingSamples = [:]", "queueWaitSamples = [:]", "memoryOutcomes = [:]", "s = Stats()",
             "lastCheckpointCaptureMs = nil", "checkpointCaptureMicros = 0", "clearSpeakers()", "diagnosticSessionID = UUID()",
             "pausedAt = nil; pausedTotal = 0"):
    assert name in clear, name
assert "if !wasAlive {" in engine and "diag.beginRun(); refreshModeDiagnosticEpoch()" in engine
for key in ("captureStopsByPacket", "captureStopsByTimeout", "captureStopsByNewSession", "extensionFreeMBAtLastStop", "secondsIntoRunAtLastStop"):
    assert f'"{key}"' in diag and f'"{key}"' in archive, key
assert "captureStopCounts = [:]" in clear
# no assignment may be left without a value (a lost string literal once produced `pauseReason = ;`)
import re
assert not re.search(r"=\s*[;\n]", diag.replace("==", "")), "assignment without a value"
assert 'pauseReason = ""' in diag
print("v2.3.2 stop/start contracts passed: run continues across stop and restart")
