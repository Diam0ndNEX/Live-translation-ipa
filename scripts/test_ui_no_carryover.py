#!/usr/bin/env python3
"""Carry-over guard (spec 12.10). Fails if a known problem of the pre-2.0.0 UI returns.
Every pattern carries its U-number from docs/v2.0.0-ui-audit.md. Source checks only; nothing is run."""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
app = root / "App"
FROZEN = {"TranslatorEngine.swift", "PiPRenderer.swift", "TextIntelligence.swift"}  # not UI; headers left alone
files = {p: p.read_text() for p in sorted(app.rglob("*.swift"))}
ui = {p: t for p, t in files.items() if p.name not in FROZEN}
failures = []


def fail(u, msg):
    failures.append(f"{u}: {msg}")


def rel(p):
    return str(p.relative_to(root))


# U1/U2: bare-integer tab switching and the old environment key
for p, t in files.items():
    if "selectTab" in t:
        fail("U1/U2", f"selectTab still used in {rel(p)}")

# U2: five tabs / Activity tab
root_src = (app / "ScreenTranslatorApp.swift").read_text()
tags = re.findall(r"\.tag\(AppTab\.\w+\)", root_src)
if len(tags) != 4:
    fail("U2", f"root TabView must have exactly 4 typed tabs, found {len(tags)}")
if re.search(r'Label\("Activity"', root_src) or ".tag(3)" in root_src:
    fail("U2", "Activity tab is back in the tab bar")

# U3: leaf tabs observe snapshots, not the whole engine
for name in ("Live/LiveView.swift", "Languages/LanguagesView.swift", "Library/LibraryView.swift", "Reader/ReaderView.swift", "Onboarding/OnboardingView.swift"):
    t = (app / name).read_text()
    if re.search(r"@EnvironmentObject[^\n]*TranslatorEngine", t) or "@ObservedObject var engine" in t:
        fail("U3", f"{name} observes the whole engine")
    if "EngineSlice" not in t:
        fail("U3", f"{name} has no narrow view model")

# U4: Home is gone
if (app / "HomeView.swift").exists():
    fail("U4", "HomeView.swift still exists")

# U5: theme
for p, t in ui.items():
    if ".preferredColorScheme(.dark)" in t:
        fail("U5", f"forced dark scheme in {rel(p)}")
    if re.search(r"\bTheme\.", t) or re.search(r"\benum Theme\b", t):
        fail("U5", f"static Theme read in {rel(p)}")
    for m in re.finditer(r"\.system\(size:\s*(\d+(?:\.\d+)?)", t):
        if float(m.group(1)) < 11 and p.name != "BrandMark.swift":
            fail("U5/U12", f"fixed font {m.group(1)} pt in {rel(p)}")
    if ".card()" in t:
        fail("U11", f".card() still used in {rel(p)}")
if (app / "UIParts.swift").exists():
    fail("U5", "UIParts.swift (old theme) still exists")

# U6: Languages tap never silently changes a language
lang = (app / "Languages/LanguagesView.swift").read_text()
if "onTapGesture" in lang:
    fail("U6", "Languages rows use a silent tap gesture")
if "Translate into" not in lang or "Translate from" not in lang:
    fail("U6", "Languages tap does not offer both from and into")

# U7: Library destructive actions
lib = (app / "Library/LibraryView.swift").read_text()
if "Delete visible unstarred" in lib:
    fail("U7", "bulk delete is back in a filter menu")
if "Undo" not in lib:
    fail("U7", "Library delete has no Undo")
if (app / "LibraryViews.swift").exists():
    fail("U7", "LibraryViews.swift (old Library) still exists")

# U9: Session/Workspace/Reader/Area unification and honest preview
ws = (app / "WorkspaceViews.swift").read_text()
if "struct SessionControls" in ws:
    fail("U9", "old SessionControls screen still exists")
if "not your live screen" not in ws and "not a live image" not in ws:
    fail("U9", "Capture area preview is not labelled as a preview")

# U10: one language picker
pickers = sum(len(re.findall(r"struct LanguagePicker\b", t)) for t in files.values())
if pickers != 1:
    fail("U10", f"expected one LanguagePicker implementation, found {pickers}")
if any("LangMenu" in t for t in files.values()):
    fail("U10", "LangMenu still referenced")

# U13: old wording
for p, t in files.items():
    for bad in ("Go to Home", "Translator Capture", "Open Home,", "Home screen", "Home tab"):
        if bad in t:
            fail("U13", f'old wording "{bad}" in {rel(p)}')

# U15: diagnostics content must not be gated on onAppear
diag = (app / "Diagnostics.swift").read_text()
if "onAppear { visible = true }" in diag or "if visible {" in diag:
    fail("U15", "Diagnostics content is gated behind onAppear")

# U16: onboarding
onb = (app / "Onboarding/OnboardingView.swift").read_text()
if "Home tab" in onb or "setupState" not in onb:
    fail("U16", "onboarding wording or resumable skip is wrong")

# U21: stale headers in UI files
for p, t in ui.items():
    first = t.splitlines()[0] if t else ""
    if re.search(r"v0\.\d+\.\d+|v1\.\d+\.\d+", first):
        fail("U21", f"stale file header in {rel(p)}: {first}")
for p in (root / "Shared" / "Shared.swift",):
    if re.search(r"v0\.\d+\.\d+", p.read_text().splitlines()[0]):
        fail("U21", "stale header in Shared.swift")

# U22: dialogs are attached to the owning button, never to a Section
settings = (app / "SettingsViews.swift").read_text()
reset = settings[settings.index("struct ResetSection"):settings.index("private struct PresetsLinkRow")]
if "confirmationDialog" in reset or "confirmDestructive" not in reset:
    fail("U22", "ResetSection dialog is not attached to the button")
if re.search(r"Section\s*\{[^{}]*\}\s*\.confirmationDialog", settings):
    fail("U22", "a confirmationDialog is attached directly to a Section")

# U23: one toast/banner queue
if any("ToastView" in t for t in files.values()):
    fail("U23", "ToastView still used")
for p, t in files.items():
    if "toastText" in t and p.name not in ("ScreenTranslatorApp.swift", "TranslatorEngine.swift"):
        fail("U23", f"{rel(p)} reads engine.toastText instead of the feedback queue")

# U3: Settings pages that only call engine methods must not subscribe to the whole engine
for name, structs in {"SettingsViews.swift": ["ReadingSettings", "IntelligenceSettings", "WindowSettings", "InterfaceSettings",
                                              "PerformanceSettings", "BackupSettings", "AboutSettings", "PrivacySettings"],
                      "CustomizationViews.swift": ["CaptionAppearanceSettings", "ReaderWorkspaceSettings", "FeedbackStorageSettings"],
                      "ExperimentalFeaturesView.swift": ["ExperimentalFeaturesView"],
                      "SettingsCategories.swift": ["TranslationSettings", "HistoryStorageSettings"],
                      "WorkspaceViews.swift": ["TranslationWorkspace", "CaptureAreaEditor"]}.items():
    text = (app / name).read_text()
    for st in structs:
        i = text.index(f"struct {st}")
        j = text.find("\nstruct ", i + 1)
        body = text[i:j if j > 0 else len(text)]
        if re.search(r"@EnvironmentObject[^\n]*TranslatorEngine", body):
            fail("U3", f"{st} still observes the whole engine")

# U2: deep links
if "screenlingo" not in (root / "project.yml").read_text() or "onOpenURL" not in root_src:
    fail("U2", "deep links are not wired")

# Tests are wired into CI
ci = (root / ".github/workflows/build.yml").read_text()
if "test_ui_no_carryover.py" not in ci or "Tests/Navigation/main.swift" not in ci:
    fail("12.10", "guard script or navigation test is not wired into CI")

if failures:
    print("Carry-over guard FAILED:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print(f"Carry-over guard passed: {len(files)} source files checked")
