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

echo "hook and wtc assemble the same text"
# The hook duplicates bin/wtc's assembly on purpose — wtc has no side-effect-free
# "print the context" mode, and coupling a must-never-fail hook to a tool that
# creates worktrees would be the worse trade. This test is what keeps the
# duplication honest: if either side changes, it fails here rather than handing a
# user a different role depending on how they started their session.
make_sandbox
WT="$SANDBOX/demo/.worktrees/demo-developer"
"$PWD/bin/wtc" demo developer >/dev/null 2>&1
wtc_text=$(cat "$WT/.agents/context.md")
hook_text=$(CLAUDE_PROJECT_DIR="$WT" bash "$HOOK")
check "hook output matches wtc's context.md" "$wtc_text" "$hook_text"
rm -rf "$SANDBOX"

echo "hook: an unreadable role file stays quiet"
echo developer > "$TMP/.agents/ROLE"
if [ "$(id -u)" -eq 0 ]; then
  echo "  skip (running as root — permissions do not apply)"
else
  BADROLES=$(mktemp -d)
  cp "$PWD/roles/_base.md" "$BADROLES/"
  cp "$PWD/roles/developer.md" "$BADROLES/developer.md"
  chmod 000 "$BADROLES/developer.md"
  out=$(CLAUDE_PROJECT_DIR="$TMP" WTC_ROLES_DIR="$BADROLES" bash "$HOOK" 2>&1)
  check "still exits 0" "0" "$?"
  lacks "no permission error in the output" "Permission denied" "$out"
  chmod 644 "$BADROLES/developer.md"; rm -rf "$BADROLES"
fi

summary
