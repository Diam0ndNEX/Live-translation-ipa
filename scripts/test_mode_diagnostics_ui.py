#!/usr/bin/env python3
"""Static routing regressions paired with the Swift three-mode and iOS CI suites."""
from pathlib import Path
from sources import read_source

root = Path(__file__).resolve().parents[1]
engine = read_source("TranslatorEngine")
diagnostics = read_source("Diagnostics")
# 2.0.0 build 86: the dashboard view moved to its own file; the recorder stays in Diagnostics.swift.
dashboard = read_source("DiagnosticsDashboard")
coordinator = read_source("TranslationSystem")
backend = read_source("ModeTranslationService")
archive = read_source("DiagnosticArchive")
tests = (root / "Tests/ThreeModes/main.swift").read_text()

def section(source: str, start: str, end: str) -> str:
    assert source.count(start) == 1, f"Missing or duplicated start: {start}"
    position = source.index(start)
    finish = source.find(end, position + len(start))
    assert finish != -1, f"Missing end: {end}"
    return source[position:finish]

selection = section(engine, "private func selectModeResult(", "private var contextRevision")
assert "diag.recordModeSelection(" in selection
assert "processingMs: modelProcessing" in selection
assert 'output.origins.contains("recovery")' in selection
assert 'output.origins.contains("speculation")' in selection
assert selection.index("if presented {") < selection.index("diag.recordModeSelection(")
assert "diag.s.translations += 1" in selection
assert "diag.recordMemory(" in selection
assert "queueMemory(" in selection

mode_event = section(engine, "private func noteModeEvent(", "private func handleModeCaption(")
assert 'reason == "model_batch_completed"' in mode_event
assert "diag.recordModeModel(ms: duration" in mode_event
assert "modeModelTimings[key] = timing" in mode_event
assert "translateMs = duration" in mode_event
assert 'reason == "speculative_model_submitted"' in mode_event
assert "noteSpeculativeModelSubmitted(caption)" in mode_event

# Only waiting confirmed work receives the shorter lane handoff interval.
lane_wait = section(backend, "while lane.busy {", "guard !Task.isCancelled, eligibleToStart() else {")
assert "if speculation || Task.isCancelled" in lane_wait
assert "Task.sleep(nanoseconds: 5_000_000)" in lane_wait

warmup = section(diagnostics, "func noteInitialWarmup(", "func noteModeEvent(")
assert 'observation.phase == "model_submitted"' in warmup
assert 'noteModelState("warmup_started")' in warmup
assert 'noteModelState("warmup_model_submitted")' in warmup
assert 'observation.phase == "model_completed"' in warmup
assert 'noteModelState("warmup_succeeded")' in warmup
assert 'noteModelState("warmup_model_completed", durationMs: observation.durationMs)' in warmup
assert warmup.index('noteModelState("warmup_started")') < warmup.index('noteModelState("warmup_model_submitted")')

# Mode memory probes must never repeat a SQLite lookup for an identical
# sentence key in the same caption.
lookup = section(engine, "private func lookupModeMemory(", "private func selectModeResult(")
assert "var resolved: [String: String]" in lookup
assert "var missing: Set<String>" in lookup
single_start = lookup.index("if caption.keys.count == 1")
multi_start = lookup.index("var resolved: [String: String]")
single = lookup[single_start:multi_start]
multi = lookup[multi_start:]
assert "guard context == contextRevision, caption.session == modeSessionID" in single
assert single.index("if let hit = bank.values[key]") < single.index("await memoryStore.lookup(key: key)")
assert single.index("await memoryStore.lookup(key: key)") < single.rindex("guard context == contextRevision, caption.session == modeSessionID")
assert "guard let value = hit.value else { return [nil] }" in single
assert multi.index("if let earlier = resolved[key]") < multi.index("await memoryStore.lookup(key: key)")
assert "if missing.contains(key)" in multi
assert "caption.session == modeSessionID" in multi

# Legacy's complete confirmed RAM caption must work on idle and busy model
# lanes, while auto-language detection cannot bypass its own routing.
fast_ram = section(engine, "private func presentQueuedFromRAMIfComplete()", "private func handleClear()")
assert 'if sourceCode != "auto", !bypassMemory, memoryTestMode.allowsReuse' in fast_ram
assert "ExactCaptionIdentity.key" in fast_ram
assert "schedulePresentation(joined, ready.translated" in fast_ram

coordinator_reset = section(coordinator, "func reset() {", "func observe(")
assert "speculationTicket = UUID()" in coordinator_reset
assert "speculation = nil" in coordinator_reset
assert "guard self.speculationTicket == ticket" in coordinator

model = section(diagnostics, "func recordModeModel(", "func recordLatency(")
assert "add(\\.translate, ms)" in model
assert "recordModeSelection(" in model
assert "event(.translation," in model
assert "guard enabled" in model
assert "No" not in model

settings = section(engine, "func diagnosticsSettingsChanged()", "Own-app visibility is observable")
assert "modeDiagnosticEpochs[modeSessionID] = diag.started" in settings
assert "func resetDiagnostics()" in settings
ui = section(dashboard, "private struct DiagnosticsBody: View", "// MARK: Simple")
assert "engine.resetDiagnostics()" in ui
# 2.2.1 (D2): changed from `in ui` to `not in ui`. The handler used to sit here AND in ScreenTranslatorApp, so every
# toggle reset and ended the run twice (the second end produced a 0 s run). Only the root handlers remain.
assert "engine.diagnosticsSettingsChanged()" not in ui
assert "v1.5.0" not in ui
assert "AppVersion.full" not in ui or "AppVersion.full" in dashboard
assert "Measured model processing:" in dashboard
assert "No measurements in this range" in dashboard
# the view reads a DashboardFacts snapshot instead of the whole engine
assert 'facts.system == .legacy' in dashboard

ownership = section(coordinator, "func shouldStartModel(", "func noteOverlappingRecovery(")
assert "speculativeEligible" in ownership
assert "return true" in ownership
assert "current.matches(caption) && committed != current" not in ownership
assert "noteSpeculativeModelSubmitted(" in ownership
assert "speculativeModelSubmitted" in coordinator
assert "if adaptiveHybrid && speculativeModelSubmitted" in coordinator
assert "speculation_superseded_before_confirmation" in archive
assert "backend_stale_request_dropped" in archive
assert "The upcoming subtitle." in tests
assert "Predicted B" in tests and "Confirmed C" in tests
assert "Previous displayed text must not invalidate" in tests

version = read_source("Shared")
project = (root / "project.yml").read_text()
assert 'static let version = "2.3.5"' in version
assert "static let build = 112" in version
assert project.count('"2.3.5"') == 3 and project.count('"112"') == 3

print("v2.2.0 predictive ownership and all-mode Diagnostics routing contract passed")
