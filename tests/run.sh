#!/usr/bin/env bash
# Runs every test file and fails if any of them does.
set -uo pipefail
cd "$(dirname "$0")/.."
rc=0
for t in tests/test_*.sh; do
  printf '\n=== %s ===\n' "$t"
  bash "$t" || rc=1
done
exit "$rc"
