#!/usr/bin/env python3
"""ScreenLingo 2.3.2 source contracts: the in-app Diagnostics tabs show the 2.3 data. UI and read-only accessors only."""
from pathlib import Path
from sources import read_source
root = Path(__file__).resolve().parents[1]
dash = read_source("DiagnosticsDashboard")
diag = read_source("Diagnostics")
shared = read_source("Shared")
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

assert 'static let version = "2.3.6"' in shared and "static let build = 113" in shared
assert project.count('"2.3.6"') == 3 and project.count('"113"') == 3
for old in ('("2.3.2", "Build 109:', '("2.3.1", "Build 108:', '("2.3.0", "Build 107:'):
    assert old in shared, old
print("v2.3.2 source contracts passed: path card, supersession split, switches line, bypassed note, version")

# ---- Stop and start again: the run continues, nothing is cleared (2.3.2) ----
engine = read_source("TranslatorEngine")
runviews = read_source("TestRunViews")
store = read_source("TestRunStore")
archive = read_source("DiagnosticArchive")
def body(src, start, end):
    i = src.index(start); return src[i:src.index(end, i)]
# the three stop paths pause the run; none ends it
assert 'diag.pauseRun(reason: "captureStopped", frames: frames)' in engine
assert 'diag.pauseRun(reason: "heartbeatTimeout", frames: frames)' in engine
assert 'diag.pauseRun(reason: "newCaptureSession", frames: frames)' in engine
for gone in ('endRun(reason: "captureStopped")', 'endRun(reason: "heartbeatTimeout")', 'endRun(reason: "newCaptureSession")'):
    assert gone not in engine, gone
# only a mode change, a reset or a different mode ends a run
assert 'diag.endRun(reason: "modeChanged")' in engine
assert 'endRun(reason: "diagnosticsReset")' in diag and 'endRun(reason: "newRunStarted")' in diag
entry = body(diag, "func beginRun(sameBroadcast: Bool, frames: Int)", "func beginRun() {")
assert "run.mode == modeActiveSystem { resumeRun(sameBroadcast: sameBroadcast, frames: frames); return }" in entry, "same mode continues the run"
assert 'endRun(reason: "newRunStarted")' in body(diag, "func beginRun() {", "private func startRunState()")
resume = body(diag, "private func resumeRun(", "private func startRunState()")
for forbidden in ("clearCollection", "s = Stats()", "endRun", "modelTimingSamples", "modeEventCounts"):
    assert forbidden not in resume, forbidden
pause = body(diag, "func pauseRun(reason: String", "private func resumeRun(")
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
assert "if !wasAlive {" in engine
for key in ("captureStopsByPacket", "captureStopsByTimeout", "captureStopsByNewSession", "extensionFreeMBAtLastStop", "secondsIntoRunAtLastStop"):
    assert f'"{key}"' in diag and f'"{key}"' in archive, key
assert "captureStopCounts = [:]" in clear
# no assignment may be left without a value (a lost string literal once produced `pauseReason = ;`)
import re
assert not re.search(r"=\s*[;\n]", diag.replace("==", "")), "assignment without a value"
assert 'pauseReason = ""' in diag
for key in ("resumedSameBroadcast", "resumedNewBroadcast", "extensionFramesDuringLastGap", "longestStopGapSeconds"):
    assert f'"{key}"' in diag and f'"{key}"' in archive, key
assert "sameBroadcast: captureAdmission == .current, frames: p.frames" in engine
assert engine.count("diag.pauseRun(reason:") == 3 and engine.count("frames: frames)") >= 3
print("v2.3.2 stop/start contracts passed: run continues across stop and restart")

# ---- Independent capture heartbeat: optional, off by default, nothing extra sent while frames flow ----
work = read_source("SharedTranslationWork")
shared_cfg = read_source("Shared")
ext = read_source("SampleHandler")
experimental = read_source("ExperimentalFeaturesView")
assert "var independentHeartbeat: Bool? = nil" in shared_cfg, "optional field: older apps and extensions ignore it"
assert "(UserDefaults.standard.object(forKey: independentHeartbeatPinnedKey) as? Bool) ?? false" in work
assert "defaults.set((defaults.object(forKey: independentHeartbeatSettingKey) as? Bool) ?? false, forKey: independentHeartbeatPinnedKey)" in work, "pinned at session start, default off"
assert "independentHeartbeat: TranslationHotPathAB.independentHeartbeat ? true : nil" in engine
assert '@AppStorage("independentCaptureHeartbeat") private var independentCaptureHeartbeat = false' in experimental
assert '"legacyConfirmedOwnLane", "independentCaptureHeartbeat"' in experimental, "reset section lists it"
assert 'settings["heartbeatAB"] = "on"' in diag and archive.count('"heartbeatAB"') >= 3
hb = body(ext, "private func sendHeartbeatIfQuiet()", "// MARK: Frames")
assert "recognitionLock" not in hb, "the heartbeat must never wait on the OCR lock"
assert "now - last >= 1.5" in hb, "sends only when nothing else went out for 1.5 s"
assert "config" not in hb.replace("independentHeartbeat", "") and "info" not in hb.split("Packet(")[1].split(")")[0], "reads only lock-protected values"
assert "stopHeartbeat()" in body(ext, "override func broadcastFinished()", "/// The app sends settings")
assert "updateHeartbeat(enabled: cfg.independentHeartbeat == true)" in ext
assert "heartbeatFrames = frames; lastSendUptime" in body(ext, "private func send(", "func encode(")
# the frame callback itself is untouched
frame = body(ext, "override func processSampleBuffer(", "let cfg = config")
assert "heartbeat" not in frame.lower()
print("v2.3.2 heartbeat contracts passed: optional, off by default, quiet-only, no OCR lock")

# ---- Changelog lint: CI failed to compile because the 2.3.1 entry ended in an escaped quote (unterminated string) ----
import re
for number, line in enumerate(shared.split("\n"), 1):
    if line.startswith('        ("'):
        quotes = len(re.findall(r'(?<!\\)"', line))
        assert quotes == 4 and line.rstrip().rstrip(",").endswith('")'), f"Shared.swift line {number}: changelog entry is not a closed string pair"
print("v2.3.2 changelog lint passed")
