#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
WTC="$PWD/bin/wtc"
make_sandbox
trap 'rm -rf "$SANDBOX"' EXIT

echo "wtc: usage"
out=$("$WTC" 2>&1); check "no arguments exits 2" "2" "$?"
contains "no arguments prints usage" "Usage:" "$out"

echo "wtc: starting a role"
out=$("$WTC" demo developer 2>&1)
check "exits 0" "0" "$?"
check "creates the worktree" "yes" "$([ -d "$SANDBOX/demo/.worktrees/demo-developer" ] && echo yes || echo no)"
check "writes ROLE" "developer" "$(cat "$SANDBOX/demo/.worktrees/demo-developer/.agents/ROLE" 2>/dev/null)"

echo "wtc: the assembled context"
ctx="$SANDBOX/demo/.worktrees/demo-developer/.agents/context.md"
check "writes context.md" "yes" "$([ -f "$ctx" ] && echo yes || echo no)"
contains "context has the base rules" "Every role" "$(cat "$ctx")"
contains "context has the role" "Role: developer" "$(cat "$ctx")"
body=$(cat "$ctx")
check "base comes before role" "yes" \
  "$([ "$(grep -n 'Every role' "$ctx" | head -1 | cut -d: -f1)" -lt "$(grep -n 'Role: developer' "$ctx" | head -1 | cut -d: -f1)" ] && echo yes || echo no)"
lacks "context does not inline AGENTS.md" "Production boundary" "$body"

echo "wtc: nothing extra in the working tree"
check "git status is clean" "" "$(git -C "$SANDBOX/demo/.worktrees/demo-developer" status --porcelain)"

echo "wtc: launching"
out=$("$WTC" demo developer 2>&1)
contains "dry run names the tool" "claude" "$out"
contains "dry run passes the context file" "append-system-prompt-file" "$out"
contains "dry run uses tmux" "tmux" "$out"
out=$(WTC_TOOL=codex "$WTC" demo developer 2>&1)
contains "another tool is honoured" "codex" "$out"
out=$(WTC_TOOL=nonesuch "$WTC" demo developer 2>&1)
contains "unknown tool explains itself" "context.md" "$out"

echo "wtc: idempotence and instances"
"$WTC" demo developer >/dev/null 2>&1; check "re-run exits 0" "0" "$?"
"$WTC" demo developer a11y >/dev/null 2>&1
check "suffixed worktree exists" "yes" "$([ -d "$SANDBOX/demo/.worktrees/demo-developer-a11y" ] && echo yes || echo no)"
check "suffixed ROLE is still the role" "developer" "$(cat "$SANDBOX/demo/.worktrees/demo-developer-a11y/.agents/ROLE")"

echo "wtc: guards"
out=$("$WTC" nosuchrepo developer 2>&1); check "unknown repo exits 1" "1" "$?"
contains "unknown repo is explained" "not a git repository" "$out"
out=$("$WTC" demo nosuchrole 2>&1); check "unknown role exits 1" "1" "$?"
contains "unknown role is explained" "no role file" "$out"
out=$("$WTC" demo ../../etc/passwd 2>&1); check "path in role name exits 1" "1" "$?"
contains "rejected as a name, not as a missing file" "is not a role name" "$out"

echo "wtc: a failed write is not reported as success"
if [ "$(id -u)" -eq 0 ]; then
  echo "  skip (running as root — permissions do not apply)"
else
  mkdir -p "$SANDBOX/demo/.worktrees/demo-integrator"
  chmod 555 "$SANDBOX/demo/.worktrees/demo-integrator"
  out=$("$WTC" demo integrator 2>&1); check "unwritable worktree exits 1" "1" "$?"
  lacks "does not claim to launch" "would launch" "$out"
  chmod 755 "$SANDBOX/demo/.worktrees/demo-integrator"

  BADROLES=$(mktemp -d)
  cp "$PWD/roles/_base.md" "$BADROLES/"
  : > "$BADROLES/developer.md"
  out=$(WTC_ROLES_DIR="$BADROLES" "$WTC" demo developer 2>&1)
  check "empty role file exits 1" "1" "$?"
  lacks "does not claim to launch with an empty role" "would launch" "$out"
  rm -rf "$BADROLES"
fi

echo "wtc: .agents is never committed"
contains "exclude covers .agents" ".agents/" \
  "$(cat "$(git -C "$SANDBOX/demo/.worktrees/demo-developer" rev-parse --git-path info/exclude)")"

echo "wtc: works when installed as a symlink"
LINKDIR=$(mktemp -d)
ln -s "$PWD/bin/wtc" "$LINKDIR/wtc"
out=$("$LINKDIR/wtc" demo developer 2>&1)
check "exits 0 through a symlink" "0" "$?"
contains "found its roles" "would launch" "$out"
lacks "no missing-role error" "no role file" "$out"
rm -rf "$LINKDIR"

summary
