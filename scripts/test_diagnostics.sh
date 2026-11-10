#!/bin/bash
set -euo pipefail
swiftc -parse-as-library Shared/SharedTranslationWork.swift $(bash scripts/swift_sources.sh TranslationSystem) Shared/TranslationActivity.swift $(bash scripts/swift_sources.sh DiagnosticArchive) Tests/DiagnosticArchive/main.swift -o /tmp/screenlingo-diagnostic-tests
/tmp/screenlingo-diagnostic-tests
