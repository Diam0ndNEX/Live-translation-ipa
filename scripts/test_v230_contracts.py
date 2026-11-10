#!/usr/bin/env python3
"""ScreenLingo 2.3.0 source contracts: Legacy diagnostics labels, the confirmed-supersession measurement, the report
column for the 2.2.3 switches, and the version.

Structural checks only. Nothing here compiles or runs the app, and nothing claims a device result or a speed gain.
2.3.0 changes diagnostics only; the engine hot path (process, drain, enqueue) must be unchanged.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
read = lambda relative: (root / relative).read_text(encoding="utf-8")
diagnostics = read("App/Diagnostics.swift")
archive = read("App/DiagnosticArchive.swift")
engine = read("App/TranslatorEngine.swift")
service = read("App/ModeTranslationService.swift")
shared = read("Shared/Shared.swift")
project = read("project.yml")

# Legacy labels: decided per caption, no value shared between captions.
assert "lastLegacySpeculation" not in diagnostics, "the shared last-speculation value must stay gone"
assert "var earlyFingerprint: String?" in diagnostics
assert "legacyModeContexts[caption]?.earlyFingerprint = fingerprint" in diagnostics
assert "legacyModeContexts[caption]?.mismatch = early != fingerprint" in diagnostics
assert "pip_enqueue_legacy_recovery" not in diagnostics.replace("// 2.3.0: the old name \"pip_enqueue_legacy_recovery\"", ""), \
    "Legacy must no longer emit the old recovery label"
assert 'context.mismatch ? "pip_enqueue_fresh_text_changed" : "pip_enqueue_confirmed_fresh"' in diagnostics
assert 'reason: "confirmed_service_ms"' in diagnostics and 'reason: "recovery_service_ms"' not in diagnostics

# Context bookkeeping: oldest entries first, never everything at once.
assert "legacyModeContexts.removeAll(); legacyContextResets += 1" not in diagnostics
assert "legacyModeContextOrder.removeFirst(dropped.count)" in diagnostics
assert diagnostics.count("legacyModeContextOrder.removeAll()") == 1, "reset clears the order list with the contexts"

# Allowlists and the model-call parser accept the new names; the old names stay readable.
assert '"pip_enqueue_fresh_text_changed"' in archive and '"pip_enqueue_legacy_recovery"' in archive
assert archive.count('"confirmed_service_ms"') == 2, "reason allowlist and model-call parser"
assert 'case "speculative_service_ms", "recovery_service_ms", "confirmed_service_ms":' in archive
# Low Latency and Hybrid keep their names (renaming them touches the Hybrid analysis); the README says what they mean.
assert service.count('"recovery_service_ms"') == 2 and service.count('"recovery_queue_ms"') == 2
assert "Only in Hybrid" in archive and "Recovery do the recovery_* names mean a recovery" in archive

# Supersession measurement: counters, one bounded sample list, exported through every allowlist.
assert "func noteConfirmedSupersession(workStarted: Bool, ageMs: Double)" in diagnostics
assert 'counters["supersededConfirmedInFlight"] = s.supersededConfirmedInFlight' in diagnostics
assert 'counters["supersededConfirmedNotStarted"] = s.supersededConfirmedNotStarted' in diagnostics
assert '"confirmedSupersededAgeMs": DiagnosticDistribution(modelTimingSamples["confirmed_superseded_age_ms"' in diagnostics
assert '"supersededConfirmedInFlight", "supersededConfirmedNotStarted"' in archive
assert archive.count('"confirmedSupersededAgeMs"') == 1
call = engine.index("diag.noteConfirmedSupersession(")
window = engine[call - 220:call + 260]
assert "diag.s.supersededUnpresentedConfirmed += 1" in window and "diag.enabled" in window, "measured only when collecting"
assert "workStarted: busy && activeQueueOwner == .confirmed" in window
assert engine.count("noteConfirmedSupersession(") == 1

# Report: the 2.2.3 switches that were on (keys are written only when ON).
assert '| memory timeouts | switches on |' in archive
assert 'armsOn' in archive and '("legacyOwnLaneAB", "Legacy own lane")' in archive

# Defaults unchanged: every 2.2.3 switch still defaults to OFF.
work = read("Shared/SharedTranslationWork.swift")
assert work.count("?? false, forKey:") == 4, "the four 2.2.3 switches keep defaulting to off"

# Version 2.3.0 build 107 in the places CI checks; older changelog entries stay.
assert 'static let version = "2.3.0"' in shared and "static let build = 107" in shared
assert project.count('"2.3.0"') == 3 and project.count('"107"') == 3
assert '("2.3.0", "Build 107:' in shared and '("2.2.3", "Build 106:' in shared
print("v2.3.0 source contracts passed: per-caption Legacy labels, confirmed_service_ms, oldest-first context drop, "
      "supersession measurement, switches column, defaults unchanged, version")
