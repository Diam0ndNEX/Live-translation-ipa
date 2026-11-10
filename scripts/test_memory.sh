#!/bin/bash
set -euo pipefail
swiftc -D MEMORY_FAULT_TESTING -parse-as-library Shared/*.swift $(bash scripts/swift_sources.sh TextIntelligence TranslationMemoryStore) Tests/MemoryStore/main.swift -o /tmp/screenlingo-memory-tests
/tmp/screenlingo-memory-tests
