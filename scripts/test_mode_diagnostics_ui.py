#!/usr/bin/env python3
"""Static routing regressions paired with the Swift three-mode and iOS CI suites."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
engine = (root / "App/TranslatorEngine.swift").read_text()
diagnostics = (root / "App/Diagnostics.swift").read_text()
coordinator = (root / "Shared/TranslationSystem.swift").read_text()
backend = (root / "App/ModeTranslationService.swift").read_text()
archive = (root / "App/DiagnosticArchive.swift").read_text()
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
assert lookup.index("if let earlier = resolved[key]") < lookup.index("await memoryStore.lookup(key: key)")
assert "if missing.contains(key)" in lookup
assert "caption.session == modeSessionID" in lookup

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
ui = section(diagnostics, "private struct DiagnosticsBody: View", "// MARK: Simple")
assert "engine.resetDiagnostics()" in ui
assert "engine.diagnosticsSettingsChanged()" in ui
assert "v1.5.0" not in ui
assert "AppVersion.full" not in ui or "AppVersion.full" in diagnostics
assert "Measured model processing:" in diagnostics
assert "No measurements in this range" in diagnostics
assert 'engine.activeTranslationSystem == .legacy' in diagnostics

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

version = (root / "Shared/Shared.swift").read_text()
project = (root / "project.yml").read_text()
assert 'static let version = "1.9.5"' in version
assert "static let build = 77" in version
assert project.count('"1.9.5"') == 3 and project.count('"77"') == 3

print("v1.9.5 predictive ownership and all-mode Diagnostics routing contract passed")
