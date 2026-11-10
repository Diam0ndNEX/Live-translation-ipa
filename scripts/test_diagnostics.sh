#!/bin/bash
set -euo pipefail
swiftc -parse-as-library Shared/SharedTranslationWork.swift Shared/TranslationSystem.swift Shared/TranslationActivity.swift $(bash scripts/swift_sources.sh DiagnosticArchive) Tests/DiagnosticArchive/main.swift -o /tmp/screenlingo-diagnostic-tests
/tmp/screenlingo-diagnostic-tests
