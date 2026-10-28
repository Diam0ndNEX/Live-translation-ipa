#!/bin/bash
set -euo pipefail
swiftc -D MEMORY_FAULT_TESTING -parse-as-library Shared/*.swift App/TextIntelligence.swift App/TranslationMemoryStore.swift Tests/MemoryStore/main.swift -o /tmp/screenlingo-memory-tests
/tmp/screenlingo-memory-tests
