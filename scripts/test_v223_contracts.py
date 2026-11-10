#!/usr/bin/env python3
"""ScreenLingo 2.2.3 source contracts: the L5 background availability refresh and the version.

Structural checks only. Nothing here compiles or runs the app, and nothing claims a device result or a speed gain.
"""
from pathlib import Path
from sources import read_source
import re

root = Path(__file__).resolve().parents[1]
shared_work = read_source("SharedTranslationWork")
service = read_source("ModeTranslationService")
experimental = read_source("ExperimentalFeaturesView")
engine = read_source("TranslatorEngine")
shared = read_source("Shared")
project = (root / "project.yml").read_text(encoding="utf-8")
index = read_source("SettingsSearchIndex")

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
diagnostics = read_source("Diagnostics")
archive = read_source("DiagnosticArchive")
assert 'if TranslationHotPathAB.refreshAvailabilityInBackground { settings["availabilityRefreshAB"] = "on" }' in diagnostics
# 2.3.0: 3 uses now (settingsKeys, cohortKeys and the new "switches on" report column).
assert archive.count('"availabilityRefreshAB"') == 3, "settingsKeys, cohortKeys and the 2.3.0 report column"
assert "deliveryFilteringMs matches confirmation-to-PiP time" in archive
assert "hybrid_switch_guard_* values are the gap" in archive

# L3 / L4: Hybrid-only arms, default OFF, pinned; constants unchanged when off.
work = read_source("SharedTranslationWork")
system = read_source("TranslationSystem")
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

# L2: Legacy confirmed-own-lane arm, default OFF, iOS 26 only, epoch-guarded drain.
assert '(UserDefaults.standard.object(forKey: legacyOwnLanePinnedKey) as? Bool) ?? false' in work
assert '@AppStorage("legacyConfirmedOwnLane") private var legacyConfirmedOwnLane = false' in experimental
assert 'label: "Legacy confirmed own lane"' in index
detach = engine[engine.index("private func detachCancelledSpeculationIfEnabled"):engine.index("private func presentQueuedFromRAMIfComplete")]
for token in ("TranslationHotPathAB.legacyConfirmedOwnLane", "activeTranslationSystem == .legacy", "activeQueueOwner == .speculative", "#available(iOS 26.0, *)", "drainEpoch += 1"):
    assert token in detach, token
assert engine.count("detachCancelledSpeculationIfEnabled()") == 2, "defined once, called once"
assert 'settings["legacyOwnLaneAB"] = "on"' in diagnostics and '"legacyOwnLaneAB"' in archive
# Event cap raised from 2,400 to 6,000 everywhere it is applied.
assert "2400" not in "".join(l for l in diagnostics.splitlines() if "structuredEvents" in l or "modeTrace" in l or "IDs.count" in l)
assert diagnostics.count("6000") >= 8 and "suffix(5840)" in diagnostics and "suffix(5872)" in diagnostics
assert archive.count("suffix(6000)") >= 3

store = read_source("TestRunStore")
assert "maximumRunBytes: Int = TestRunStore.unlimitedRunBytes" in store and "static let unlimitedRunBytes = Int.max" in store

assert "maximumTotalBytes: Int = Int.max" in store and "maximumUnpinnedRuns: Int = Int.max" in store, "no default storage limits"
assert "100 MB" not in read_source("TestRunViews")

# Version 2.2.3 build 106 in the places CI checks.
assert 'static let version = "2.3.8"' in shared and "static let build = 115" in shared
assert project.count('"2.3.8"') == 3 and project.count('"115"') == 3
assert '("2.2.3", "Build 106:' in shared
assert '("2.2.2", "Build 105:' in shared, "older changelog entries stay"
print("v2.2.3 source contracts passed: L5 switch (default off, pinned), unchanged request path and TTL, toggle, Fast OCR switch, version")
