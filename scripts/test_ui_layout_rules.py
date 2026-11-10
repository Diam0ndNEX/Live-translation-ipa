#!/usr/bin/env python3
"""ScreenLingo 2.1.0 layout lint (spec §13.8). Source checks only; nothing is compiled or run.

Each rule carries the problem number it prevents (R1-R10 from §13.0.1, or the §13.4 rule). A rule that is only a
text heuristic says so in its message, so a pass is not read as proof of the visual result.
"""
import re
import sys
from pathlib import Path
from sources import read_source

root = Path(__file__).resolve().parents[1]
app = root / "App"
files = {p: p.read_text() for p in sorted(app.rglob("*.swift"))}
failures = []


def rel(p):
    return str(p.relative_to(root))


def fail(rule, path, msg):
    failures.append(f"{rule}: {rel(path)}: {msg}")


def lines_of(text):
    return text.splitlines()


for path, text in files.items():
    ui_file = "/UI/" in str(path)
    for n, line in enumerate(lines_of(text), 1):
        code = line.split("//", 1)[0]
        # §13.4.1 type ramp: caption2 is banned; 12 pt is the minimum fixed size.
        if "caption2" in code:
            fail("§13.4.1", path, f"line {n}: caption2 is below the type ramp")
        for m in re.finditer(r"\.font\(\.system\(size:\s*(\d+(?:\.\d+)?)", code):
            if float(m.group(1)) < 12 and path.name != "BrandMark.swift":
                fail("§13.4.1", path, f"line {n}: fixed font {m.group(1)} pt is below 12 pt")
        # R3: one surface level, no card helpers, no strokes on surfaces, no shadows except the Start button.
        if re.search(r"\binfoCard\b", code):
            fail("R3", path, f"line {n}: infoCard (card inside card)")
        if ".strokeBorder" in code:
            fail("R3", path, f"line {n}: strokeBorder on a surface")
        if ".shadow(" in code and path.name != "StartButton.swift":
            fail("R3", path, f"line {n}: shadow outside the Start button")
        # R5/R8 size discipline: nothing but the live caption, the Start button and the area editor is taller than 120 pt.
        for m in re.finditer(r"frame\([^)]*minHeight:\s*(\d+(?:\.\d+)?)", code):
            if float(m.group(1)) > 120 and path.name not in ("StartButton.swift", "LiveCaption.swift", "AreaEditor.swift"):
                fail("R5/R8", path, f"line {n}: minHeight {m.group(1)} pt is above 120 pt")
        # U5: never force dark mode.
        if ".preferredColorScheme(.dark)" in code:
            fail("U5", path, f"line {n}: forced dark scheme")
        # R4 (heuristic): content must keep the system bottom inset under the tab bar; only backgrounds may ignore it.
        if ".ignoresSafeArea(" in code and ui_file and "edges: .top" not in code and not re.search(r"(Color|background|Background)[^\n]*ignoresSafeArea", code):
            fail("R4", path, f"line {n}: content ignores the safe area (heuristic check)")

    # R8: no tile grid anywhere in Settings.
    if path.name.startswith("Settings") and "LazyVGrid" in text:
        fail("R8", path, "LazyVGrid in a Settings file")

# §13.4.2: deleted components stay deleted.
for name in ("InfoCardModifier", "ScreenScaffold", "SectionHeader", "SettingsTile", "SettingsNavRow",
             "SettingsPageHeader", "LiveStage", "LiveHero", "HealthRing", "IconButton"):
    for path, text in files.items():
        if re.search(rf"\bstruct {name}\b", text):
            fail("§13.4.2", path, f"deleted component {name} is defined again")
# Owner decision after build 91: the Diagnostics page chips come back (pinned, one page at a time),
# so the chip bar is required, not forbidden. Other screens must not grow their own chip bars.
for path, text in files.items():
    if path.name != "DiagnosticsDashboard.swift" and re.search(r"\bfunc pageChip\b|\bvar pageBar\b", text):
        fail("R6", path, "page chips outside Diagnostics")

# §13.3 / U10: one language picker implementation.
pickers = sum(len(re.findall(r"struct (LanguagePicker|LanguageSheet)\b", t)) for t in files.values())
if pickers != 1:
    failures.append(f"U10: expected exactly one language picker implementation (LanguageSheet), found {pickers}")

# R6: Diagnostics has no big summary pinned above every page; only the compact chip bar is pinned.
dash = read_source("DiagnosticsDashboard")
# 2.1.8: the chip row scrolls with the page; a pinned slab is what the owner called "stuck at the top".
if "pinnedViews" in dash:
    failures.append("R6: DiagnosticsDashboard.swift: the page chip bar is pinned again")
if "private var pageBar" not in dash:
    failures.append("R6: DiagnosticsDashboard.swift: the page chip bar is missing")
if re.search(r"HealthRing\(", dash):
    failures.append("R6: DiagnosticsDashboard.swift: a health ring is pinned above the pages")
# R7: no health score shown, and mode names without the build id in the UI.
if re.search(r"\bscore:\s*a\.score\b", dash):
    failures.append("R7: DiagnosticsDashboard.swift: a health score is shown")
for path, text in files.items():
    if path.name in ("TranslatorEngine.swift", "Diagnostics.swift", "DiagnosticArchive.swift"):
        continue
    if re.search(r"(System|system|active|pending)\.title\b", text) and "TranslationSystem" in text + dash:
        for n, line in enumerate(lines_of(text), 1):
            if re.search(r"\b(facts\.system|facts\.active|facts\.pending|activeTranslationSystem|pendingTranslationSystem|system)\.title\b", line):
                fail("R7", path, f"line {n}: mode title with the build id; use shortName")

# R10: toolbar buttons have labels (Label or text), not bare round icons.
for path, text in files.items():
    if "/UI/" not in str(path) and path.name != "DiagnosticsDashboard.swift":
        continue
    for m in re.finditer(r"ToolbarItem[^{]*\{\s*Button\s*\{[^}]*\}\s*label:\s*\{\s*Image\(", text):
        fail("R10", path, "toolbar button with an unlabeled image")

# R1/R2: the old Live preview box and status pill over the headline are gone.
for old in ("Live/LiveView.swift", "Live/LiveSheets.swift", "Languages/LanguagesView.swift",
            "Library/LibraryView.swift", "Reader/ReaderView.swift", "WorkspaceViews.swift"):
    if (app / old).exists():
        failures.append(f"R1/R2/R3: {old} (replaced screen) still exists")
translate = read_source("TranslateScreen")
if "PiPPreview" in translate or "StatusPill" in translate:
    failures.append("R1/R2: Translate draws the old preview box or a status pill")

# R5: Languages groups and collapses its list instead of one flat list.
lang = read_source("LanguageSheet")
for needle in ("Frequently used", "Available to download", "Downloaded", "Not supported on this device"):
    if needle not in lang:
        failures.append(f"R5: LanguageSheet has no '{needle}' group")

# R9: every settings page is a native list (no header card) and the floating caption pages show the preview.
custom = read_source("CustomizationViews")
settings = read_source("SettingsViews")
if "CaptionPreview()" not in custom or "CaptionPreview()" not in settings:
    failures.append("R9: Window and Style pages must start with CaptionPreview")

if failures:
    print("UI layout lint FAILED:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print(f"UI layout lint passed: {len(files)} source files checked")
