#!/bin/bash
# Test Runs storage tests (v2.0.0 build 84). Run from the repository root: the test reads App/Diagnostics.swift.
set -euo pipefail
swiftc -parse-as-library Shared/SharedTranslationWork.swift $(bash scripts/swift_sources.sh TranslationSystem) Shared/TranslationActivity.swift $(bash scripts/swift_sources.sh DiagnosticArchive TestRunStore) Tests/TestRuns/main.swift -o /tmp/screenlingo-testrun-tests
/tmp/screenlingo-testrun-tests
