#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
LINT="$PWD/bin/wtr-lint"

echo "lint: this repository"
out=$("$LINT" . 2>&1); check "repository is consistent" "0" "$?"

echo "lint: a broken example is caught"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/roles" "$TMP/agents" "$TMP/examples" "$TMP/bin"
touch "$TMP/roles/_base.md" "$TMP/roles/developer.md"
printf 'x\n' > "$TMP/agents/real-agent.md"

printf 'trunk: main\n\n## Roles\narchitect\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "unknown role fails" "1" "$?"
contains "names the unknown role" "architect" "$out"

printf '## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "missing trunk fails" "1" "$?"
contains "says trunk" "trunk" "$out"

printf 'trunk: main\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "missing boundary fails" "1" "$?"
contains "says production boundary" "roduction boundary" "$out"

printf 'trunk: main\n\n## Subagents\nghost-agent\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "unknown subagent fails" "1" "$?"
contains "names the unknown subagent" "ghost-agent" "$out"

echo "lint: vendor names in roles are caught"
printf 'trunk: main\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
printf 'Use Claude for this.\n' > "$TMP/roles/developer.md"
out=$("$LINT" "$TMP" 2>&1); check "vendor name in a role fails" "1" "$?"
contains "names the offending file" "developer.md" "$out"

echo "lint: reviewer field is required"
printf 'trunk: main\n\n## Test commands\nx\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "missing reviewer fails" "1" "$?"
contains "says reviewer" "reviewer:" "$out"

echo "lint: a heading without a space is caught, not silently skipped"
printf 'trunk: main\nreviewer: example-reviewer\n\n## Test commands\nx\n\n##Roles\narchitect\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "malformed heading fails" "1" "$?"
contains "names the malformed heading" "space after ##" "$out"

# Same content with the heading repaired: now the unknown role itself must be the
# complaint — proving the section really was being skipped before.
printf 'trunk: main\nreviewer: example-reviewer\n\n## Test commands\nx\n\n## Roles\narchitect\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "repaired heading exposes the bad role" "1" "$?"
contains "names the unknown role" "architect" "$out"

summary
