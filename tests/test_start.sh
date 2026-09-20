#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
WTR="$PWD/bin/wtr"
make_sandbox
trap 'rm -rf "$SANDBOX"' EXIT

echo "wtr: usage"
out=$("$WTR" 2>&1); check "no arguments exits 2" "2" "$?"
contains "no arguments prints usage" "Usage:" "$out"

echo "wtr: starting a role"
out=$("$WTR" demo developer 2>&1)
check "exits 0" "0" "$?"
check "creates the worktree" "yes" "$([ -d "$SANDBOX/demo/.worktrees/demo-developer" ] && echo yes || echo no)"
check "writes ROLE" "developer" "$(cat "$SANDBOX/demo/.worktrees/demo-developer/.agents/ROLE" 2>/dev/null)"

echo "wtr: the assembled context"
ctx="$SANDBOX/demo/.worktrees/demo-developer/.agents/context.md"
check "writes context.md" "yes" "$([ -f "$ctx" ] && echo yes || echo no)"
contains "context has the base rules" "Every role" "$(cat "$ctx")"
contains "context has the role" "Role: developer" "$(cat "$ctx")"
body=$(cat "$ctx")
check "base comes before role" "yes" \
  "$([ "$(grep -n 'Every role' "$ctx" | head -1 | cut -d: -f1)" -lt "$(grep -n 'Role: developer' "$ctx" | head -1 | cut -d: -f1)" ] && echo yes || echo no)"
lacks "context does not inline AGENTS.md" "Production boundary" "$body"

echo "wtr: nothing extra in the working tree"
check "git status is clean" "" "$(git -C "$SANDBOX/demo/.worktrees/demo-developer" status --porcelain)"

echo "wtr: launching"
out=$("$WTR" demo developer 2>&1)
contains "dry run names the tool" "claude" "$out"
contains "dry run passes the context file" "append-system-prompt-file" "$out"
contains "dry run uses tmux" "tmux" "$out"
out=$(WTR_TOOL=codex "$WTR" demo developer 2>&1)
contains "another tool is honoured" "codex" "$out"
out=$(WTR_TOOL=nonesuch "$WTR" demo developer 2>&1)
contains "unknown tool explains itself" "context.md" "$out"

echo "wtr: idempotence and instances"
"$WTR" demo developer >/dev/null 2>&1; check "re-run exits 0" "0" "$?"
"$WTR" demo developer a11y >/dev/null 2>&1
check "suffixed worktree exists" "yes" "$([ -d "$SANDBOX/demo/.worktrees/demo-developer-a11y" ] && echo yes || echo no)"
check "suffixed ROLE is still the role" "developer" "$(cat "$SANDBOX/demo/.worktrees/demo-developer-a11y/.agents/ROLE")"

echo "wtr: guards"
out=$("$WTR" nosuchrepo developer 2>&1); check "unknown repo exits 1" "1" "$?"
contains "unknown repo is explained" "not a git repository" "$out"
out=$("$WTR" demo nosuchrole 2>&1); check "unknown role exits 1" "1" "$?"
contains "unknown role is explained" "no role file" "$out"
out=$("$WTR" demo ../../etc/passwd 2>&1); check "path in role name exits 1" "1" "$?"

echo "wtr: .agents is never committed"
contains "exclude covers .agents" ".agents/" \
  "$(cat "$(git -C "$SANDBOX/demo/.worktrees/demo-developer" rev-parse --git-path info/exclude)")"

summary
