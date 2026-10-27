# Universal Translation Memory 2.0 implementation baseline

Baseline: `6bd542bfb2fd9cad915db9d56b592c8174a09e3a`, development branch `codex/screenlingo-v1.3.0`, app 1.3.0 (43).

Verified baseline: GitHub Actions run 40536974176, job 122304734836, passed existing regression tests, unsigned iOS app/extension build, metadata validation and IPA packaging. Xcode 26.6.0 / iPhoneOS26.5 SDK, iOS18 deployment, Swift 5 mode. No open PRs/issues at audit.

## Existing behavior to preserve

Versioned JSON envelope, rule fingerprints, confirmed/private retention gate, candidate lifetime checks, speculative/session/saved-hit attribution, bounded candidate traces, recorder timing, latency charts and TXT/CSV exports, and in-app simulator already exist. History, settings, OCR modes, stability settings, rotation, PiP, and offline translation remain in scope for regression verification.

## Confirmed storage defects and gaps

- Startup synchronously reads and loads the full JSON envelope on the main actor.
- RAM cache trimming removes confirmed entries from the next whole-file persistence snapshot.
- Retranslate clears the cache and marks it dirty, also permitting saved entries to disappear.
- v1.2.1 unversioned memory is not imported.
- Memory count measures RAM entries, not durable committed entries.
- New feature branches have no CI trigger; this batch adds PR coverage.

## Ordered integration

1. Baseline/CI coverage (this PR).
2. System SQLite storage, indexes, transactional writes, legacy preservation and migration tests.
3. Bounded RAM lookup, live integration, generation checks, durable write status and memory management.
4. Extend existing diagnostics, structured privacy-safe exports, persistent sessions and memory simulation.
5. Integrated regression/build checks, scaling measurements, recovery verification and release review.

System SQLite avoids an additional dependency and uses platform-supported transactions. All disk work must run off the main actor. Persistent retention is independent of RAM eviction. Unknown legacy metadata must remain unknown; no unsafe inferred compatibility. Schema, normalization, segmentation, key and translation versions are independent of app version. Preserve legacy files and failed databases; fallback to fresh translation must never delete them.

## Evidence limits and release gates

The Linux workspace has no Swift compiler, Xcode, iOS simulator or connected iPhone. macOS CI supplies compilation and IPA evidence. CI timing is not device translation performance. Same-device controlled baseline/updated workloads, thermal and long-session checks, and in-place installed-IPA upgrades are mandatory outstanding release gates. Do not call the system release-ready until these have been observed. Each implementation PR records its own exact commit and fresh CI result.
