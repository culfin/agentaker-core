#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
ATK="$PWD/bin/atk"
make_sandbox
trap 'tmux kill-session -t atk-demo >/dev/null 2>&1; rm -rf "$SANDBOX"' EXIT

# A second repo, so `atk list` (no argument) has more than one heading to
# get right, and `atk list demo` has something to prove it excluded.
git init -q -b main "$SANDBOX/other"
git -C "$SANDBOX/other" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init

# A bare remote for demo, with main already on it, so the push assertions
# below (and the "unrelated branch" fixture further down) have somewhere to
# push to. cmd_drop's unpushed-commits check is scoped to the worktree's own
# branch (HEAD --not --remotes) — it no longer matters whether main itself
# is pushed.
git init -q --bare "$SANDBOX/demo-remote.git"
git -C "$SANDBOX/demo" remote add origin "$SANDBOX/demo-remote.git"
git -C "$SANDBOX/demo" push -q origin main

echo "atk list: nothing yet"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" list 2>&1)
contains "says so when a repo has no worktrees" "no worktrees under" "$out"

echo "atk list: shows what exists"
"$ATK" demo developer >/dev/null 2>&1
"$ATK" demo developer eyeoffice >/dev/null 2>&1
"$ATK" other developer >/dev/null 2>&1
# A worktree whose directory name and branch differ, built directly like the
# drop-ambiguity fixtures below: atk's own worktrees always name the branch
# after the directory, which would let a dirname-column check pass even if
# the column were actually just repeating the branch column.
git -C "$SANDBOX/demo" worktree add "$SANDBOX/demo/.worktrees/demo-mismatch" -b totally-different-branch >/dev/null 2>&1
mkdir -p "$SANDBOX/demo/.worktrees/demo-mismatch/.agents"
printf 'developer\n' > "$SANDBOX/demo/.worktrees/demo-mismatch/.agents/ROLE"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" list 2>&1)
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
# directory name and branch are genuinely different strings — on atk's own
# worktrees they're identical, so a check there couldn't tell "shows the
# directory name" from "shows the branch again."
contains "shows a directory name that differs from its branch" "demo-mismatch" "$out"
contains "... alongside that actual branch name" "totally-different-branch" "$out"
contains "shows the branch atk created" "demo-developer-eyeoffice" "$out"
# Done with it — it was only here to prove the dirname column isn't just the
# branch column twice, and its DEV label would otherwise collide with
# demo-developer for every `drop` test below (a real collision, correctly
# refused, but not what those tests are checking).
git -C "$SANDBOX/demo" worktree remove --force "$SANDBOX/demo/.worktrees/demo-mismatch" >/dev/null 2>&1
contains "sizes are off by default — du is slow on a large tree" "sizes omitted" "$out"
lacks "an idle worktree is not claimed to be running" "running" "$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" list demo 2>&1)"

echo "atk list: a repo argument filters to it"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" list demo 2>&1)
contains "shows the requested repo" "demo" "$out"
lacks "excludes the other repo" "other" "$out"

echo "atk list: --size actually measures"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" list demo --size 2>&1)
lacks "no longer says sizes are omitted" "sizes omitted" "$out"
contains "prints a real du size, not a placeholder" "K" "$out"

echo "atk list: an unknown repo is explained, not silently empty"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" list nosuchrepo 2>&1)
check "exits 1" "1" "$?"
contains "says it's not a git repository" "not a git repository" "$out"

echo "atk drop: refuses on uncommitted changes, and says how many"
echo one > "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice/a.txt"
echo two > "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice/b.txt"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" drop demo DEV·eyeoffice 2>&1)
check "exits 1" "1" "$?"
contains "counts the uncommitted files" "2 uncommitted file(s)" "$out"
lacks "does not remove the worktree" "removed" "$out"
check "the worktree is still there" "yes" \
  "$([ -d "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice" ] && echo yes || echo no)"
rm -f "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice/a.txt" "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice/b.txt"

echo "atk drop: refuses on commits with no remote, and names the branch"
git -C "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice" -c user.email=t@e -c user.name=t \
  commit -q --allow-empty -m "not pushed anywhere"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" drop demo DEV·eyeoffice 2>&1)
check "exits 1" "1" "$?"
contains "counts the unpushed commit" "1 commit(s)" "$out"
# The exact phrase, not bare "demo-developer-eyeoffice": that substring is
# also part of the worktree's own path, which a success message (from a
# broken check that let the drop through) would print too.
contains "names the branch" "on demo-developer-eyeoffice not on any remote" "$out"
git -C "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice" push -q origin demo-developer-eyeoffice:demo-developer-eyeoffice

echo "atk drop: refuses on an open tmux window, and names the session"
tmux new-session -d -s atk-demo -n "DEV·eyeoffice" sleep 60
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" drop demo DEV·eyeoffice 2>&1)
check "exits 1" "1" "$?"
contains "names the session to close" "atk-demo" "$out"
contains "says to close it first" "close it first" "$out"

echo "atk drop: --force overrides all three at once"
echo dirty >> "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice/a.txt"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" drop demo DEV·eyeoffice --force 2>&1)
check "exits 0" "0" "$?"
contains "confirms the removal" "removed" "$out"
check "the worktree is actually gone" "no" \
  "$([ -d "$SANDBOX/demo/.worktrees/demo-developer-eyeoffice" ] && echo yes || echo no)"
check "git no longer lists it either" "" \
  "$(git -C "$SANDBOX/demo" worktree list | grep demo-developer-eyeoffice)"
out=$(tmux list-windows -t atk-demo 2>&1)
lacks "the tmux window is closed too" "DEV·eyeoffice" "$out"

echo "atk drop: a clean, pushed, closed worktree needs no --force"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" drop demo DEV 2>&1)
check "exits 0" "0" "$?"
contains "confirms the removal" "removed" "$out"
check "the worktree is actually gone, not just claimed to be" "no" \
  "$([ -d "$SANDBOX/demo/.worktrees/demo-developer" ] && echo yes || echo no)"

echo "atk drop: refuses an ambiguous label, and deletes neither"
# Two honest worktrees sharing a label: role_tag() abbreviates an
# unrecognised role to its first three letters, so a "devops" worktree reads
# DEV, same as "developer" — collision, not corruption. Built directly
# (skipping cmd_start, which requires a role file) since describe_worktree()
# is documented to handle a worktree atk didn't create.
git -C "$SANDBOX/demo" worktree add "$SANDBOX/demo/.worktrees/demo-developer" -b demo-developer-2 >/dev/null 2>&1
mkdir -p "$SANDBOX/demo/.worktrees/demo-developer/.agents"
printf 'developer\n' > "$SANDBOX/demo/.worktrees/demo-developer/.agents/ROLE"
git -C "$SANDBOX/demo" worktree add "$SANDBOX/demo/.worktrees/demo-devops" -b demo-devops >/dev/null 2>&1
mkdir -p "$SANDBOX/demo/.worktrees/demo-devops/.agents"
printf 'devops\n' > "$SANDBOX/demo/.worktrees/demo-devops/.agents/ROLE"

out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" drop demo DEV 2>&1)
check "exits 1" "1" "$?"
contains "names the first candidate by directory" "demo-developer" "$out"
contains "names the second candidate by directory" "demo-devops" "$out"
contains "suggests the directory name as the way out" "Use the directory name" "$out"
check "neither worktree was removed" "yes yes" \
  "$([ -d "$SANDBOX/demo/.worktrees/demo-developer" ] && echo yes || echo no) $([ -d "$SANDBOX/demo/.worktrees/demo-devops" ] && echo yes || echo no)"

echo "atk drop: --force does not override an ambiguous label"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" drop demo DEV --force 2>&1)
check "still exits 1" "1" "$?"
contains "still refuses, by name" "matches more than one worktree" "$out"
check "still neither worktree was removed" "yes yes" \
  "$([ -d "$SANDBOX/demo/.worktrees/demo-developer" ] && echo yes || echo no) $([ -d "$SANDBOX/demo/.worktrees/demo-devops" ] && echo yes || echo no)"

echo "atk drop: the directory name resolves an ambiguous label unambiguously"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" drop demo demo-devops --force 2>&1)
check "exits 0" "0" "$?"
contains "removes exactly that one" "removed" "$out"
check "demo-devops is gone" "no" \
  "$([ -d "$SANDBOX/demo/.worktrees/demo-devops" ] && echo yes || echo no)"
check "demo-developer is untouched" "yes" \
  "$([ -d "$SANDBOX/demo/.worktrees/demo-developer" ] && echo yes || echo no)"

echo "atk drop: with the collision gone, the label alone works again"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" drop demo DEV --force 2>&1)
check "exits 0" "0" "$?"
contains "removes it" "removed" "$out"

echo "atk drop: unpushed commits are scoped to the worktree's own branch, not every local branch"
# A second local branch in the same repo, carrying a commit that was never
# pushed anywhere. `git log --branches --not --remotes` (what cmd_drop ran
# before this fix) sees every local branch through the shared ref store, so
# it would refuse to drop a CLEAN, fully-pushed worktree just because this
# unrelated branch exists somewhere else in the same repo.
git -C "$SANDBOX/demo" branch unrelated-branch
git -C "$SANDBOX/demo" worktree add "$SANDBOX/demo/.worktrees/tmp-unrelated" unrelated-branch >/dev/null 2>&1
git -C "$SANDBOX/demo/.worktrees/tmp-unrelated" -c user.email=t@e -c user.name=t \
  commit -q --allow-empty -m "never pushed, unrelated to the worktree under test"
git -C "$SANDBOX/demo" worktree remove --force "$SANDBOX/demo/.worktrees/tmp-unrelated" >/dev/null 2>&1

git -C "$SANDBOX/demo" worktree add "$SANDBOX/demo/.worktrees/demo-clean" -b demo-clean >/dev/null 2>&1
mkdir -p "$SANDBOX/demo/.worktrees/demo-clean/.agents"
printf 'developer\n' > "$SANDBOX/demo/.worktrees/demo-clean/.agents/ROLE"
git -C "$SANDBOX/demo" push -q origin demo-clean:demo-clean

out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" drop demo demo-clean 2>&1)
check "exits 0 — the unrelated branch's unpushed commit is not this worktree's problem" "0" "$?"
contains "confirms the removal" "removed" "$out"

echo "atk drop: the unpushed-commits message doesn't overstate what --force costs"
git -C "$SANDBOX/demo" worktree add "$SANDBOX/demo/.worktrees/demo-unpushed" -b demo-unpushed >/dev/null 2>&1
mkdir -p "$SANDBOX/demo/.worktrees/demo-unpushed/.agents"
printf 'developer\n' > "$SANDBOX/demo/.worktrees/demo-unpushed/.agents/ROLE"
git -C "$SANDBOX/demo/.worktrees/demo-unpushed" -c user.email=t@e -c user.name=t \
  commit -q --allow-empty -m "not pushed"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" drop demo demo-unpushed 2>&1)
check "exits 1" "1" "$?"
contains "says the branch and its commits survive --force" "survive" "$out"
git -C "$SANDBOX/demo" worktree remove --force "$SANDBOX/demo/.worktrees/demo-unpushed" >/dev/null 2>&1

echo "atk drop: an unknown label is explained, not confused with a missing repo"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" drop other NOSUCH 2>&1)
check "exits 1" "1" "$?"
contains "says the label wasn't found" "no worktree named" "$out"

echo "atk drop: missing arguments print usage"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" drop demo 2>&1)
check "exits 2" "2" "$?"
contains "prints usage" "Usage:" "$out"

summary
