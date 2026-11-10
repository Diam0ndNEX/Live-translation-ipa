#!/usr/bin/env python3
"""Keeps docs/structure-guidelines.md from going stale.

  python3 scripts/test_structure_docs.py          check (CI)
  python3 scripts/test_structure_docs.py --write  regenerate the size table, then check

Checks:
  1. The size table between the sizes markers matches the files on disk (lines rounded to 50).
  2. "Reviewed for: X.Y" in the guidelines equals the major.minor version in Shared/Shared.swift.
     At a new minor version (2.4.0, 3.0.0 ...) CI fails until someone re-reads the guidelines and updates it.
  3. Every Swift file over 800 lines is named in the guidelines table (a reason is needed above 800).
  4. docs/v<version>-specification.md exists and is listed in docs/README.md.
"""
import re, sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
guide = root / "docs/structure-guidelines.md"
START, END = "<!-- sizes:start -->", "<!-- sizes:end -->"
SWIFT_DIRS = ("App", "Shared", "BroadcastExtension")

def swift_files():
    return sorted(p for d in SWIFT_DIRS for p in (root / d).rglob("*.swift"))

def lines(p):
    return len(p.read_text().splitlines())

def table():
    files = swift_files()
    parts = {}
    mains = {}
    for p in files:
        if "+" in p.stem:
            parts.setdefault(p.stem.split("+")[0], []).append(p)
        else:
            mains[p.stem] = p
    rows = []
    for stem, plist in parts.items():
        main = mains.get(stem)
        if main is None:
            continue
        rows.append((lines(main), stem, str(main.relative_to(root)), len(plist)))
    rows.sort(reverse=True)
    out = ["| Main file | Lines (rounded to 50) | Part files |", "|---|---|---|"]
    for n, stem, rel, count in rows:
        out.append(f"| {rel} | {round(n / 50) * 50} | {count} |")
    return "\n".join(out)

def main():
    text = guide.read_text()
    if START not in text or END not in text:
        sys.exit("structure-guidelines.md has no sizes markers")
    head, rest = text.split(START, 1)
    old_table, tail = rest.split(END, 1)
    new_table = "\n" + table() + "\n"
    if "--write" in sys.argv and old_table != new_table:
        guide.write_text(head + START + new_table + END + tail)
        text = guide.read_text()
        print("structure-guidelines.md: size table regenerated")
    failures = []
    if START + new_table + END not in text:
        failures.append("the size table is out of date: run python3 scripts/test_structure_docs.py --write")
    version = re.search(r'static let version = "(\d+)\.(\d+)\.(\d+)"', (root / "Shared/Shared.swift").read_text())
    major_minor = f"{version[1]}.{version[2]}"
    reviewed = re.search(r"Reviewed for: (\d+\.\d+)", text)
    if not reviewed or reviewed[1] != major_minor:
        failures.append(f"structure-guidelines.md says 'Reviewed for: {reviewed[1] if reviewed else 'nothing'}' but the app is {major_minor}.x: "
                        "re-read the whole file against the code, fix what is outdated, then set 'Reviewed for: %s'" % major_minor)
    for p in swift_files():
        if lines(p) > 800 and p.name not in text:
            failures.append(f"{p.relative_to(root)} has {lines(p)} lines (over 800) and is not named in structure-guidelines.md")
    full = f"{version[1]}.{version[2]}.{version[3]}"
    spec = root / f"docs/v{full}-specification.md"
    if not spec.exists():
        failures.append(f"docs/v{full}-specification.md is missing")
    elif spec.name not in (root / "docs/README.md").read_text():
        failures.append(f"{spec.name} is not listed in docs/README.md")
    if failures:
        print("Structure docs check FAILED:")
        for f in failures:
            print(" -", f)
        sys.exit(1)
    print(f"structure docs are current (reviewed for {major_minor}, spec v{full})")

main()
