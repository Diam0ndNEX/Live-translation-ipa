# Memory 2.0 checkpoint — 2026-10-28

Status: INCOMPLETE DEVELOPMENT CHECKPOINT. Do not merge or install as a release.

## Verified baseline and completed batch
- Repository Diam0ndNEX/Live-translation-ipa; never edit main directly.
- Original development baseline: 6bd542bfb2fd9cad915db9d56b592c8174a09e3a, codex/screenlingo-v1.3.0, app 1.3.0 build 43.
- Baseline/CI PR #1: https://github.com/Diam0ndNEX/Live-translation-ipa/pull/1
- Published baseline/CI commit: 3afb6f54b1055dc8eecf5cedf62b81173c42dcae.
- Fresh IPA workflow 40548853242 passed. Original baseline workflow 40536974176 also passed. Neither proves device performance or installation migration.

## Work in progress saved with this checkpoint
- App/TranslationMemoryStore.swift: SQLite actor, schema/indexes, exact-key lookup deadline, transactional additive saves, legacy preservation/import, conflict records, management and diagnostic-session APIs. NOT integrated into TranslatorEngine and NOT compiled/tested yet.
- App/DiagnosticArchive.swift and Diagnostics.swift: structured event/session models, memory diagnostic UI and export work. Integration incomplete; review before use.
- SettingsViews.swift and MemoryManagementView.swift (if present): management navigation and independent history deletion; requires engine APIs below. Any missing referenced type is unfinished work, not a passing build.
- Existing live engine is unchanged: JSON memory and destructive RAM/snapshot coupling still apply until integration is completed.

## Exact next step
Finish and run the standalone SQLite migration/storage test harness on macOS CI BEFORE activating SQLite in the live translator. Inspect current checkpoint files and git status first; do not recreate completed code. Keep this draft checkpoint separate from release PRs. Split tested storage into its own PR based on the verified baseline/CI branch.

## Engine integration contract still to implement
Expose memoryStore: TranslationMemoryStore, published optional memoryHealth: MemoryStoreHealth, memoryPendingWrites: Int and memoryFailure: String?. Add async refreshMemoryHealth(), clearRAMCache(), async throwing removeMemoryEntries(ids:[Int64]), and make clearMemory report success only after commit. Coordinate revisions and clear barriers so pending writes cannot resurrect deleted records.
Use prepare(legacyURLs:) off main, retain both historical originals, activate only after verification. Replace whole-file snapshots with bounded additive confirmed-write batches; never persist speculation. Keep pending/failed status until commit. Use bounded RAM LRU (3000 default), indexed store lookup, generation checks after suspension, and fresh fallback on timeout/failure. Retranslate must bypass reuse without erasing durable memory. Never infer missing legacy rule metadata. Connect Diagnostics.memoryStore and memory health/outcome metrics using actual API definitions in source.

## Unfinished work
Storage migration tests/fixtures, interruption/corruption/low-storage tests; CI test wiring and SQLite linkage; engine integration and RAM cache; classification/segmentation policy and tests; management integration; simulator scenarios; structured export privacy tests; persistent diagnostic session integration; performance/scaling benchmarks at 3k/25k/100k/500k; end-to-end tracing audit and counter attribution; independent integrated review and IPA build. P2 fuzzy matching/cloud backups are deferred.

## Tests and failures
- PASS: baseline/CI PR IPA workflow 40548853242.
- New implementation tests: NOT RUN. No known failing test execution is recorded because the implementation has not been compiled. Missing engine APIs are known compile/integration blockers.
- Local environment lacks Swift and Xcode. Use GitHub macOS workflow; preserve existing regression tests.
- Command-line git push failed due to missing HTTPS credentials; authenticated GitHub connector works for commits/branches/PRs.
- Workspace was briefly unavailable, then restored. Verify files before resuming.
- Real-device performance, thermal/long-session behavior and in-place installed-IPA upgrade tests: UNVERIFIED and mandatory release gates.

## Resume protocol
Read this document and docs/memory2-baseline.md; fetch current development and checkpoint heads; inspect open PR/check status and uncommitted work; preserve all work; complete storage tests then integrate in dependency order. Record exact SHAs and fresh results. Before stopping, save changes to a feature branch and update this handoff with remaining tasks, failures and the next concrete step. Do not claim the master specification is complete from this checkpoint.

## Subsequent integration progress
Live TranslatorEngine now uses asynchronous SQLite preparation/lookup, additive pending confirmed writes, committed counts and RAM LRU trimming. MemoryManagementView has bounded search, status, integrity verification, RAM clearing and explicit permanent-clear confirmation. A standalone migration harness and CI step were added. These are implementation changes, not verified release evidence. Initial WIP checkpoint run 40611113777 failed before these missing pieces were added; integrated run 40611465886 is in progress. Next inspect its first failing step, correct compilation/runtime defects and rerun. Outstanding: expanded failure-path tests, background queue/clear races, memory pressure adaptation, segmentation/classification, simulator scenarios, exports/import UI, complete diagnostics wiring and all device release gates.

## Latest continuation
- Initial integrated implementation de14d5d79a402e9f420bba3031b3c2af5dd8d61e passed full IPA workflow 40611465886 (existing regressions, initial storage migration tests, iOS build, metadata, packaging/upload).
- PR #2 now contains ba9b06706e1ee3a42a6594a6be6084186c9b36a7: extended opaque legacy/conflict/export roundtrip tests, revision-fenced write acknowledgements, RAM timing and fresh confirmation promotion. Run 40611821319 in progress when recorded.
- PR #3 (codex/memory2-simulator), 8d71d9077cbcceb1a2583ec8d6ff0d009d5d6b38: memory scenarios and deadline assumptions, regression tests; run 40611880568 in progress when recorded.
- Memory management transfer controls added next: async export, security-scoped bounded import and explicit text disclosure; compilation pending.
- Exact next step: inspect the newest CI runs for PRs #2/#3 and transfer UI, fix any failures, then add interruption/corruption/concurrency regression coverage and independent review. Do not merge the draft stack until its own prerequisites pass. Device benchmarks and installed-IPA migration remain mandatory unverified release gates.


## Continuation audit — 2026-10-28 (Revision 3.0)
- Compared reference codex/screenlingo-v1.3.0 against codex/memory2-management-transfer: baseline TranslatorEngine/Diagnostics/PipelineSimulation exist; memory2 branch adds SQLite store, memory management UI and simulation changes. Do not duplicate these.
- Confirmed PR #2 run 40611821319 and PR #3 run 40611880568 succeeded at their respective SHAs. These are NOT verification of the combined PR #4 head.
- 390e35d9f4a0f03fef5f1bdcf248495beacfc1ea: export now rejects output larger than the supported 256 MiB import ceiling.
- cabeda81143b6a933f0496e62b8bec284fbfbd72: clearMemory now refuses deletion while confirmed writes are pending and reports success only after the SQLite clear returns.
- Latest commit had no associated PR-triggered workflow run at inspection. Build and tests for these changes are UNVERIFIED.
- Remaining high-priority review: verify asynchronous clear/write interleavings and failed-clear cache behavior; exercise migration interruptions, corruption, low-storage, and selected-entry deletion concurrency; verify combined IPA CI and device in-place upgrade.
- Exact next step: trigger/check the combined branch's IPA CI, fix any failures, then add deterministic concurrent write/clear tests. Do not merge into main or claim release readiness without device validation.
