#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
HOOK="$PWD/hooks/load_role.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "hook: silent when this is not an agent worktree"
out=$(CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>&1)
check "prints nothing" "" "$out"
check "exits 0" "0" "$?"

echo "hook: emits base and role"
mkdir -p "$TMP/.agents" && echo developer > "$TMP/.agents/ROLE"
out=$(CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>&1)
contains "has the base rules" "Every role" "$out"
contains "has the role" "Role: developer" "$out"

echo "hook: an unknown role warns instead of failing"
echo architect > "$TMP/.agents/ROLE"
out=$(CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>&1)
check "still exits 0" "0" "$?"
contains "warns" "no role file" "$out"
lacks "does not emit base rules" "Every role" "$out"

echo "hook: a path in ROLE is refused"
echo "../../etc/passwd" > "$TMP/.agents/ROLE"
out=$(CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>&1)
check "exits 0" "0" "$?"
lacks "emits nothing useful to an attacker" "root:" "$out"

summary
