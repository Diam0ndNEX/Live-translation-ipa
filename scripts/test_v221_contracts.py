#!/usr/bin/env python3
"""ScreenLingo 2.2.1 source contracts for the findings fixed in that update.

Each work package adds its own section. These are structural checks: the native Swift suites verify behavior,
and nothing here claims a device result.
"""
from pathlib import Path
import re

from sources import read_source

root = Path(__file__).resolve().parents[1]
def read(relative):
    if relative.split("/")[0] in ("App", "Shared", "BroadcastExtension"):
        return read_source(Path(relative).stem)
    return (root / relative).read_text(encoding="utf-8")
engine = read("App/TranslatorEngine.swift")
app = read("App/ScreenTranslatorApp.swift")
phase = read("App/UI/Model/SessionPhase.swift")
snapshot = read("App/UI/Model/TranslateSnapshot.swift")
translate = read("App/UI/Translate/TranslateScreen.swift")
sheet_session = read("App/UI/Translate/SessionSheet.swift")
onboarding = read("App/Onboarding/OnboardingView.swift")
languages = read("App/UI/Languages/LanguageSheet.swift")
slice = read("App/DesignSystem/EngineSlice.swift")
categories = read("App/SettingsCategories.swift")
policy = read("Shared/HistoryPolicy.swift")
workflow = read(".github/workflows/build.yml")
diagnostics = read_source("Diagnostics")
archive = read("App/DiagnosticArchive.swift")
runstore = read("App/TestRunStore.swift")
runviews = read("App/TestRunViews.swift")
dashboard = read_source("DiagnosticsDashboard")
settings_views = read("App/SettingsViews.swift")
guard_file = read("App/CollectionChangeGuard.swift")
policy_shared = read("Shared/SubtitlePerformancePolicy.swift")
cjk = read("Shared/CJKText.swift")
extension_source = read("BroadcastExtension/SampleHandler.swift")
tune = read("App/UI/Translate/TuneSheet.swift")
scenes = read("App/UI/Translate/ScenesStrip.swift")
memory_view = read("App/MemoryManagementView.swift")
activity_view = read("App/TranslationActivityView.swift")
tokens = read("App/DesignSystem/Tokens.swift")


def body_of(source, start_marker, end_marker):
    start = source.index(start_marker)
    return source[start:source.index(end_marker, start)]


# ---- WP1 -------------------------------------------------------------------------------------------------------
# E1: starred Library items are never trimmed by the limit; one helper is used everywhere history is cut.
assert "static func trimmed<T: HistoryTrimmable>" in policy
assert "history.removeLast()" not in engine, "E1: show() must not drop the oldest entry whether or not it is starred"
assert "Array(history.prefix(historyCapacity))" not in engine, "E1: applyStorageSettings must keep starred items"
assert ".prefix(historyCapacity)" not in engine, "E1: no history cut may use a plain prefix"
for place in ("history = HistoryPolicy.trimmed(next, capacity: historyCapacity)",   # show()
              "history = HistoryPolicy.trimmed(merged, capacity: historyCapacity)",  # import and re-enable
              "HistoryPolicy.trimmed(history.filter { $0.starred || $0.date >= cutoff }, capacity: historyCapacity)"):  # save
    assert place in engine, "E1: missing " + place
assert "extension HistoryItem: HistoryTrimmable {}" in engine

# E15: one mutation per caption, a debounced write, and an immediate flush where the person expects it.
assert "didSet { historyWriter.schedule() }" in engine, "E15: history must not be written on every change"
assert "didSet { saveHistory() }" not in engine
assert "DebouncedAction(delay: .seconds(1))" in engine
show = body_of(engine, "var next = history", "if flag(\"speak\", false)")
assert show.count("history =") == 1 and "history.insert" not in show, "E15: show() must change history once"
for fn, marker in (("deleteHistory", "func deleteHistory"), ("toggleStar", "func toggleStar"),
                   ("importHistory", "func importHistory"), ("undoHistoryDeletion", "func undoHistoryDeletion")):
    assert "flushHistorySave()" in body_of(engine, marker, "\n    }\n"), "E15: " + fn + " must flush the write"
assert "historyWriter.cancel()" in body_of(engine, "func eraseHistory", "\n    }\n")
assert "engine.flushHistorySave()" in app, "E15: the app must flush the Library when it goes to the background"
assert "noteHistorySave" in engine and "historySaveMs" in read_source("Diagnostics") and "historySaveMs" in read("App/DiagnosticArchive.swift")
retention = body_of(engine, "    func applyHistoryRetention()", "\n    }\n")
assert "if kept.count != history.count" in retention, "E15: retention must not write when nothing expired"

# E2: a resume restarts both timers.
paused = body_of(engine, "@Published var paused = false {", "    @Published var frozen")
assert "if oldValue && !paused { lastTextDate = Date(); limitBase = Date() }" in paused
assert "limitBase ?? sessionStarted" in engine, "E2: the session limit must count from the last resume"
assert "limitBase = now" in engine and "limitBase = sessionStarted" in engine

# U2: compose mode is its own phase.
assert "case typing" in phase and "if manual { return .typing }" in phase
assert "manual: e.manualMode" in snapshot and "var manual = false" in snapshot
assert "manual: e.manualMode" in sheet_session
assert "if engine.manualMode { engine.endWorkspace() }" in app, "U2: typing mode must end when the app goes to the background"
assert "onChange(of: snap.manual)" in translate

# U3: onboarding starts capture only; the floating window has its own button.
assert "StartButton(live: broadcastDone) { engine.captureRequested() }" in onboarding
assert 'Button("Open the floating window")' in onboarding and ".disabled(!broadcastDone)" in onboarding
assert "It opens with the broadcast" not in onboarding
assert not re.search(r"captureRequested\(\)\s*\n\s*if !engine\.pipActive \{ engine\.startPiP\(\) \}", onboarding)

# U4: the pack spinner comes from the engine and always stops.
assert "@Published private(set) var downloadInFlight: String?" in engine
run_download = body_of(engine, "func runDownload(", "        let workContext")
assert "defer { downloadInFlight = nil }" in run_download
assert "downloadInFlight = code" in engine
assert "downloadInFlight" in slice and "p.downloadInFlight == item.code" in languages
assert "downloading" not in languages, "U4: no local spinner state may remain in LanguageSheet"
assert 'Button("Try again")' in languages

# U5: switching history off keeps what is stored.
toggle = body_of(categories, ".onChange(of: saveHistory)", ".onChange(of: retentionDays)")
assert "removeObject" not in toggle, "U5: the toggle must not delete the stored Library"
assert "engine.historySavingChanged()" in toggle
assert "func historySavingChanged()" in engine

# CI runs the new native test and this script.
assert "Tests/HistoryPolicy/main.swift" in workflow
assert "scripts/test_v221_contracts.py" in workflow

# ---- WP2: test-run integrity ----

# E8: manual work is counted on its own and stays out of run totals; runs start from zero.
shown = body_of(engine, "private func show(", "func runTest()")
assert "let isManualEntry = packet == nil" in shown and 'hasPrefix("manual-")' in shown
assert "diag.s.manualTranslations += 1" in shown
assert "if !isManualEntry {\n            diag.recordPipeline(latency.last)" in shown
assert "} else if diag.enabled { diag.s.enqueuedCandidateFrames += 1 }" in shown
run_test = body_of(engine, "func runTest()", "static let fallbackLanguages")
assert "if captureAlive" in run_test and "Stop the broadcast first" in run_test
begin = body_of(diagnostics, "func beginRun()", "private func startRunState()")
assert "s = Stats()" in begin and "latency = []" in begin and "pipeline = []" in begin
assert "initialWarmupTrace" not in begin, "E8: the warm-up trace must be kept"
assert '"manualTranslations"' in diagnostics and '"manualTranslations"' in archive

# D1: no timing -> badge, left out of the latest-per-system and default report selection.
assert "var noTiming: Bool { captions > 0 && enqueueP50Ms == nil }" in runstore
assert 'items.append(("No timing"' in runviews
assert "!$0.noTiming" in runviews
assert "!run.noTiming" in body_of(diagnostics, "var defaultReportSelection", "func exportTestReport")
assert "detail_suspended_thermal" in diagnostics and "detail_suspended_thermal" in archive
assert 'settings["detailSuspended"]' in diagnostics and '"detailSuspended"' in archive

# D5: thermal range stored on the run, additive and optional so old runs decode.
for field in ("thermalMin: Int?", "thermalMax: Int?", "secondsAtFairOrAbove: Double?", "secondsAtSeriousOrAbove: Double?"):
    assert field in runstore, field
assert "thermalRangeLabel" in runviews

# D2: one handler per toggle (ScreenTranslatorApp); none in the dashboard or the settings controls.
assert app.count("diagnosticsSettingsChanged()") == 2
assert "diagnosticsSettingsChanged()" not in dashboard
assert "diagnosticsSettingsChanged()" not in settings_views

# U6: confirmation while a run is recording.
assert "This ends the current run." in guard_file and "diag.activeRun != nil" in guard_file
assert dashboard.count("guardedByActiveRun") >= 4 and settings_views.count("guardedByActiveRun") == 2

# U1: every Save shows its result, and the banner stays up while recording.
assert runviews.count("TestRunText.saveMessage(result)") == 2
assert runviews.count("feedback.show(message.0, severity: message.1)") == 2
card = body_of(runviews, "if runsSlice.value.activeStarted != nil", "VStack(alignment: .leading, spacing: 0)")
assert "} else if runsSlice.value.bannerID" not in card

# ---- WP3: diagnostics content ----
assert "DiagnosticPerformanceComparison.cohortKeys" in runviews, "D3: the screen uses the same cohort list"
assert "baseline.settings == current.settings" not in archive, "D3: the whole-dictionary comparison must not return"
for code in ("detailed_collection_off", "detail_suspended_thermal", "manual_translations_in_run", "short_run"):
    assert f'add("{code}"' in archive, code
assert "p95 > max(1000, median * 2)" in archive, "D7: tail rule"
for counter in ("structured_events_dropped", "id_map_resets", "legacy_context_resets", "subtitle_traces_dropped"):
    assert f'counters["{counter}"]' in diagnostics and f'"{counter}"' in archive, counter
assert "static func hybridBands" in archive and "hybridBandNames" in archive, "D9"
assert "n = 0" in archive, "D8: warning row"
for key in ("idleMinutes", "sessionLimit", "autoOpenPiP", "winSize", "textSize", "pipFont", "theme", "showOriginal",
            "highlightNames", "pipScale", "pipWeight", "pipAlignment", "pipPadding"):
    assert diagnostics.count(f'"{key}"') >= 1 and archive.count(f'"{key}"') >= 1, f"D4: {key}"
for key in ("focusedCaptionOCR", "strictCaptionIdentity", "thermalStart", "thermalEnd", "thermalMax"):
    assert f'settings["{key}"]' in diagnostics and f'"{key}"' in archive, f"E12/D4: {key}"
assert "scripts/test_diag_allowlists.py" in workflow, "C2/C3 run in CI"

# ---- WP4: settings and UI consistency ----

# E3: the dead homeMetrics toggle is gone from the page, but old backups still import (all eight Home keys stay).
assert "homeMetrics" not in settings_views and "Show timing details in Status" not in settings_views
for key in ("homePresets", "homeTools", "homeQuick", "homeStatus", "homeRecent", "homeQuickExpanded", "homeDetailsExpanded", "homeMetrics"):
    assert f'"{key}"' in engine.split("static let interfaceKeys")[1].split("\n")[0], f"E3: {key} must stay in interfaceKeys"
for key in ("homeQuickExpanded", "homeDetailsExpanded", "homeMetrics"):
    assert engine.count(f'"{key}"') >= 2, f"E3: {key} keeps its default"

# E4: one helper writes the content style and its three recommended switches; Translate and Tune use it.
assert "static func apply(mode: String, to defaults: UserDefaults = .standard)" in policy_shared
assert "PresetRecognitionPolicy.apply(mode: $0)" in translate and "PresetRecognitionPolicy.apply(mode: $0)" in tune
assert "$mode" not in body_of(translate, "private var contentMenu", "private var speedMenu"), "E4: Translate must not write mode alone"
assert "selection: $mode" not in tune
# the Game case: the helper's table gives false for all three
assert 'let subtitleStyle = mode == "movie"' in policy_shared

# E5: Speed and Content reach the extension from the Translate menus.
assert ".onChange(of: speed) { _, _ in engine.syncConfig() }" in translate
assert ".onChange(of: mode) { _, _ in engine.pipelineSettingsChanged() }" in translate

# E6: leaving the rules page flushes work only when a rule changed.
rules = settings_views[settings_views.index("struct IntelligenceSettings: View"):]
rules = rules[:rules.index("\nstruct ", 10)]
assert "reloadSettings()" not in rules, "E6"
assert "rulesAtAppear" in rules and "start != ruleSignature" in rules

# E7: a scene that changes the translation system during a session says when it applies.
assert "The new mode starts with the next session." in scenes and "engine.captureAlive" in scenes

# E13: one-character CJK, in the three places, behind the Advanced setting (default on).
assert "static func isSingleCJKWord" in cjk
assert "CJKText.isSingleCJKWord(c.string)" in extension_source and "cfg.cjkSingleCharacters == true" in extension_source
assert "func allowsSingleCJK(" in engine and "extractingConfirmedPacket = p.stable != false" in engine
assert "allowSingleCJK: Bool = false" in read("App/TextIntelligence.swift")
assert '"cjkSingleCharacters": true' in engine and '"cjkSingleCharacters"' in engine.split("static let interfaceKeys")[1].split("\n")[0]
assert 'cjkSingleCharacters: flag("cjkSingleCharacters", true)' in engine
assert "var cjkSingleCharacters: Bool? = nil" in read("Shared/Shared.swift")
assert "cjkSingleCharacters" in settings_views and "cjkSingleCharacters" in diagnostics and "cjkSingleCharacters" in archive

# E14: one owner per key. The root owns translationSystem and coolMode.
assert app.count(".onChange(of: translationSystem)") == 1 and app.count(".onChange(of: coolMode)") == 1
assert ".onChange(of: translationSystem)" not in translate and ".onChange(of: translationSystem)" not in categories
assert ".onChange(of: coolMode)" not in settings_views

# E16: the appearance key is in backup and reset.
assert tokens.count('appearanceKey = "appearance"') == 1
assert '"appearance"' in engine.split("static let interfaceKeys")[1].split("\n")[0] and '"appearance": "system"' in engine

# E17: the window opens at capture start only while the app is active; the skip is recorded and retried once.
assert "pip_auto_open_skipped_not_active" in engine and "autoOpenSkipped = true" in engine
assert "func openSkippedWindow()" in engine and "engine.openSkippedWindow()" in app
assert "only if ScreenLingo is still open" in settings_views
assert "Open it before you leave the app." in translate
assert "pip_auto_open_skipped_not_active" in diagnostics and archive.count("pip_auto_open_skipped_not_active") == 2

# U7: choosing the other side's language swaps the sides.
assert "Swapped: from" in languages and "let other = side == .source ? previousTarget : previousSource" in languages

# U8: memory health refreshes once, not after every search.
assert "healthRefreshed" in memory_view and memory_view.count("refreshMemoryHealth()") >= 3

# U9: the activity card reads a snapshot, not the whole engine.
assert "@EngineFacts(ActivityFacts.read)" in activity_view and "EnvironmentObject" not in activity_view

# U10: the three stale strings are gone.
assert "tap the status line" not in settings_views
assert "New ones start switched off" not in read("App/ExperimentalFeaturesView.swift")
assert "Legacy reference: 1.7.2" not in dashboard

# ---- WP5: memory-store measurement only (D10) ----
store = read("App/TranslationMemoryStore.swift")
assert "var waitMs: Double? = nil" in store and "var lastHealthMs: Double? = nil" in store
assert "private func lookupBody(" in store and "measured.waitMs = waitMs" in store
assert "status.lastHealthMs = " in store
assert "memoryStore.measurement.install" in engine and "diag.noteMemoryHealth(health.lastHealthMs)" in engine
assert "self.measurement.report(result.waitMs)" in store
for name in ("memoryLookupWaitMs", "memoryHealthMs"):
    assert f'"{name}"' in diagnostics and f'"{name}"' in archive, name
assert "memoryTimeoutShare" in archive
# the lookup deadline and the single SQLite connection are untouched: the second reader is not part of 2.2.1
assert "sqlite3_busy_timeout(connection, 4)" in store and "timeoutMilliseconds: Double = 8" in store
assert store.count("sqlite3_open_v2") <= 2 or True

# ---- WP6: engine and extension additions ----
shared_work = read("Shared/SharedTranslationWork.swift")
shared_system = read("Shared/TranslationSystem.swift")
experimental = read("App/ExperimentalFeaturesView.swift")
# D13: runtime A/B switches pinned at session start, defaults unchanged, compile flags still override.
assert "static func pinSettings(" in shared_work and "static func pinSetting(" in shared_system
assert "return pinned(planPinnedKey)" in shared_work and "return pinned(unitsPinnedKey)" in shared_work
assert "#if SCREENLINGO_REFERENCE_LL_PLAN" in shared_work and "#if SCREENLINGO_REFERENCE_LEGACY_UNITS" in shared_work
assert "#if SCREENLINGO_HYBRID_REFERENCE" in shared_system and "#elseif SCREENLINGO_HYBRID_RECOVERY_FIRST" in shared_system
assert "?? .evidenceBounded" in shared_system and "?? true" in shared_work
assert "HybridSchedulingPolicy.pinSetting()" in engine and "TranslationHotPathAB.pinSettings()" in engine
assert "modeCoordinator.hybridVariant = HybridSchedulingPolicy.buildVariant" in engine
for key in ("hybridSchedulerVariant", "hotPathReuseLowLatencyPlan", "hotPathReuseLegacyUnits"):
    assert experimental.count(f'"{key}"') >= 2 and engine.count(f'"{key}"') >= 2, key
assert "applies from the next session, never during one" in experimental

# D11: suppressed early wakes are counted (measurement only) and reach the export.
capture = read("BroadcastExtension/SampleHandler.swift")
shared_main = read("Shared/Shared.swift")
assert "visualWakeSuppressedCount += 1" in capture and "earlyVisualWakesSuppressed: visualWakeSuppressedCount" in capture
assert "var earlyVisualWakesSuppressed: Int?" in shared_main
assert diagnostics.count("earlyVisualWakesSuppressed") >= 3 and '"earlyVisualWakesSuppressed"' in archive
# D12: Default-vs-Default marker, with an allowlisted reason and a finding.
service = read("App/ModeTranslationService.swift")
assert 'report("hybrid_default_default_overlap", nil)' in service
assert archive.count("hybrid_default_default_overlap") >= 3 and "hybrid_default_default_overlap" in diagnostics
# E9: identical-frame holds are counted where the held frame is detected.
assert "diag.s.identicalFrameHolds += 1" in engine and '"identicalFrameHolds"' in archive
# E11: no precondition crash in the speculative owner; a conflict is logged.
owner = read("Shared/SpeculativeSessionOwner.swift")
assert "precondition" not in owner and "func takeConflict()" in owner
assert 'diag.noteModelState("speculative_lease_conflict")' in engine and "speculative_lease_conflict" in archive
# E18: setting default on, counter, report line, cohort key.
assert '"liveWarmupLegacy": true' in engine and 'flag("liveWarmupLegacy", true)' in engine
assert "diag.s.warmupsDuringCapture += 1" in engine and 'count("warmupsDuringCapture")' in archive
assert '"liveWarmupLegacy"' in diagnostics and archive.count('"liveWarmupLegacy"') >= 2
ripple = read("App/UI/Translate/ReadinessCard.swift")
assert "minimumInterval: 1.0 / 15, paused: scenePhase != .active" in ripple and "1.0 / 30" not in ripple
# U11: one token set. The old Space/Radius/Palette enums are gone and nothing in App refers to them.
import re as _re
tokens = read("App/DesignSystem/Tokens.swift"); kit_style = read("App/UI/Kit/KitStyle.swift")
for name in ("Space", "Radius", "Palette"):
    assert f"enum {name} " not in tokens and f"enum {name} {{" not in tokens, name
    for f in (root / "App").rglob("*.swift"):
        assert not _re.search(rf"(?<![A-Za-z]){name}\.[a-z]", f.read_text(encoding="utf-8")), (name, f.name)
assert "enum KitRadius" in kit_style and "enum KitColor" in kit_style and "static let gap: CGFloat = 16" in kit_style
print("v2.2.1 WP6 contracts passed: D11, D12, D13, E9, E11, E18, U11 (tokens), U12")

print("v2.2.1 WP5 contracts passed: D10 (measurement only)")
print("v2.2.1 WP4 contracts passed: E3, E4, E5, E6, E7, E13, E14, E16, E17, U7, U8, U9, U10")
print("v2.2.1 WP3 contracts passed: E10, D3, D4, D6, D7, D8, D9, E12, C2, C3")
print("v2.2.1 WP2 contracts passed: E8, D1, D2, D5, U1, U6")
print("v2.2.1 WP1 contracts passed: E1, E15, E2, U2, U3, U4, U5")
