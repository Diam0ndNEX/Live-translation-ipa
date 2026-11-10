#!/usr/bin/env python3
"""Fast structural regression checks for Settings navigation, ownership and defaults."""
import re
from pathlib import Path
from sources import read_source

root = Path(__file__).resolve().parents[1]
sources = {
    name: read_source(Path(name).stem)
    for name in (
        "SettingsViews.swift", "CustomizationViews.swift", "SettingsCategories.swift",
        "ExperimentalFeaturesView.swift", "SmartPipelineSettings.swift",
        "MemoryManagementView.swift"
    )
}
home = sources["SettingsViews.swift"]
extra = sources["ExperimentalFeaturesView.swift"]
engine = read_source("TranslatorEngine")
presets = read_source("Presets")
recognition_policy = read_source("SubtitlePerformancePolicy")
extension = read_source("SampleHandler")

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
        "incrementalBatchRecovery", "directPiPBuffer", "hybridSwitchGuard",
        "pixelConfirmation", "eventDrivenOCR", "fastOCR", "legacySharedSession",
        "subtitleAwareChangeDetection", "preserveRelatedMovieGroups",
        "adaptiveConfirmation", "confirmationDeadline", "continuousRotation",
        "hybridSchedulerVariant", "hotPathReuseLowLatencyPlan", "hotPathReuseLegacyUnits", "liveWarmupLegacy",
    },
    "SettingsViews.swift": {
        "adaptiveOCR", "subtitleTracking", "deduplicateCopies",
        "rapidTextTracking", "joinAdjacentText", "activeTextFocus",
        "contextualLanguage", "languageRecovery", "smartCool", "keepAwake",
    },
    "SettingsCategories.swift": {
        "translationSystem", "translateAhead", "keepWarm", "remember", "predictiveWarmup",
        "selectiveSpeculation", "adaptiveSpeculation", "speculationConfidence",
        "saveHistory", "historyRetentionDays", "historyCapacity",
        "diagSamples", "testRunSaving", "freshTranslationTest", "temporaryMemoryTest",
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
assert 'Picker("Content style defaults", selection: contentStyleSelection)' in home
assert "private var contentStyleSelection: Binding<String>" in home
assert "recommended[PresetRecognitionPolicy.rapidTextTracking]" in home
assert "recommended[PresetRecognitionPolicy.joinAdjacentText]" in home
assert "recommended[PresetRecognitionPolicy.activeTextFocus]" in home


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
# v2.0.0: the Hybrid switch guard is the measured default; off is the A/B reference.
assert '"hybridSwitchGuard": true' in engine
assert 'modeCoordinator.hybridSwitchGuard = flag("hybridSwitchGuard", true)' in engine
assert '@AppStorage("hybridSwitchGuard") private var hybridSwitchGuard = true' in extra
# v2.0.0 G1/G2 are measured defaults; Fast OCR is an off-by-default experiment.
assert '"pixelConfirmation": true, "eventDrivenOCR": true, "fastOCR": false' in engine
assert 'pixelConfirmation: flag("pixelConfirmation", true)' in engine
assert 'fastOCR: flag("fastOCR", false)' in engine

# Ensure the data controls and their destructive confirmation live in History
# rather than the unrelated Home appearance or feedback screens.
assert "engine.eraseHistory()" in sources["SettingsCategories.swift"]
assert "engine.eraseHistory()" not in home
assert 'Toggle("Copy translations automatically"' in sources["CustomizationViews.swift"]
assert 'Toggle("Vibrate on new translation"' in sources["CustomizationViews.swift"]
assert 'Toggle("Save translation history"' in sources["SettingsCategories.swift"]
# 2.2.1 E4: the content style chosen on Translate or the Tune sheet writes the same three switches as Settings does.
# Game and Comic recommend false for all three, Movie true (the table lives in one place).
assert 'let subtitleStyle = mode == "movie"' in recognition_policy
assert "static func apply(mode: String, to defaults: UserDefaults = .standard)" in recognition_policy
for name in ("TranslateScreen.swift", "TuneSheet.swift"):
    ui = read_source(Path(name).stem)
    assert "PresetRecognitionPolicy.apply(mode: $0)" in ui, f"{name} must apply the content style, not only store it"
# 2.2.1 E3/E13: the dead toggle is gone, the CJK setting is on the Reading page and in reset.
assert "homeMetrics" not in home
assert 'Toggle("Translate single Chinese, Japanese or Korean characters", isOn: $cjkSingleCharacters)' in home
assert '"dropNoise", "cjkSingleCharacters"' in home
print(f"Settings redesign regression checks passed: {len(owners)} saved keys, {len(nav)} routes, no duplicated switches")
