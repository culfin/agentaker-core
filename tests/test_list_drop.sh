#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
WTC="$PWD/bin/wtc"
make_sandbox
trap 'tmux kill-session -t wtc-demo >/dev/null 2>&1; rm -rf "$SANDBOX"' EXIT

# A second repo, so `wtc list` (no argument) has more than one heading to
# get right, and `wtc list demo` has something to prove it excluded.
git init -q -b main "$SANDBOX/other"
git -C "$SANDBOX/other" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init

# A bare remote for demo, with main already on it — log --branches --not
# --remotes (exactly what cmd_drop runs) looks across every local branch, not
# just the one worktree's, so leaving main unpushed would count its commit
# too and throw off "exactly one" below.
git init -q --bare "$SANDBOX/demo-remote.git"
git -C "$SANDBOX/demo" remote add origin "$SANDBOX/demo-remote.git"
git -C "$SANDBOX/demo" push -q origin main

echo "wtc list: nothing yet"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" list 2>&1)
contains "says so when a repo has no worktrees" "no worktrees under" "$out"

echo "wtc list: shows what exists"
"$WTC" demo developer >/dev/null 2>&1
"$WTC" demo developer eyeoffice >/dev/null 2>&1
"$WTC" other developer >/dev/null 2>&1
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" list 2>&1)
# An exact-line match, not `contains`: "demo" is also a substring of every
# branch name printed below it ("demo-developer"), which would pass even if
# the heading itself were never printed.
check "lists the demo heading" "yes" "$(printf '%s\n' "$out" | grep -qxF demo && echo yes || echo no)"
contains "lists the other heading" "other" "$out"
# "  DEV " and not bare "DEV": the suffixed row below also contains "DEV" as
# a substring ("DEV·eyeoffice"), which would let this pass vacuously even if
# the plain row's own label broke.
contains "tags the plain developer worktree DEV" "  DEV " "$out"
contains "tags the suffixed one with its name" "DEV·eyeoffice" "$out"
contains "shows the branch wtc created" "demo-developer-eyeoffice" "$out"
contains "sizes are off by default — du is slow on a large tree" "sizes omitted" "$out"
lacks "an idle worktree is not claimed to be running" "running" "$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" list demo 2>&1)"

echo "wtc list: a repo argument filters to it"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" list demo 2>&1)
contains "shows the requested repo" "demo" "$out"
lacks "excludes the other repo" "other" "$out"

echo "wtc list: --size actually measures"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" list demo --size 2>&1)
lacks "no longer says sizes are omitted" "sizes omitted" "$out"
contains "prints a real du size, not a placeholder" "K" "$out"

echo "wtc list: an unknown repo is explained, not silently empty"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" list nosuchrepo 2>&1)
check "exits 1" "1" "$?"
contains "says it's not a git repository" "not a git repository" "$out"

echo "wtc drop: refuses on uncommitted changes, and says how many"
echo one > "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice/a.txt"
echo two > "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice/b.txt"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" drop demo DEV·eyeoffice 2>&1)
check "exits 1" "1" "$?"
contains "counts the uncommitted files" "2 uncommitted file(s)" "$out"
lacks "does not remove the worktree" "removed" "$out"
check "the worktree is still there" "yes" \
  "$([ -d "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice" ] && echo yes || echo no)"
rm -f "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice/a.txt" "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice/b.txt"

echo "wtc drop: refuses on commits with no remote, and names the branch"
git -C "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice" -c user.email=t@e -c user.name=t \
  commit -q --allow-empty -m "not pushed anywhere"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" drop demo DEV·eyeoffice 2>&1)
check "exits 1" "1" "$?"
contains "counts the unpushed commit" "1 commit(s)" "$out"
# The exact phrase, not bare "demo-developer-eyeoffice": that substring is
# also part of the worktree's own path, which a success message (from a
# broken check that let the drop through) would print too.
contains "names the branch" "on demo-developer-eyeoffice not on any remote" "$out"
git -C "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice" push -q origin demo-developer-eyeoffice:demo-developer-eyeoffice

echo "wtc drop: refuses on an open tmux window, and names the session"
tmux new-session -d -s wtc-demo -n "DEV·eyeoffice" sleep 60
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" drop demo DEV·eyeoffice 2>&1)
check "exits 1" "1" "$?"
contains "names the session to close" "wtc-demo" "$out"
contains "says to close it first" "close it first" "$out"

echo "wtc drop: --force overrides all three at once"
echo dirty >> "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice/a.txt"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" drop demo DEV·eyeoffice --force 2>&1)
check "exits 0" "0" "$?"
contains "confirms the removal" "removed" "$out"
check "the worktree is actually gone" "no" \
  "$([ -d "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice" ] && echo yes || echo no)"
check "git no longer lists it either" "" \
  "$(git -C "$SANDBOX/demo" worktree list | grep demo-developer-eyeoffice)"
out=$(tmux list-windows -t wtc-demo 2>&1)
lacks "the tmux window is closed too" "DEV·eyeoffice" "$out"

echo "wtc drop: a clean, pushed, closed worktree needs no --force"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" drop demo DEV 2>&1)
check "exits 0" "0" "$?"
contains "confirms the removal" "removed" "$out"
check "the worktree is actually gone, not just claimed to be" "no" \
  "$([ -d "$SANDBOX/demo/.worktrees/demo-developer" ] && echo yes || echo no)"

echo "wtc drop: an unknown label is explained, not confused with a missing repo"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" drop other NOSUCH 2>&1)
check "exits 1" "1" "$?"
contains "says the label wasn't found" "no worktree named" "$out"

echo "wtc drop: missing arguments print usage"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" drop demo 2>&1)
check "exits 2" "2" "$?"
contains "prints usage" "Usage:" "$out"

summary
