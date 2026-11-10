#!/bin/bash
set -euo pipefail
swiftc -parse-as-library Shared/*.swift $(bash scripts/swift_sources.sh LoopbackServer) Tests/Transport/main.swift -o /tmp/screenlingo-transport-tests
/tmp/screenlingo-transport-tests
