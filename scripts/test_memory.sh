#!/bin/bash
set -euo pipefail
swiftc -parse-as-library Shared/*.swift App/TextIntelligence.swift App/TranslationMemoryStore.swift Tests/MemoryStore/main.swift -o /tmp/screenlingo-memory-tests
/tmp/screenlingo-memory-tests
