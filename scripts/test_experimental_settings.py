#!/usr/bin/env python3
"""Fast structural regression checks for Settings navigation, ownership and defaults."""
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sources = {
    name: (root / "App" / name).read_text()
    for name in (
        "SettingsViews.swift", "CustomizationViews.swift", "SettingsCategories.swift",
        "ExperimentalFeaturesView.swift", "SmartPipelineSettings.swift",
        "MemoryManagementView.swift"
    )
}
home = sources["SettingsViews.swift"]
extra = sources["ExperimentalFeaturesView.swift"]
engine = (root / "App" / "TranslatorEngine.swift").read_text()
presets = (root / "App" / "Presets.swift").read_text()
recognition_policy = (root / "Shared" / "SubtitlePerformancePolicy.swift").read_text()
extension = (root / "BroadcastExtension" / "SampleHandler.swift").read_text()

# Every editable option has one owner page. The Experimental page only
# observes whether Skip unchanged frames is enabled.
owners = {}
for name, source in sources.items():
    for key in re.findall(r'@AppStorage\("([^"]+)"\)', source):
        owners.setdefault(key, []).append(name)
for key, names in owners.items():
    if key == "skipUnchanged":
        assert sorted(names) == ["ExperimentalFeaturesView.swift", "SettingsViews.swift"]
    else:
        assert len(names) == 1, f"{key} duplicated across Settings: {names}"

expected = {
    "ExperimentalFeaturesView.swift": {
        "incrementalBatchRecovery", "directPiPBuffer",
        "subtitleAwareChangeDetection", "preserveRelatedMovieGroups",
        "adaptiveConfirmation", "confirmationDeadline", "continuousRotation",
    },
    "SettingsViews.swift": {
        "adaptiveOCR", "subtitleTracking", "deduplicateCopies",
        "rapidTextTracking", "joinAdjacentText", "activeTextFocus",
        "contextualLanguage", "languageRecovery", "smartCool", "keepAwake",
        "homeMetrics", "homeQuickExpanded", "homeDetailsExpanded",
    },
    "SettingsCategories.swift": {
        "translationSystem", "translateAhead", "keepWarm", "remember", "predictiveWarmup",
        "selectiveSpeculation", "adaptiveSpeculation", "speculationConfidence",
        "saveHistory", "historyRetentionDays", "historyCapacity",
        "diagSamples", "persistDiagnosticSessions", "freshTranslationTest", "temporaryMemoryTest",
    },
    "CustomizationViews.swift": {
        "displayPolicy", "minDisplay", "heartbeatInterval",
        "steadyCaptions", "protectConfirmedPresentation",
        "haptics", "hapticStrength", "autoCopy", "autoCopyFormat",
        "speak", "speechRate", "interruptSpeech",
    },
}
for file, keys in expected.items():
    for key in keys:
        assert owners.get(key) == [file], f"{key} should be on {file}: {owners.get(key)}"
        assert f'"{key}"' in engine, f"Setting {key} is missing from engine backup/reset"
        assert sources[file].count(f'"{key}"') >= 2, f"{key} missing from page reset keys"

# All presets must expose the same capabilities. Names are metadata,
# never permission checks in the actual capture pipeline.
assert "if mode == .movie" not in engine
assert "OCRGrouping.makeBlocks(lines, joinAdjacentText:" in engine
assert 'if flag("activeTextFocus", true)' in engine
assert 'rapidTextTracking: flag("rapidTextTracking", true)' in engine
assert "cfg.rapidTextTracking ?? cfg.movieMode ?? false" in extension
assert 'legacyDefaults(for: "movie")' not in extension
for key in ("rapidTextTracking", "joinAdjacentText", "activeTextFocus"):
    assert presets.count(f'"{key}": true') >= 2, f"Movie and Lyrics presets must enable {key}"
    assert presets.count(f'"{key}": false') >= 2, f"Game and Comic presets must disable {key}"
    assert f'static let {key} = "{key}"' in recognition_policy
assert "legacyOptions[k]" in presets, "Older imported custom presets must retain their behavior"

nav = [
    "ReadingSettings()", "IntelligenceSettings()", "TranslationSettings()",
    "WindowSettings()", "ResponsivenessSettings()", "FeedbackStorageSettings()",
    "InterfaceSettings()", "ReaderWorkspaceSettings()", "HistoryStorageSettings()",
    "PerformanceSettings()", "ExperimentalFeaturesView()", "DiagnosticsSettings()",
    "PrivacySettings()", "BackupSettings()", "AboutSettings()",
]
for page in nav:
    assert f"destination: {page}" in home, f"Settings route missing: {page}"
assert 'PresetsLinkRow(store: engine.presets)' in home
assert "ExperimentalFeaturesView()" in sources["SmartPipelineSettings.swift"]
assert "PipelineSimulatorView()" in sources["SettingsCategories.swift"]
assert 'NavigationLink { CaptionAppearanceSettings() }' not in home

for key in ("incrementalBatchRecovery",
            "directPiPBuffer", "subtitleAwareChangeDetection", "preserveRelatedMovieGroups"):
    assert f'"{key}": false' in engine, f"New experiment {key} must remain off by default"
assert 'Picker("Translation system"' in sources['SettingsCategories.swift']
assert "available: skipUnchanged" in extra
assert "available: mode == TranslateMode.movie.rawValue" not in extra
assert '@AppStorage("mode")' not in extra
assert 'enabled: $preserveRelatedMovieGroups)' in extra
assert "PresetRecognitionPolicy.migrate(UserDefaults.standard)" in engine
assert 'movieMode: flag("rapidTextTracking", true)' in engine
assert '@AppStorage("lowLatencyTranslation")' not in extra
assert '.onChange(of: pipelineSignature) { _, _ in engine.pipelineSettingsChanged() }' in extra
assert '.onChange(of: directPiPBuffer) { _, _ in engine.applyStyle() }' in extra

# Ensure the data controls and their destructive confirmation live in History
# rather than the unrelated Home appearance or feedback screens.
assert "engine.eraseHistory()" in sources["SettingsCategories.swift"]
assert "engine.eraseHistory()" not in home
assert 'Toggle("Copy translations automatically"' in sources["CustomizationViews.swift"]
assert 'Toggle("Vibrate on new translation"' in sources["CustomizationViews.swift"]
assert 'Toggle("Save translation history"' in sources["SettingsCategories.swift"]
print(f"Settings redesign regression checks passed: {len(owners)} saved keys, {len(nav)} routes, no duplicated switches")
