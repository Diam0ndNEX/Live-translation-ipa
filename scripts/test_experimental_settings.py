#!/usr/bin/env python3
"""Fast structural checks for the consolidated Experimental Features tab."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
home = (root / "App" / "SettingsViews.swift").read_text()
experiments = (root / "App" / "ExperimentalFeaturesView.swift").read_text()
legacy = (root / "App" / "SmartPipelineSettings.swift").read_text()
engine = (root / "App" / "TranslatorEngine.swift").read_text()

experiment_keys = {
    "lowLatencyTranslation", "incrementalBatchRecovery", "directPiPBuffer",
    "subtitleAwareChangeDetection", "preserveRelatedMovieGroups",
    "adaptiveOCR", "adaptiveConfirmation", "subtitleTracking", "deduplicateCopies",
    "selectiveSpeculation", "adaptiveSpeculation", "speculationConfidence",
    "confirmationDeadline", "steadyCaptions", "protectConfirmedPresentation",
    "smartCool", "contextualLanguage", "continuousRotation", "languageRecovery",
    "predictiveWarmup", "freshTranslationTest",
}
for key in experiment_keys:
    binding = f'@AppStorage("{key}")'
    assert experiments.count(binding) == 1, f"Experimental UI missing/duplicates {key}"
    assert binding not in home, f"Legacy Settings page duplicates {key}"
    assert f'"{key}"' in engine, f"Engine cannot backup/reset {key}"
    assert experiments.count(f'"{key}"') >= 2, f"Reset key missing from Experimental UI: {key}"

assert "NavigationLink { ExperimentalFeaturesView() }" in home
assert 'Label("Experimental Features"' in home
assert "ExperimentalFeaturesView()" in legacy, "Old Smart pipeline route must remain compatible"
assert 'Toggle("Skip unchanged frames"' in home, "Normal OCR controls must remain accessible"
assert 'Toggle("Translate ahead"' in home, "Normal translation control must remain accessible"
assert 'Toggle("Remember translations"' in home, "Normal translation memory control must remain accessible"
assert '.onChange(of: lowLatencyTranslation) { _, _ in engine.translationStrategyChanged() }' in experiments
assert '.onChange(of: directPiPBuffer) { _, _ in engine.applyStyle() }' in experiments
assert '.onChange(of: pipelineSignature) { _, _ in engine.pipelineSettingsChanged() }' in experiments
assert 'if #available(iOS 26.4, *)' in experiments
assert "enabled: $subtitleAwareChangeDetection," in experiments
assert "available: skipUnchanged" in experiments
assert "enabled: $preserveRelatedMovieGroups," in experiments
assert "available: mode == TranslateMode.movie.rawValue" in experiments
for important in ("adaptiveOCR", "subtitleTracking", "steadyCaptions", "smartCool", "predictiveWarmup"):
    assert f'@AppStorage("{important}") private var' in experiments
assert '"lowLatencyTranslation": false' in engine
assert '"incrementalBatchRecovery": false' in engine
assert '"directPiPBuffer": false' in engine
assert '"subtitleAwareChangeDetection": false' in engine
assert '"preserveRelatedMovieGroups": false' in engine
print(f"Experimental Features: {len(experiment_keys)} saved controls consolidated, defaults preserved")
