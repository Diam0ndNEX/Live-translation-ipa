#!/bin/bash
# Print the path of each named Swift source, wherever it lives under App/, Shared/ or BroadcastExtension/,
# plus any split parts named <Name>+<Topic>.swift. Use it in swiftc lists instead of hardcoded App/ paths:
#   swiftc ... $(bash scripts/swift_sources.sh TextIntelligence TranslationMemoryStore) ...
# Run from the repository root. Fails if a name is missing or if the same file name exists twice.
set -euo pipefail
for name in "$@"; do
  main=$(find App Shared BroadcastExtension -type f -name "$name.swift" | sort)
  if [ -z "$main" ]; then echo "swift_sources: no $name.swift found" >&2; exit 1; fi
  if [ "$(echo "$main" | wc -l)" -ne 1 ]; then echo "swift_sources: more than one $name.swift: $main" >&2; exit 1; fi
  echo "$main"
  find App Shared BroadcastExtension -type f -name "$name+*.swift" | sort
done
