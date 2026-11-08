#!/usr/bin/env python3
"""ScreenLingo 2.2.3 source contracts: the L5 background availability refresh and the version.

Structural checks only. Nothing here compiles or runs the app, and nothing claims a device result or a speed gain.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
read = lambda relative: (root / relative).read_text(encoding="utf-8")
shared_work = read("Shared/SharedTranslationWork.swift")
service = read("App/ModeTranslationService.swift")
experimental = read("App/ExperimentalFeaturesView.swift")
engine = read("App/TranslatorEngine.swift")
shared = read("Shared/Shared.swift")
project = read("project.yml")
index = read("App/UI/Model/SettingsSearchIndex.swift")

# L5: a third runtime switch, pinned at session start by the existing call, default OFF (current behaviour).
assert 'static let availabilityRefreshSettingKey = "backgroundAvailabilityRefresh"' in shared_work
assert 'static let availabilityRefreshPinnedKey = "backgroundAvailabilityRefreshPinned"' in shared_work
assert "?? false, forKey: availabilityRefreshPinnedKey)" in shared_work, "L5 must default to off"
assert "static var refreshAvailabilityInBackground: Bool" in shared_work
accessor = shared_work[shared_work.index("static var refreshAvailabilityInBackground"):shared_work.index("static var label")]
assert "?? false" in accessor, "L5 pinned value must default to off"
assert "TranslationHotPathAB.pinSettings()" in engine, "the switch is pinned when a session starts"

# The refresh only runs behind the switch, only while nothing is translating, and is called once.
start = service.index("private func refreshAvailabilityIfStale(")
refresh = service[start:service.index("\n    func cancel(speculation", start)]
assert refresh.index("guard TranslationHotPathAB.refreshAvailabilityInBackground") < refresh.index("availabilityRefreshing.insert")
for busy in ("!speculative.busy", "!confirmed.busy", "!warmupLane.busy", "hostedTask == nil"):
    assert busy in refresh, busy
assert "guard revision == self.generation else { return }" in refresh, "a reset discards the result"
assert service.count("self.refreshAvailabilityIfStale(") == 1

# The request path and the 30 s cache are unchanged; the refresh threshold stays below the TTL.
assert "private let installedCheckTTL: Double = 30" in service
assert 'report("backend_installed_cache_hit", nil)' in service
assert 'report("backend_availability_ms"' in service
after = float(re.search(r"availabilityRefreshAfter: Double = (\d+(?:\.\d+)?)", service)[1])
assert 0 < after < 30

# The toggle exists, defaults to off and resets.
assert '@AppStorage("backgroundAvailabilityRefresh") private var backgroundAvailabilityRefresh = false' in experimental
assert experimental.count('"backgroundAvailabilityRefresh"') >= 2
assert 'title: "Refresh language check in background"' in experimental
assert 'label: "Refresh language check in background"' in index

# L1: Fast OCR is already a runtime switch, off by default, and was not changed.
assert '@AppStorage("fastOCR") private var fastOCR = false' in experimental
assert 'fastOCR: flag("fastOCR", false)' in engine

# Diagnostics: the arm flag is exported (only when ON), allowlisted, and part of the cohort so on/off runs are not compared.
diagnostics = (root / "App/Diagnostics.swift").read_text()
archive = (root / "App/DiagnosticArchive.swift").read_text()
assert 'if TranslationHotPathAB.refreshAvailabilityInBackground { settings["availabilityRefreshAB"] = "on" }' in diagnostics
assert archive.count('"availabilityRefreshAB"') == 2, "settingsKeys and cohortKeys"
assert "deliveryFilteringMs matches confirmation-to-PiP time" in archive
assert "hybrid_switch_guard_* values are the gap" in archive

# L3 / L4: Hybrid-only arms, default OFF, pinned; constants unchanged when off.
work = (root / "Shared/SharedTranslationWork.swift").read_text()
system = (root / "Shared/TranslationSystem.swift").read_text()
for name, pinned in (("hybridRelaxedBackoff", "hybridBackoffPinnedKey"), ("hybridShorterGuard", "hybridGuardPinnedKey")):
    assert f'(UserDefaults.standard.object(forKey: {pinned}) as? Bool) ?? false' in work, name
    assert f'@AppStorage("{name}") private var {name} = false' in experimental, name
    assert experimental.count(f'"{name}"') >= 2, name
assert 'label: "Hybrid relaxed backoff"' in index and 'label: "Hybrid shorter switch guard"' in index
assert "static let switchGuardWindowMs = 1500.0" in system
assert "TranslationHotPathAB.hybridShorterGuard ? 1000.0 : switchGuardWindowMs" in system
assert "TranslationHotPathAB.hybridShorterGuard ? 120.0 : 220.0" in system
assert "hybridRelaxedBackoff ? 4 : 8" in system
assert "(relaxed ? 6 : 12) : (relaxed ? 2 : 4)" in system
assert "gapMs < effectiveSwitchGuardWindowMs else { return .lowLatency }" in system
assert '"hybridBackoffAB"' in archive and '"hybridGuardAB"' in archive
assert 'settings["hybridBackoffAB"] = "on"' in diagnostics and 'settings["hybridGuardAB"] = "on"' in diagnostics

assert "TranslationHotPathAB.hybridRelaxedBackoff, skipped > 0, let set = skipSetAt" in system, "decay only in the arm"
assert "static let relaxedBackoffMaxAge = 10.0" in system

# Version 2.2.3 build 106 in the places CI checks.
assert 'static let version = "2.2.3"' in shared and "static let build = 106" in shared
assert project.count('"2.2.3"') == 3 and project.count('"106"') == 3
assert '("2.2.3", "Build 106:' in shared
assert '("2.2.2", "Build 105:' in shared, "older changelog entries stay"
print("v2.2.3 source contracts passed: L5 switch (default off, pinned), unchanged request path and TTL, toggle, Fast OCR switch, version")
