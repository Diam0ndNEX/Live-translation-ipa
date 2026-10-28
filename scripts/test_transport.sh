#!/bin/bash
set -euo pipefail
swiftc -parse-as-library Shared/*.swift App/LoopbackServer.swift Tests/Transport/main.swift -o /tmp/screenlingo-transport-tests
/tmp/screenlingo-transport-tests
