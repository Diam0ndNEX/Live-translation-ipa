#!/bin/bash
set -euo pipefail
# Manual macOS-only microbenchmark. This is NOT a substitute for on-device
# ScreenLingo latency, thermal, upgrade, or long-session acceptance tests.
swiftc -O -parse-as-library Shared/*.swift App/TextIntelligence.swift App/TranslationMemoryStore.swift Tests/MemoryStoreBenchmarks/main.swift -o /tmp/screenlingo-memory-benchmark
/tmp/screenlingo-memory-benchmark "$@"
