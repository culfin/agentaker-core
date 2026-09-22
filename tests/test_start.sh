#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
TENDER="$PWD/bin/tender"
make_sandbox
trap 'rm -rf "$SANDBOX"' EXIT

echo "tender: usage"
out=$("$TENDER" 2>&1); check "no arguments exits 2" "2" "$?"
contains "no arguments prints usage" "Usage:" "$out"
contains "documents TENDER_DRY_RUN — the only way a user discovers it otherwise" "TENDER_DRY_RUN" "$out"
contains "says a dry run still creates the worktree — it reads as side-effect free otherwise" "still created" "$out"
contains "documents TENDER_YES — the only non-interactive route through init" "TENDER_YES" "$out"
contains "documents TENDER_NO_NETWORK" "TENDER_NO_NETWORK" "$out"

echo "tender: starting a role"
out=$("$TENDER" demo developer 2>&1)
check "exits 0" "0" "$?"
check "creates the worktree" "yes" "$([ -d "$SANDBOX/demo/.worktrees/demo-developer" ] && echo yes || echo no)"
check "writes ROLE" "developer" "$(cat "$SANDBOX/demo/.worktrees/demo-developer/.agents/ROLE" 2>/dev/null)"

echo "tender: the assembled context"
ctx="$SANDBOX/demo/.worktrees/demo-developer/.agents/context.md"
check "writes context.md" "yes" "$([ -f "$ctx" ] && echo yes || echo no)"
contains "context has the base rules" "Every role" "$(cat "$ctx")"
contains "context has the role" "Role: developer" "$(cat "$ctx")"
body=$(cat "$ctx")
check "base comes before role" "yes" \
  "$([ "$(grep -n 'Every role' "$ctx" | head -1 | cut -d: -f1)" -lt "$(grep -n 'Role: developer' "$ctx" | head -1 | cut -d: -f1)" ] && echo yes || echo no)"
lacks "context does not inline AGENTS.md" "Production boundary" "$body"

echo "tender: nothing extra in the working tree"
check "git status is clean" "" "$(git -C "$SANDBOX/demo/.worktrees/demo-developer" status --porcelain)"

echo "tender: launching"
out=$("$TENDER" demo developer 2>&1)
contains "dry run names the tool" "claude" "$out"
contains "dry run passes the context file" "append-system-prompt-file" "$out"
contains "dry run uses tmux" "tmux" "$out"
out=$(TENDER_TOOL=codex "$TENDER" demo developer 2>&1)
contains "another tool is honoured" "codex" "$out"
contains "an unrun launch path says so at launch time" "has never been run" "$out"
out=$("$TENDER" demo developer 2>&1)
lacks "a verified path stays quiet about it" "has never been run" "$out"
out=$(TENDER_TOOL=nonesuch "$TENDER" demo developer 2>&1)
contains "unknown tool explains itself" "context.md" "$out"

echo "tender: idempotence and instances"
"$TENDER" demo developer >/dev/null 2>&1; check "re-run exits 0" "0" "$?"
"$TENDER" demo developer a11y >/dev/null 2>&1
check "suffixed worktree exists" "yes" "$([ -d "$SANDBOX/demo/.worktrees/demo-developer-a11y" ] && echo yes || echo no)"
check "suffixed ROLE is still the role" "developer" "$(cat "$SANDBOX/demo/.worktrees/demo-developer-a11y/.agents/ROLE")"

echo "tender: guards"
out=$("$TENDER" nosuchrepo developer 2>&1); check "unknown repo exits 1" "1" "$?"
contains "unknown repo is explained" "not a git repository" "$out"
out=$("$TENDER" demo nosuchrole 2>&1); check "unknown role exits 1" "1" "$?"
contains "unknown role is explained" "no role file" "$out"
out=$("$TENDER" demo ../../etc/passwd 2>&1); check "path in role name exits 1" "1" "$?"
contains "rejected as a name, not as a missing file" "is not a role name" "$out"

echo "tender: a failed write is not reported as success"
if [ "$(id -u)" -eq 0 ]; then
  echo "  skip (running as root — permissions do not apply)"
else
  mkdir -p "$SANDBOX/demo/.worktrees/demo-maintainer"
  chmod 555 "$SANDBOX/demo/.worktrees/demo-maintainer"
  out=$("$TENDER" demo maintainer 2>&1); check "unwritable worktree exits 1" "1" "$?"
  lacks "does not claim to launch" "would launch" "$out"
  chmod 755 "$SANDBOX/demo/.worktrees/demo-maintainer"

  BADROLES=$(mktemp -d)
  cp "$PWD/roles/_base.md" "$BADROLES/"
  : > "$BADROLES/developer.md"
  out=$(TENDER_ROLES_DIR="$BADROLES" "$TENDER" demo developer 2>&1)
  check "empty role file exits 1" "1" "$?"
  lacks "does not claim to launch with an empty role" "would launch" "$out"
  rm -rf "$BADROLES"
fi

echo "tender: legible tab titles"
out=$("$TENDER" demo developer 2>&1)
contains "developer tags DEV" "demo · DEV" "$out"
# A reviewer start asks the keychain whether a token exists — a stub keychain
# with none, never the real one.
NOKEY=$(mktemp -d); trap 'rm -rf "$SANDBOX" "$NOKEY"' EXIT
printf '#!/bin/sh\nexit 44\n' > "$NOKEY/security"; cp "$NOKEY/security" "$NOKEY/secret-tool"
chmod +x "$NOKEY/security" "$NOKEY/secret-tool"
out=$(PATH="$NOKEY:$PATH" "$TENDER" demo reviewer 2>&1)
contains "reviewer tags REV" "demo · REV" "$out"
out=$("$TENDER" demo maintainer 2>&1)
contains "maintainer tags MNT" "demo · MNT" "$out"
out=$("$TENDER" demo none 2>&1)
contains "none tags ---" "demo · ---" "$out"
out=$("$TENDER" demo developer eyeoffice 2>&1)
contains "a suffix follows the tag with a middle dot, not the role name" "demo · DEV·eyeoffice" "$out"

TAGROLES=$(mktemp -d)
cp "$PWD/roles/_base.md" "$TAGROLES/"
printf '# Role: architect\n' > "$TAGROLES/architect.md"
out=$(TENDER_ROLES_DIR="$TAGROLES" "$TENDER" demo architect 2>&1)
contains "an unrecognised role abbreviates to its first three letters, uppercased" "demo · ARC" "$out"
rm -rf "$TAGROLES"

echo "tender: .agents is never committed"
contains "exclude covers .agents" ".agents/" \
  "$(cat "$(git -C "$SANDBOX/demo/.worktrees/demo-developer" rev-parse --git-path info/exclude)")"

echo "tender: works when installed as a symlink"
LINKDIR=$(mktemp -d)
ln -s "$PWD/bin/tender" "$LINKDIR/tender"
out=$("$LINKDIR/tender" demo developer 2>&1)
check "exits 0 through a symlink" "0" "$?"
contains "found its roles" "would launch" "$out"
lacks "no missing-role error" "no role file" "$out"
rm -rf "$LINKDIR"

summary
