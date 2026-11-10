# ScreenLingo structure guidelines

Status: written 2026-11-10 for the 2.3.2 (build 109) code. Nothing here was compiled or run. Existing files are NOT moved by this document; it defines where NEW code, tests and docs go and how the big files shrink over time.

Why: `TranslatorEngine.swift` (~258 KB), `Diagnostics.swift` (~121 KB), `DiagnosticArchive.swift` (~105 KB), `TranslationMemoryStore.swift` (~81 KB) and `DiagnosticsDashboard.swift` (~77 KB) are too big to review or edit safely, and `App/` has ~27 loose files. Optimization work keeps going, so structure improves a little with every update instead of in one big stop.

## 1. What is possible now (no moves, no risk to tests)
- New code goes into new files in the target folders below. Xcode sources are `[App, Shared]` in `project.yml` and are picked up recursively, so a new folder under `App/` needs no project change.
- `Shared/` stays FLAT. `build.yml` compiles `Shared/*.swift` with a glob, so a subfolder there would silently drop files from those test builds.
- Existing files are not moved until a dedicated update moves them together with every path in `scripts/` and `.github/workflows/build.yml` (see section 6).
- `docs/` stays flat for now (see section 7). The index is `docs/README.md`.

## 2. Target layout for `App/`
```
App/
  Engine/        capture intake, OCR handling, Legacy drain and speculation,
                 confirmation, PiP enqueue, mode preparation, caption assembly
  Diagnostics/   recorder core, mode and pipeline events, run snapshots, archive/report sections, dashboard
  Memory/        translation memory store, writer, management view
  PiP/           PiP renderer, loopback transport
  TestRuns/      test run store and views
  Settings/      settings views, categories, customization
  UI/            already organized by screen (Kit, Model, Translate, Library, Languages, Fixtures)
```
This is the END state. Do not move old files just to match it.

## 3. Rules for new code
1. One concern per file, named for the concern (`LegacySpeculationAdmission.swift`, not `Helpers.swift`).
2. Target size: under about 400 lines; over about 800 lines needs a reason in the PR.
3. A new feature gets a new file in the right folder. It must not be appended to a file listed as "giant" above.
4. Pure logic with no UI or engine state goes in `Shared/` as a small policy file with a Swift test in `Tests/` (the existing pattern: `PixelConfirmation`, `HistoryPolicy`, `LanguageRouting`).
5. SwiftUI views go in `App/UI/<Screen>/` or `App/Settings/`, never next to engine code.
6. Engine code that must touch engine state goes into an `extension TranslatorEngine` in its own file under `App/Engine/`.

## 4. Extract-on-touch (how the giant files shrink)
When an update has to change code inside a giant file:
1. First commit, no behavior change: move the affected functions into a new file as an `extension`, text unchanged.
2. Update tests and CI paths for that move in the same commit.
3. Second commit: the actual change, in the new small file.
Both commits say what they are. A failed CI run is then traceable to one of them.

Swift note: `private` members are file-scoped, so an extension in another file cannot use them. Moving code can force `private` to become `fileprivate` or internal. That is a small code change; list it in the commit message.

## 5. Which files to split first (UNVERIFIED split points)
Split points are guesses from file names and sizes, not from reading the code. Confirm by reading before moving.
- `TranslatorEngine`: capture and OCR intake, Legacy drain and speculation, confirmation and PiP enqueue, mode preparation, core state.
- `Diagnostics`: recorder core, mode and pipeline events, run snapshots and export.
- `DiagnosticArchive`: one file per report/ZIP section.

## 6. Tests and CI
- Source-contract tests in `scripts/` read files by path (`read('App/TranslatorEngine.swift')`) and compare function text with older commits (`old('App/TranslatorEngine.swift')`, which runs `git show <commit>:<path>`). After a move, `read()` must use the new path while `old()` must keep the OLD commit's path.
- `build.yml` names files explicitly in `swiftc` commands and uses `Shared/*.swift`.
- Any update that moves a file lists every script and workflow line it changed.
- New contract tests read files through one place for paths, so a later move needs one edit. Do not copy-paste a path into many assertions.
- Do not add a new `test_vXYZ_contracts.py` per version if the check fits an existing topic test. A per-version file is only for checks that are specific to that release.
- CI green means it compiles and the tests pass. It is not proof of speed or correct subtitles.

## 7. Docs
- One specification per update: `docs/vX.Y.Z-specification.md`. State what was read, what was not, and what is unverified.
- Add every new doc to `docs/README.md` in the same commit.
- Diagnostics analyses (per build or mode) stay in the Claude Project, not in `docs/`, unless a spec needs the numbers; then quote them with their conditions.
- Do not move existing docs into subfolders until it is checked whether any script or doc links to their paths.

## 8. Checklist for every update
- [ ] Read the contract tests that mention the files you edit.
- [ ] New code is in a new file in the target folder; no giant file grew.
- [ ] If a giant file was touched: extraction commit first, then the change.
- [ ] Version, build and changelog bumped in `Shared/Shared.swift` and `project.yml` (3 places each) and every script that asserts the version.
- [ ] `docs/vX.Y.Z-specification.md` added and listed in `docs/README.md`.
- [ ] Commit messages say what changed. No speed claims without Diagnostics from all three modes.
- [ ] Say that nothing was compiled; the CI run is the first test.

## 9. Not decided
- Whether `App/` files get regrouped at all, or only the new code follows the layout.
- Whether per-version test scripts should be merged into topic tests.
- Whether `docs/` should get subfolders.
