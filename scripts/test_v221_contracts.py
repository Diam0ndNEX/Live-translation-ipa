#!/usr/bin/env python3
"""ScreenLingo 2.2.1 source contracts for the findings fixed in that update.

Each work package adds its own section. These are structural checks: the native Swift suites verify behavior,
and nothing here claims a device result.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
read = lambda relative: (root / relative).read_text(encoding="utf-8")
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
assert "noteHistorySave" in engine and "historySaveMs" in read("App/Diagnostics.swift") and "historySaveMs" in read("App/DiagnosticArchive.swift")
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

print("v2.2.1 WP1 contracts passed: E1, E15, E2, U2, U3, U4, U5")
