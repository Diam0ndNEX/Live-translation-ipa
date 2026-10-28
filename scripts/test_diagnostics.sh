#!/bin/bash
set -euo pipefail
swiftc -parse-as-library App/DiagnosticArchive.swift Tests/DiagnosticArchive/main.swift -o /tmp/screenlingo-diagnostic-tests
/tmp/screenlingo-diagnostic-tests
