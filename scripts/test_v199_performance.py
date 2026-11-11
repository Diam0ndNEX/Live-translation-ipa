#!/usr/bin/env python3
"""ScreenLingo v1.9.9 regression-sensitive source contract.

The native Swift suites verify behavior. This gate additionally protects the
A/B build provenance and three-mode wiring from accidental future removal.
It does not claim a device performance improvement.
"""
from pathlib import Path

from sources import read_source

root = Path(__file__).resolve().parents[1]
def read(relative):
    if relative.split("/")[0] in ("App", "Shared", "BroadcastExtension"):
        return read_source(Path(relative).stem)
    return (root / relative).read_text(encoding="utf-8")
shared = read("Shared/Shared.swift")
project = read("project.yml")
capture = read_source("SampleHandler")
acquisition = read("Shared/SubtitleAcquisitionPolicy.swift")
governor = read("Shared/SubtitlePerformancePolicy.swift")
engine = read_source("TranslatorEngine")
coordinator = read_source("TranslationSystem")
service = read("App/ModeTranslationService.swift")
diagnostics = read_source("Diagnostics")
archive = read("App/DiagnosticArchive.swift")
memory = read_source("TranslationMemoryStore")
workflow = read(".github/workflows/build.yml")

assert 'static let version = "2.5.0"' in shared
assert "static let build = 118" in shared
assert project.count('"2.5.0"') == 3
assert project.count('"118"') == 3

assert "SCREENLINGO_REFERENCE_CAPTURE_CADENCE" in capture
assert "SubtitleAcquisitionPolicy.allowsEarlyVisualWake" in capture
assert "cfg.skipUnchanged ?? true" in capture
assert "rapidTextTracking: rapidText" in capture
assert "lastOcrMs" in capture
assert "if mayProbeEarly && !changed { cadenceSkipped += 1; return }" in capture
assert "if mayProbeEarly && changed {" in capture
assert "visualWakeWindowCount += 1" in capture
assert "visualWakeCount += 1" in capture
assert "recognize(pb, orientation, cfg, edge: plan.edge)" in capture
assert "earlyVisualWakes: visualWakeCount" in capture
# 2.5.0 (changed with the code): Hybrid Recovery was removed, so the 1.9.9 Hybrid drain, settling wait and hedge
# invariants that stood here and below have nothing left to pin. What they pinned must now be absent.
assert "physicalDrainBudget" not in coordinator and "postDefaultSettlement" not in coordinator
assert '"hybrid_' not in coordinator and "hybrid_" not in service
assert "let availabilityKey = languagePairKey" in service
assert "lane.lastFinishedPair = languagePairKey" in service
assert "mayProbeEarlyInWindow" in acquisition
assert "visualWakeWindowCount" in capture
assert "discardPendingSpeculation" in engine
assert "legacy_queued_speculation_superseded" in engine
assert "lastVisualWakeProbe = .distantPast" in capture
assert "if (cfg.skipUnchanged ?? true) || (cfg.captureDiagnostics ?? false) ||" in capture
assert "(rapidText && !pressure)" in capture

assert "SCREENLINGO_REFERENCE_LEGACY_ADMISSION" in engine
assert "allowsCredibleOpportunity" in engine
assert "legacyAdaptiveLowYieldSkips" in engine
assert "legacyAdaptiveSavedSkips" in engine
assert "legacyLowConfidenceSkips" in engine
assert "legacyBusySpeculationSkips" in engine
assert "legacyDuplicateSpeculationSkips" in engine
assert "guard !busy, queued == nil" in engine
assert "if presentQueuedFromRAMIfComplete() { return }" in engine
assert "SpeculativeSessionOwner" in engine

assert "if units == other.units { return true }" in coordinator
assert "if missing.count == 1 && allMissing.count == 1" in coordinator
assert "if caption.keys.count == 1" in engine
assert "SCREENLINGO_REFERENCE_CONFIRMED_PROBE" in coordinator
assert "verifiedConfirmedMemory" in coordinator
assert "verified.caption == caption" in coordinator
assert "verified.hits.count == caption.units.count" in coordinator
assert "confirmed_memory_probe_reused" in coordinator
assert "hybridVariant" not in coordinator and "maySubmitDefaultAfterAvailability" not in service
assert "lane.sharedDefaultLease.requestCancellation()" in service

for flag in (
    "rapidTextTracking", "joinAdjacentText", "activeTextFocus"
):
    assert flag in engine
    assert flag in diagnostics
assert "mode == \"movie\"" not in capture
assert "mode == \"movie\"" not in acquisition
assert "ThermalPerformancePolicy.automaticPressure" in capture
assert "ThermalPerformancePolicy.automaticPressure" in engine
assert "mode_trace_ring_overwritten" in archive
assert "earlyVisualWakes" in archive
assert "hybrid_unsubmitted_hedge_ms" not in archive
assert "legacyAdaptiveLowYieldSkips" in archive
assert "CREATE TABLE" in memory
assert "codex/screenlingo-v1.9.9-recovery-evidence" in workflow
assert "claude/**" in workflow
assert "Verify v1.9.9 recovery and OCR regression contract" in workflow

print("v1.9.9 nominal/fair, custom preset, exact-lane and A/B wiring contract passed")

assert "            (cfg.skipUnchanged ?? true) &&\n            SubtitleAcquisitionPolicy.allowsEarlyVisualWake(" not in capture
print("v1.9.9 skip-independent early wake source invariants passed (the Hybrid drain invariants ended with the mode in 2.5.0)")
