# ScreenLingo structure guidelines

Status: rewritten for 2.3.9 (build 116), re-read against the code for 2.4.0 (build 117). Reviewed for: 2.4 (see section 9). The big files were split in 2.3.3 to 2.3.9 (see `docs/structure-migration-plan.md` for the log). Swift was never compiled in chat; the GitHub Actions run is the first test of any change. This file says where code, tests and docs go, and how to split safely.

## 1. Current state (2.4.0)
<!-- sizes:start -->
| Main file | Lines (rounded to 50) | Part files |
|---|---|---|
| App/TranslatorEngine.swift | 1350 | 20 |
| App/Diagnostics.swift | 700 | 8 |
| BroadcastExtension/SampleHandler.swift | 550 | 3 |
| App/DiagnosticArchive.swift | 450 | 7 |
| App/TranslationMemoryStore.swift | 400 | 9 |
| App/ModeTranslationService.swift | 400 | 2 |
| App/DiagnosticsDashboard.swift | 300 | 5 |
| App/SettingsViews.swift | 300 | 2 |
| App/TestRunViews.swift | 250 | 2 |
| Shared/TranslationSystem.swift | 250 | 3 |
<!-- sizes:end -->
Biggest remaining: TranslatorEngine (stored properties, `init`, test-pinned members) and `process` (391 lines, one function, left whole on purpose).

## 2. Layout
```
App/
  Engine/        TranslatorEngine+*, ModeTranslationService+*
  Diagnostics/   recorder, archive, dashboard parts
  Memory/        translation memory store parts
  TestRuns/      test run view parts
  Settings/      settings view parts
  UI/            organized by screen (Kit, Model, Translate, Library, Languages, Fixtures)
Shared/          FLAT (build.yml compiles Shared/*.swift by glob)
BroadcastExtension/  SampleHandler + parts
```
Main files stay where they are (`App/TranslatorEngine.swift` ...); only parts live in the folders. `project.yml` sources are recursive, so new folders need no project change.

## 3. Rules for new code
1. One concern per file, named for the concern. Target under about 400 lines; over about 800 needs a reason in the PR.
2. New features go in new files in the folders above, never appended to a main file that is already over 800 lines.
3. Split parts are named `Type+Topic.swift`, even when the part declares a different type. `scripts/sources.py` and `scripts/swift_sources.sh` find parts only by this name.
4. Pure logic with no UI or engine state goes in `Shared/` as a small policy file with a Swift test in `Tests/`.
5. SwiftUI views go in `App/UI/<Screen>/`, `App/Settings/` or the screen folder. UI files keep a unique name; the UI lints match on names and on `/UI/`.
6. Engine code that touches engine state goes in `extension TranslatorEngine` in its own file under `App/Engine/`.

## 4. How to split a file safely (learned in 2.3.3 to 2.3.9)
1. Move whole units: top-level types, or whole members of a class, actor or struct. Never cut inside a function. One concern per commit; text unchanged.
2. Stay in the main file: stored properties, `init`, `deinit`, `body`, members with `override`, and members that tests match by text or by position (section markers).
3. Imports: every new file gets the imports its code uses. A missing `import CryptoKit` broke the 2.3.5 build. Grep the block for the symbols of each import of the source file.
4. Access: `private` is file-scoped. Remove `private` only from members that another file of the same type uses. Then check that no internal method exposes a private type (2.3.5 and 2.3.7 each found one). Never make a member public.
5. Check with a line multiset (moved text plus parts equals the old file; only `private` removals, wrappers and imports differ).
6. Run all `scripts/test_*.py` and `make_settings_index.py --check`. Fix tests only so that their meaning stays (see section 5).
7. Bump the version (every update), write `docs/vX.Y.Z-specification.md`, list it in `docs/README.md`. One push per stage; a new push cancels the running CI.
8. Hot paths (`SampleHandler`, `TranslatorEngine`, `TranslationSystem`) are guarded by tests. `test_three_modes.py` compares `process`, `drain`, `cachedCaption`, `extractTexts` and `selectBlocks` with the text of commit e94542ce; the other hot-path checks look for required lines. Moving a function is allowed when the body stays identical. Since 2.4.0 the owner allows changing them: change the test in the same commit and say in the specification which assertion changed and why. 2.4.0 itself did not change those five functions.
9. Helper scripts for these checks are in `scripts/split_tools/` (see its README).

## 5. Tests and CI
- Python tests load Swift with `from sources import read_source` and `read_source("Name")` (main file plus all `Name+*.swift`). New tests must do the same. Never read `App/Name.swift` by path.
- `function()` in `test_three_modes.py` cuts a function at its own closing brace and ignores `private`; `old()` comparisons keep the OLD commit path.
- Test strings should name a member without the access keyword (`func show(`, not `private func show(`).
- Tests that slice source between two markers depend on member order in one file. Keep those members together in the main file.
- Shell scripts and `build.yml` build `swiftc` lists with `$(bash scripts/swift_sources.sh Name1 Name2)`, never with a file name. `Shared/*.swift` stays a glob. Workflow files cannot be pushed from chat; hand the file to the owner to paste.
- Do not add a `test_vXYZ_contracts.py` per version if the check fits an existing topic test. A new script also needs a new step in `build.yml`, which only the owner can paste; 2.4.0 put its checks at the end of `test_three_modes.py` for that reason.
- CI is two parallel jobs: `checks` (all tests) and `build` (xcodegen, xcodebuild, IPA). The IPA can exist while `checks` is red; read both.
- CI green means it compiles and the tests pass. It is not proof of speed or correct subtitles.

## 6. Docs
- One specification per update: `docs/vX.Y.Z-specification.md`. State what was read, what was not, what is unverified.
- Docs of older versions are records; do not edit them. Add every new doc to `docs/README.md` in the same commit.
- Diagnostics analyses of single test runs stay in the Claude Project, not in `docs/`. An audit written for an update (`docs/vX.Y.Z-audit.md`) is a doc and is listed in `docs/README.md`.

## 7. Branches and PRs
- Work on `claude/screenlingo-v<version>` from the newest `claude/screenlingo-v*` branch. Open a draft PR into the branch you started from, never `main`. Old `codex/*` branches are history.
- The chat session cannot delete branches or push workflow files.

## 8. Checklist for every update
- [ ] Read the contract tests that mention the files you edit.
- [ ] New code is in a new file in the right folder; no file over 800 lines grew.
- [ ] A split follows section 4 (imports, access, signature check, multiset, tests).
- [ ] Version, build and changelog (no inner quotes) in `Shared/Shared.swift`; 3 places each in `project.yml`; every script that asserts the version.
- [ ] `docs/vX.Y.Z-specification.md` added and listed in `docs/README.md`; `python3 scripts/test_structure_docs.py --write` run.
- [ ] Commit messages say what changed. No speed claims without Diagnostics from all three modes.
- [ ] A change that can alter wording or what is translated early has a switch (pinned at session start in `TranslationHotPathAB`), a line in the report's switches column, and a changelog sentence.
- [ ] Say that nothing was compiled in chat; the CI run is the first test.

## 9. Keeping this file current
`scripts/test_structure_docs.py` runs in CI and fails when:
- the size table in section 1 no longer matches the files (run `python3 scripts/test_structure_docs.py --write`; it only changes when a file moves by about 50 lines or a new part appears);
- "Reviewed for" is older than the app's major.minor version. At 2.4.0, 3.0.0 and so on, re-read the whole file against the code, fix what is outdated, update `Status:` and set `Reviewed for: X.Y`;
- a Swift file over 800 lines is not named in this file;
- the current version has no `docs/vX.Y.Z-specification.md` listed in `docs/README.md`.

## 10. Not decided
- Whether `process` (391 lines) and `handleContent` (229) should ever be broken into smaller functions. That is a code change, not a layout change, and needs Diagnostics data.
- Whether per-version test scripts should be merged into topic tests.
- Whether `docs/` should get subfolders (check first that no script links to the paths).
