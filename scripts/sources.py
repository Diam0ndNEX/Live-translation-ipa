#!/usr/bin/env python3
"""Finds Swift sources by logical name so tests keep working when a file is moved or split.

read_source("TranslatorEngine") returns the text of TranslatorEngine.swift plus every split part named
TranslatorEngine+<Topic>.swift, wherever they sit under App/, Shared/ or BroadcastExtension/.
See docs/structure-guidelines.md section 6. Nothing here compiles or runs the app.

Use from a script in scripts/ (run as `python3 scripts/<name>.py`, so this folder is on sys.path):
    from sources import read_source
    engine = read_source("TranslatorEngine")
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
SOURCE_DIRS = ("App", "Shared", "BroadcastExtension")


def source_files(name):
    """The main file first, then its split parts (Name+Topic.swift) in path order."""
    found = []
    for directory in SOURCE_DIRS:
        base = root / directory
        if not base.is_dir():
            continue
        for path in base.rglob("*.swift"):
            if path.stem == name or path.stem.startswith(name + "+"):
                found.append(path)
    exact = [p for p in found if p.stem == name]
    if len(exact) > 1:
        raise RuntimeError("More than one file named " + name + ".swift: " + ", ".join(p.as_posix() for p in exact))
    return sorted(found, key=lambda p: (p.stem != name, p.as_posix()))


def read_source(name):
    files = source_files(name)
    if not files:
        raise FileNotFoundError("No Swift source named " + name + " under " + ", ".join(SOURCE_DIRS))
    return "\n".join(p.read_text(encoding="utf-8") for p in files)
