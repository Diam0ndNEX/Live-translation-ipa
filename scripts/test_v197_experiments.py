#!/usr/bin/env python3
"""ScreenLingo v1.9.7 regression-sensitive source contract.

The native Swift suites verify behavior. This gate additionally protects the
A/B build provenance and three-mode wiring from accidental future removal.
It does not claim a device performance improvement.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
read = lambda relative: (root / relative).read_text(encoding="utf-8")
shared = read("Shared/Shared.swift")
project = read("project.yml")
capture = read("BroadcastExtension/SampleHandler.swift")
acquisition = read("Shared/SubtitleAcquisitionPolicy.swift")
governor = read("Shared/SubtitlePerformancePolicy.swift")
engine = read("App/TranslatorEngine.swift")
coordinator = read("Shared/TranslationSystem.swift")
service = read("App/ModeTranslationService.swift")
diagnostics = read("App/Diagnostics.swift")
archive = read("App/DiagnosticArchive.swift")
memory = read("App/TranslationMemoryStore.swift")
workflow = read(".github/workflows/build.yml")

assert 'static let version = "1.9.7"' in shared
assert "static let build = 79" in shared
assert project.count('"1.9.7"') == 3
assert project.count('"79"') == 3

assert "SCREENLINGO_REFERENCE_CAPTURE_CADENCE" in capture
assert "SubtitleAcquisitionPolicy.allowsEarlyVisualWake" in capture
assert "cfg.skipUnchanged ?? true" in capture
assert "rapidTextTracking: rapidText" in capture
assert "lastOcrMs" in capture
assert "if mayProbeEarly && !changed { cadenceSkipped += 1; return }" in capture
assert "if mayProbeEarly && changed { visualWakeCount += 1 }" in capture
assert "recognize(pb, orientation, cfg, edge: plan.edge)" in capture
assert "earlyVisualWakes: visualWakeCount" in capture
assert "min(0.025, max(0, proposed))" in coordinator

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

assert "SCREENLINGO_REFERENCE_CONFIRMED_PROBE" in coordinator
assert "verifiedConfirmedMemory" in coordinator
assert "verified.caption == caption" in coordinator
assert "verified.hits.count == caption.units.count" in coordinator
assert "confirmed_memory_probe_reused" in coordinator
assert "SCREENLINGO_REFERENCE_HYBRID_PREFLIGHT" in coordinator
assert "hybrid_unsubmitted_hedge_ms" in coordinator
assert "hybridVariant" in coordinator
assert "hybrid_default_fallback" in coordinator
assert "maySubmitDefaultAfterAvailability" in service
assert "hybrid_previous_default_exit_gap_ms" in service
assert "hybrid_recovery_post_default_service_ms" in service
assert "hybrid_recovery_no_recent_overlap_service_ms" in service
assert "hybrid_unexplained_slow_recovery_ms" in service
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
assert "hybrid_unsubmitted_hedge_ms" in archive
assert "legacyAdaptiveLowYieldSkips" in archive
assert "CREATE TABLE" in memory
assert "codex/screenlingo-v1.9.7-three-mode-gains" in workflow
assert "codex/screenlingo-v1.9.6-hybrid-contention" in workflow
assert "Verify v1.9.7 isolated three-mode performance contract" in workflow

print("v1.9.7 nominal/fair, custom preset, exact-lane and A/B wiring contract passed")
