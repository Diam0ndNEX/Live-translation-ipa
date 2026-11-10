# ScreenLingo docs index

Files are named by the version they were written for. Grouped here by purpose; the files themselves have not been moved or edited. Descriptions come from file names, not a re-read of every file.

Older documents are records of what was true when they were written. They name branches, PRs and commands that may no longer exist or apply (for example `codex/screenlingo-v1.9.9-recovery-evidence` as PR base). Do not treat them as instructions; the rules for new work are in the two files below.

## Rules for code, tests and docs (read before an update)
- structure-guidelines.md: where new code goes, extract-on-touch for the giant files, test and CI path rules, update checklist
- structure-migration-plan.md: which scripts depend on which files, and the order for moving and splitting existing files

## Current line (start here)
- v2.3.8-specification.md: newest specification (remaining big files split, not TranslatorEngine)
- v2.3.7-specification.md: the five big files split
- v2.3.6-specification.md: memory store, dashboard and recorder models split
- v2.3.5-specification.md: memory store split, stage 2
- v2.3.4-specification.md: memory store split, stage 1
- v2.3.3-specification.md: layout, tests find Swift by name, first splits, faster CI. Older line: (2.3.2 has no specification file; see the changelog in `Shared/Shared.swift`)
- v2.3.1-specification.md
- v2.3.0-specification.md
- v2.2.3-specification.md: includes the 2.2.2 b105 latency test figures
- v2.2.1-specification.md, v2.2.1-decisions.md, v2.2.1-addendum.md, v2.2.1-prompt.md

## UI/UX rebuild (2.0.0 to 2.1.0)
- v2.1.0-ui-ux-ground-up-specification.md, v2.1.0-ui-ux-prompt.md, v2.1.0-ui-audit.md
- v2.0.0-ui-ux-overhaul-specification.md, v2.0.0-ui-ux-prompt.md, v2.0.0-ui-audit.md, v2.0.0-ui-problem-fix-table.md
- v2.0.0-specification.md, v2.0.0-test-runs-specification.md

## Three-mode architecture and performance (1.9.x)
- v1.9.0-three-modes.md, v1.9.0-handoff.md
- v1.9.1-hybrid-performance.md, v1.9.2-specification.md, v1.9.3-specification.md, v1.9.4-measured-reliability.md
- ScreenLingo-v1.9.5-Audit.md, ScreenLingo-v1.9.6-Architecture.md, ScreenLingo-v1.9.7-Architecture.md
- ScreenLingo-v1.9.8-Audit.md, ScreenLingo-v1.9.9-Retrospective.md
- ScreenLingo-v1.9.6-Baseline.json, ScreenLingo-v1.9.7-Baseline.json: baseline numbers

## Earlier history (1.4.x to 1.7.x)
- v1.7.0-performance.md, v1.7.1-testing-and-scheduling.md, v1.7.2-performance.md
- v1.5.0-*: acceptance, diagnostics-zip-v3, experimental-features, optimization-research, settings-redesign
- v1.4.x acceptance notes: v1.4.0 to v1.4.7 (device, diagnostic, release, latency, performance, idle-memory-batches)
- memory2-baseline.md, memory2-handoff.md: memory 2 work

## Conventions
- A new update adds its specification here as vX.Y.Z-specification.md and lists it in this index.
- Diagnostics analyses (builds, per-mode) live in the Claude Project, not in this folder.
