#!/usr/bin/env python3
"""Fail CI if nominal/fair policy parity is weakened in any translation backend."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (root / path).read_text(encoding="utf-8")

engine = read("App/TranslatorEngine.swift")
extension = read("BroadcastExtension/SampleHandler.swift")
simulation = read("App/PipelineSimulation.swift")
core = read("Shared/TranslationSystem.swift")
policy = read("Shared/SubtitlePerformancePolicy.swift")
tests = read("Tests/main.swift")
modes = read("Tests/ThreeModes/main.swift")
diagnostics = read("App/Diagnostics.swift")

required = {
    "thermal classification": 'case .nominal, .fair: return .fullPerformance' in policy,
    "thermal protection": 'case .serious: return .protected' in policy and 'case .critical: return .emergency' in policy,
    "extension pressure": 'ThermalPerformancePolicy.automaticPressure(for: ProcessInfo.processInfo.thermalState)' in extension,
    "engine adaptive pressure": 'ThermalPerformancePolicy.automaticPressure(for: ProcessInfo.processInfo.thermalState) || (busy && queued != nil)' in engine,
    "legacy speculation": '&& !ProcessInfo.processInfo.isLowPowerModeEnabled && !ThermalPerformancePolicy.automaticPressure(for: ProcessInfo.processInfo.thermalState)' in engine,
    "nominal/fair shared policy history": 'thermal <= 1 ? "full_performance"' in core,
    "thermal excluded from caption identity": 'static func == (lhs: Self, rhs: Self) -> Bool' in core,
    "simulator uses shared pressure": 'ThermalPerformancePolicy.automaticPressure(named: s.thermal)' in simulation,
    "all systems and presets parity": 'for system in ["legacy", "hybridRecovery", "lowLatency"]' in tests and 'for preset in ["movie", "comic", "game", "lyrics", "custom"]' in tests,
    "active-caption thermal transition test": 'nominalCaption.policyCohort == fairCaption.policyCohort' in modes,
    "diagnostic parity evidence": '"performanceTier"' in diagnostics and '"reductionReasons"' in diagnostics,
}
forbidden = [
    ("engine nominal-only pressure", "ProcessInfo.processInfo.thermalState != .nominal", engine),
    ("engine nominal-only speculation", "ProcessInfo.processInfo.thermalState == .nominal &&", engine),
    ("extension nominal-only pressure", "ProcessInfo.processInfo.thermalState != .nominal", extension),
    ("simulator nominal-only pressure", 's.thermal != "nominal"', simulation),
    ("simulator nominal-only speculation", 's.thermal=="nominal"', simulation),
]
for name, ok in required.items():
    assert ok, "Missing required nominal/fair policy gate: " + name
for name, snippet, source in forbidden:
    assert snippet not in source, "Forbidden fair-only software reduction: " + name

print("Nominal/fair policy parity source gate passed across all three systems and presets")
