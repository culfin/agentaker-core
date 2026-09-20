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
# A worktree whose directory name and branch differ, built directly like the
# drop-ambiguity fixtures below: wtc's own worktrees always name the branch
# after the directory, which would let a dirname-column check pass even if
# the column were actually just repeating the branch column.
git -C "$SANDBOX/demo" worktree add "$SANDBOX/demo/.worktrees/demo-mismatch" -b totally-different-branch >/dev/null 2>&1
mkdir -p "$SANDBOX/demo/.worktrees/demo-mismatch/.agents"
printf 'developer\n' > "$SANDBOX/demo/.worktrees/demo-mismatch/.agents/ROLE"
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
# The directory name, not just the branch: two rows can share a label (see
# the drop-ambiguity tests below), and the directory name is the only column
# that always tells them apart — a reader has to be able to build a `drop`
# command from what's on screen. Checked on the mismatch fixture, where the
# directory name and branch are genuinely different strings — on wtc's own
# worktrees they're identical, so a check there couldn't tell "shows the
# directory name" from "shows the branch again."
contains "shows a directory name that differs from its branch" "demo-mismatch" "$out"
contains "... alongside that actual branch name" "totally-different-branch" "$out"
contains "shows the branch wtc created" "demo-developer-eyeoffice" "$out"
# Done with it — it was only here to prove the dirname column isn't just the
# branch column twice, and its DEV label would otherwise collide with
# demo-developer for every `drop` test below (a real collision, correctly
# refused, but not what those tests are checking).
git -C "$SANDBOX/demo" worktree remove --force "$SANDBOX/demo/.worktrees/demo-mismatch" >/dev/null 2>&1
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

echo "wtc drop: refuses an ambiguous label, and deletes neither"
# Two honest worktrees sharing a label: role_tag() abbreviates an
# unrecognised role to its first three letters, so a "devops" worktree reads
# DEV, same as "developer" — collision, not corruption. Built directly
# (skipping cmd_start, which requires a role file) since describe_worktree()
# is documented to handle a worktree wtc didn't create.
git -C "$SANDBOX/demo" worktree add "$SANDBOX/demo/.worktrees/demo-developer" -b demo-developer-2 >/dev/null 2>&1
mkdir -p "$SANDBOX/demo/.worktrees/demo-developer/.agents"
printf 'developer\n' > "$SANDBOX/demo/.worktrees/demo-developer/.agents/ROLE"
git -C "$SANDBOX/demo" worktree add "$SANDBOX/demo/.worktrees/demo-devops" -b demo-devops >/dev/null 2>&1
mkdir -p "$SANDBOX/demo/.worktrees/demo-devops/.agents"
printf 'devops\n' > "$SANDBOX/demo/.worktrees/demo-devops/.agents/ROLE"

out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" drop demo DEV 2>&1)
check "exits 1" "1" "$?"
contains "names the first candidate by directory" "demo-developer" "$out"
contains "names the second candidate by directory" "demo-devops" "$out"
contains "suggests the directory name as the way out" "Use the directory name" "$out"
check "neither worktree was removed" "yes yes" \
  "$([ -d "$SANDBOX/demo/.worktrees/demo-developer" ] && echo yes || echo no) $([ -d "$SANDBOX/demo/.worktrees/demo-devops" ] && echo yes || echo no)"

echo "wtc drop: --force does not override an ambiguous label"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" drop demo DEV --force 2>&1)
check "still exits 1" "1" "$?"
contains "still refuses, by name" "matches more than one worktree" "$out"
check "still neither worktree was removed" "yes yes" \
  "$([ -d "$SANDBOX/demo/.worktrees/demo-developer" ] && echo yes || echo no) $([ -d "$SANDBOX/demo/.worktrees/demo-devops" ] && echo yes || echo no)"

echo "wtc drop: the directory name resolves an ambiguous label unambiguously"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" drop demo demo-devops --force 2>&1)
check "exits 0" "0" "$?"
contains "removes exactly that one" "removed" "$out"
check "demo-devops is gone" "no" \
  "$([ -d "$SANDBOX/demo/.worktrees/demo-devops" ] && echo yes || echo no)"
check "demo-developer is untouched" "yes" \
  "$([ -d "$SANDBOX/demo/.worktrees/demo-developer" ] && echo yes || echo no)"

echo "wtc drop: with the collision gone, the label alone works again"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" drop demo DEV --force 2>&1)
check "exits 0" "0" "$?"
contains "removes it" "removed" "$out"

echo "wtc drop: an unknown label is explained, not confused with a missing repo"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" drop other NOSUCH 2>&1)
check "exits 1" "1" "$?"
contains "says the label wasn't found" "no worktree named" "$out"

echo "wtc drop: missing arguments print usage"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" drop demo 2>&1)
check "exits 2" "2" "$?"
contains "prints usage" "Usage:" "$out"

summary
