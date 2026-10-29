#!/bin/bash
set -euo pipefail
swiftc -parse-as-library Shared/TranslationSystem.swift Shared/TranslationActivity.swift App/DiagnosticArchive.swift Tests/DiagnosticArchive/main.swift -o /tmp/screenlingo-diagnostic-tests
/tmp/screenlingo-diagnostic-tests
