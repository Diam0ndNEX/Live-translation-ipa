#!/usr/bin/env python3
"""ScreenLingo 2.3.1 source contracts: cross-mode diagnostics names and the version.

Structural checks only. Nothing here compiles or runs the app, and nothing claims a device result or a speed gain.
2.3.1 changes diagnostics names and one diagnostic call; translation, OCR, confirmation and defaults are unchanged.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
read = lambda relative: (root / relative).read_text(encoding="utf-8")
diagnostics = read("App/Diagnostics.swift")
archive = read("App/DiagnosticArchive.swift")
engine = read("App/TranslatorEngine.swift")
system = read("Shared/TranslationSystem.swift")
shared = read("Shared/Shared.swift")
project = read("project.yml")

# "recovery" is the code's own word in the new modes for a translation after confirmation.
assert system.count('"recovery_success"') == 1 and system.count('event(caption, "recovery_decision_" + reason, nil)') == 1
assert 'origins[index] = speculative ? "speculation" : "recovery"' in system

# Legacy reports early translations still running at confirmation like the other two modes.
assert "func noteLegacySpeculationInFlightMatch(candidate: String?)" in diagnostics
assert "legacyModeContexts[candidate]?.speculationInFlight = true" in diagnostics
assert 'context.speculationInFlight ? "pip_enqueue_speculation_match_in_flight" : "pip_enqueue_speculation_match_ready"' in diagnostics
assert '"pip_enqueue_speculation_match_in_flight"' in archive, "already allowlisted"
assert engine.count("diag.noteLegacySpeculationInFlightMatch(candidate: queuedPacket?.candidateID)") == 1
branch = engine[engine.index("} else if currentSpeculativeText == joined {"):]
assert branch.index("specMatchingConfirmation += 1") < branch.index("noteLegacySpeculationInFlightMatch") < branch.index("startDrain()")

# Hybrid and Low Latency record bypassed, as Legacy does, when memory reuse is off.
assert "(memoryTestMode.allowsReuse && !bypassMemory) ? .miss : .bypassed" in engine
assert "modeCoordinator.allowsReuse = memoryTestMode.allowsReuse && !bypassMemory" in engine
assert "diag.recordMemory(.bypassed, candidate: workCandidate, unitKey: key)" in engine, "Legacy unchanged"

# Three groups, same in every mode.
assert "static func pathGroup(_ reason: String) -> String?" in archive
for group, reasons in {
    "memory": ["pip_enqueue_memory_hit"],
    "early": ["pip_enqueue_speculation_match_ready", "pip_enqueue_speculation_match_in_flight"],
    "confirmed_time": ["pip_enqueue_confirmed_fresh", "pip_enqueue_fresh_text_changed", "pip_enqueue_legacy_recovery", "pip_enqueue_recovery_success"],
}.items():
    assert f'return "{group}"' in archive
    for reason in reasons:
        assert f'"{reason}"' in archive
assert '"_path_" + group' in archive
assert "path_memory" in archive and "path_early" in archive and "path_confirmed_time" in archive, "README names the groups"
assert "Only in Hybrid" not in archive, "the wrong 2.3.0 README sentence is gone"

# Version 2.3.1 build 108; older changelog entries stay.
assert 'static let version = "2.3.2"' in shared and "static let build = 109" in shared
assert project.count('"2.3.2"') == 3 and project.count('"109"') == 3
for old in ('("2.3.1", "Build 108:', '("2.3.0", "Build 107:', '("2.2.3", "Build 106:'):
    assert old in shared, old
print("v2.3.1 source contracts passed: recovery naming, Legacy in-flight label, bypassed outcome, path groups, version")
