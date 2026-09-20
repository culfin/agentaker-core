#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
MDT="$PWD/bin/mdt"
make_sandbox
trap 'rm -rf "$SANDBOX"' EXIT

echo "mdt: usage"
out=$("$MDT" 2>&1); check "no arguments exits 2" "2" "$?"
contains "no arguments prints usage" "Usage:" "$out"
contains "documents MDT_DRY_RUN — the only way a user discovers it otherwise" "MDT_DRY_RUN" "$out"
contains "documents MDT_YES — the only non-interactive route through init" "MDT_YES" "$out"
contains "documents MDT_NO_NETWORK" "MDT_NO_NETWORK" "$out"

echo "mdt: starting a role"
out=$("$MDT" demo developer 2>&1)
check "exits 0" "0" "$?"
check "creates the worktree" "yes" "$([ -d "$SANDBOX/demo/.worktrees/demo-developer" ] && echo yes || echo no)"
check "writes ROLE" "developer" "$(cat "$SANDBOX/demo/.worktrees/demo-developer/.agents/ROLE" 2>/dev/null)"

echo "mdt: the assembled context"
ctx="$SANDBOX/demo/.worktrees/demo-developer/.agents/context.md"
check "writes context.md" "yes" "$([ -f "$ctx" ] && echo yes || echo no)"
contains "context has the base rules" "Every role" "$(cat "$ctx")"
contains "context has the role" "Role: developer" "$(cat "$ctx")"
body=$(cat "$ctx")
check "base comes before role" "yes" \
  "$([ "$(grep -n 'Every role' "$ctx" | head -1 | cut -d: -f1)" -lt "$(grep -n 'Role: developer' "$ctx" | head -1 | cut -d: -f1)" ] && echo yes || echo no)"
lacks "context does not inline AGENTS.md" "Production boundary" "$body"

echo "mdt: nothing extra in the working tree"
check "git status is clean" "" "$(git -C "$SANDBOX/demo/.worktrees/demo-developer" status --porcelain)"

echo "mdt: launching"
out=$("$MDT" demo developer 2>&1)
contains "dry run names the tool" "claude" "$out"
contains "dry run passes the context file" "append-system-prompt-file" "$out"
contains "dry run uses tmux" "tmux" "$out"
out=$(MDT_TOOL=codex "$MDT" demo developer 2>&1)
contains "another tool is honoured" "codex" "$out"
out=$(MDT_TOOL=nonesuch "$MDT" demo developer 2>&1)
contains "unknown tool explains itself" "context.md" "$out"

echo "mdt: idempotence and instances"
"$MDT" demo developer >/dev/null 2>&1; check "re-run exits 0" "0" "$?"
"$MDT" demo developer a11y >/dev/null 2>&1
check "suffixed worktree exists" "yes" "$([ -d "$SANDBOX/demo/.worktrees/demo-developer-a11y" ] && echo yes || echo no)"
check "suffixed ROLE is still the role" "developer" "$(cat "$SANDBOX/demo/.worktrees/demo-developer-a11y/.agents/ROLE")"

echo "mdt: guards"
out=$("$MDT" nosuchrepo developer 2>&1); check "unknown repo exits 1" "1" "$?"
contains "unknown repo is explained" "not a git repository" "$out"
out=$("$MDT" demo nosuchrole 2>&1); check "unknown role exits 1" "1" "$?"
contains "unknown role is explained" "no role file" "$out"
out=$("$MDT" demo ../../etc/passwd 2>&1); check "path in role name exits 1" "1" "$?"
contains "rejected as a name, not as a missing file" "is not a role name" "$out"

echo "mdt: a failed write is not reported as success"
if [ "$(id -u)" -eq 0 ]; then
  echo "  skip (running as root — permissions do not apply)"
else
  mkdir -p "$SANDBOX/demo/.worktrees/demo-maintainer"
  chmod 555 "$SANDBOX/demo/.worktrees/demo-maintainer"
  out=$("$MDT" demo maintainer 2>&1); check "unwritable worktree exits 1" "1" "$?"
  lacks "does not claim to launch" "would launch" "$out"
  chmod 755 "$SANDBOX/demo/.worktrees/demo-maintainer"

  BADROLES=$(mktemp -d)
  cp "$PWD/roles/_base.md" "$BADROLES/"
  : > "$BADROLES/developer.md"
  out=$(MDT_ROLES_DIR="$BADROLES" "$MDT" demo developer 2>&1)
  check "empty role file exits 1" "1" "$?"
  lacks "does not claim to launch with an empty role" "would launch" "$out"
  rm -rf "$BADROLES"
fi

echo "mdt: legible tab titles"
out=$("$MDT" demo developer 2>&1)
contains "developer tags DEV" "demo · DEV" "$out"
out=$("$MDT" demo reviewer 2>&1)
contains "reviewer tags REV" "demo · REV" "$out"
out=$("$MDT" demo maintainer 2>&1)
contains "maintainer tags MNT" "demo · MNT" "$out"
out=$("$MDT" demo none 2>&1)
contains "none tags ---" "demo · ---" "$out"
out=$("$MDT" demo developer eyeoffice 2>&1)
contains "a suffix follows the tag with a middle dot, not the role name" "demo · DEV·eyeoffice" "$out"

TAGROLES=$(mktemp -d)
cp "$PWD/roles/_base.md" "$TAGROLES/"
printf '# Role: architect\n' > "$TAGROLES/architect.md"
out=$(MDT_ROLES_DIR="$TAGROLES" "$MDT" demo architect 2>&1)
contains "an unrecognised role abbreviates to its first three letters, uppercased" "demo · ARC" "$out"
rm -rf "$TAGROLES"

echo "mdt: .agents is never committed"
contains "exclude covers .agents" ".agents/" \
  "$(cat "$(git -C "$SANDBOX/demo/.worktrees/demo-developer" rev-parse --git-path info/exclude)")"

echo "mdt: works when installed as a symlink"
LINKDIR=$(mktemp -d)
ln -s "$PWD/bin/mdt" "$LINKDIR/mdt"
out=$("$LINKDIR/mdt" demo developer 2>&1)
check "exits 0 through a symlink" "0" "$?"
contains "found its roles" "would launch" "$out"
lacks "no missing-role error" "no role file" "$out"
rm -rf "$LINKDIR"

summary
