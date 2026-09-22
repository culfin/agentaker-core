#!/usr/bin/env bash
# Agent PRs counted, and capped where AGENTS.md asks (issue #1, lib/throttle.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
TENDER="$PWD/bin/tender"
make_sandbox
STUB=$(mktemp -d)
trap 'tmux kill-session -t =tender-demo >/dev/null 2>&1; rm -rf "$SANDBOX" "$STUB"' EXIT

# gh is stubbed: `pr list` answers from $STUB/prs-<repo> ("branch createdAt"
# lines — what the real call's --jq turns gh's JSON into), or fails if
# $STUB/fail-<repo> exists. Every other gh call (status's searches) prints
# nothing. Every call is logged, so a test can prove gh was NOT asked.
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
repo=$(basename "$PWD")
printf '%s | %s\n' "$repo" "$*" >> "$GH_CALLS"
case "$*" in
  "pr list"*)
    if [ -e "$STUB_DIR/fail-$repo" ]; then echo "no git remotes found" >&2; exit 1; fi
    cat "$STUB_DIR/prs-$repo" 2>/dev/null
    ;;
esac
exit 0
STUBEOF
chmod +x "$STUB/gh"
export GH_CALLS="$STUB/calls" STUB_DIR="$STUB"
: > "$GH_CALLS"
export PATH="$STUB:$PATH"

# ISO-8601 UTC, $1 seconds ago (GNU date, then BSD/macOS date).
ago() {
  date -u -d "@$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ
}
DAY=86400

set_up() {  # $1 repo, $2 extra AGENTS.md line (optional)
  [ -e "$SANDBOX/$1/.git" ] || {
    git init -q -b main "$SANDBOX/$1"
    git -C "$SANDBOX/$1" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
  }
  printf 'trunk: main\nreviewer: x\n%s\n' "${2:-}" > "$SANDBOX/$1/AGENTS.md"
}

echo "throttle: counting — exact branch rule, drafts, oldest"
set_up acme "max-open-prs: 5"
set_up acme-web
# acme's listing: two agent PRs (one a draft — gh pr list returns drafts by
# default, and the rule has no draft filter, so both lines count), plus
# lookalikes that must not count.
cat > "$STUB/prs-acme" <<EOF
acme-developer $(ago $((2 * DAY + 60)))
acme-developer-a11y $(ago 3600)
acme-developerx $(ago $((9 * DAY)))
acme-web-developer $(ago $((9 * DAY)))
acme-reviewer $(ago $((9 * DAY)))
feature/login $(ago $((9 * DAY)))
EOF
: > "$STUB/prs-acme-web"
out=$(TENDER_REVIEWER=r "$TENDER" status someowner 2>&1)
contains "counts exact and suffixed branches, oldest from createdAt" \
  "acme: 2 agent PRs open, oldest waiting 2d (cap 5)" "$out"
lacks "a repo with none gets no line" "acme-web:" "$out"
contains "the section has its heading" "agent PRs open:" "$out"
calls=$(cat "$GH_CALLS")
contains "asks gh pr list in the repo, drafts included (no --draft filter)" \
  "acme | pr list --state open --json headRefName,createdAt --limit 200" "$calls"
lacks "never filters drafts out" "draft" "$(grep 'pr list' "$GH_CALLS")"

echo "throttle: one PR reads in the singular"
printf 'acme-developer %s\n' "$(ago $((5 * 3600 + 60)))" > "$STUB/prs-acme"
out=$(TENDER_REVIEWER=r "$TENDER" status someowner 2>&1)
contains "singular, hours" "acme: 1 agent PR open, waiting 5h (cap 5)" "$out"

echo "throttle: at the cap reads full"
set_up acme "max-open-prs: 2  # keep it small"
printf 'acme-developer %s\nacme-developer-b %s\n' "$(ago 120)" "$(ago 600)" > "$STUB/prs-acme"
out=$(TENDER_REVIEWER=r "$TENDER" status someowner 2>&1)
contains "full at the cap, trailing comment allowed" "acme: 2 agent PRs open, oldest waiting 10m (cap 2 — full)" "$out"

echo "throttle: no cap — just the count"
set_up acme
out=$(TENDER_REVIEWER=r "$TENDER" status someowner 2>&1)
contains "no cap note without a cap" "acme: 2 agent PRs open, oldest waiting 10m" "$out"
lacks "says nothing about a cap" "cap" "$(printf '%s\n' "$out" | grep '^  acme:')"

echo "throttle: invalid cap — reported, and never treated as 0"
for bad in "0" "-1" "three" "3x" "" "03"; do
  set_up acme "max-open-prs: $bad"
  out=$(TENDER_REVIEWER=r "$TENDER" status someowner 2>&1)
  contains "'$bad' is reported as not a positive integer" \
    "(max-open-prs '$bad' in AGENTS.md is not a positive integer — no cap applied)" "$out"
  lacks "'$bad' is not shown as a full cap" "full" "$out"
done
: > "$STUB/prs-acme"
set_up acme "max-open-prs: zero"
out=$(TENDER_REVIEWER=r "$TENDER" status someowner 2>&1)
contains "an invalid cap is reported even with no PRs open" \
  "acme: no agent PRs open (max-open-prs 'zero'" "$out"

echo "throttle: could not ask is not zero"
set_up acme "max-open-prs: 2"
touch "$STUB/fail-acme"
out=$(TENDER_REVIEWER=r "$TENDER" status someowner 2>&1)
check "a failed count fails the board" "1" "$?"
contains "says it could not ask, with gh's reason" "acme: could not ask: no git remotes found" "$out"
lacks "does not claim zero" "no agent PRs" "$out"
contains "warns the board is incomplete" "incomplete" "$out"
rm -f "$STUB/fail-acme"
: > "$STUB/prs-acme"
out=$(TENDER_REVIEWER=r "$TENDER" status someowner 2>&1)
check "asked, and none open: exits 0" "0" "$?"
contains "asked, and none open: (none)" "agent PRs open:
  (none)" "$out"

echo "throttle: gh missing is could-not-ask too"
# Only the throttle part: a PATH without gh at all. bin/tender itself still
# needs bash, git, date, sed, grep — so shadow only gh, like test_status.sh
# shadows tmux.
NOGH=$(mktemp -d)
NOGH_PATH=""
IFS=':' read -ra path_dirs <<< "$PATH"
for dir in "${path_dirs[@]}"; do
  [ "$dir" = "$STUB" ] && continue
  if [ -x "$dir/gh" ]; then
    shadow="$NOGH${dir//\//_}"
    mkdir -p "$shadow"
    for entry in "$dir"/*; do
      [ "$(basename "$entry")" = gh ] && continue
      ln -s "$entry" "$shadow/$(basename "$entry")" 2>/dev/null
    done
    NOGH_PATH="$NOGH_PATH:$shadow"
  else
    NOGH_PATH="$NOGH_PATH:$dir"
  fi
done
# A developer window is running, so the start reaches the count.
mkdir -p "$SANDBOX/acme/.worktrees/acme-developer/.agents"
printf 'developer\n' > "$SANDBOX/acme/.worktrees/acme-developer/.agents/ROLE"
tmux new-session -d -s tender-acme -n "DEV" sleep 600
out=$(PATH="${NOGH_PATH#:}" "$TENDER" acme developer second 2>&1)
check "no gh: the start proceeds" "0" "$?"
contains "no gh: says so in one line" "could not count open agent PRs (gh is not installed) — starting anyway" "$out"
tmux kill-session -t =tender-acme >/dev/null 2>&1
rm -rf "$NOGH"

echo "throttle: the start refusal needs all three conditions"
set_up demo "max-open-prs: 2"
mkdir -p "$SANDBOX/demo/.worktrees/demo-developer/.agents"
printf 'developer\n' > "$SANDBOX/demo/.worktrees/demo-developer/.agents/ROLE"
printf 'demo-developer %s\ndemo-developer-b %s\n' "$(ago 120)" "$(ago 600)" > "$STUB/prs-demo"
tmux new-session -d -s tender-demo -n "DEV" sleep 600

: > "$GH_CALLS"
out=$("$TENDER" demo developer second 2>&1)
check "all three hold: refuses with exit 1" "1" "$?"
contains "names the cap and the count" \
  "demo has 2 agent PRs open, at its cap (max-open-prs: 2 in AGENTS.md)" "$out"
lacks "does not launch" "would launch" "$out"
check "creates no worktree when refusing" "no" \
  "$([ -d "$SANDBOX/demo/.worktrees/demo-developer-second" ] && echo yes || echo no)"

printf 'demo-developer %s\ndemo-developer-b %s\ndemo-developer-c %s\n' "$(ago 1)" "$(ago 2)" "$(ago 3)" > "$STUB/prs-demo"
out=$("$TENDER" demo developer second 2>&1)
check "above the cap refuses too" "1" "$?"

# (a) false: no cap
set_up demo
: > "$GH_CALLS"
out=$("$TENDER" demo developer second 2>&1)
check "no cap: starts" "0" "$?"
check "no cap: gh is not asked at all" "" "$(grep 'pr list' "$GH_CALLS")"
set_up demo "max-open-prs: nope"
out=$("$TENDER" demo developer second 2>&1)
check "invalid cap: starts (treated as no cap, not 0)" "0" "$?"
rm -rf "$SANDBOX/demo/.worktrees/demo-developer-second"
git -C "$SANDBOX/demo" worktree prune
git -C "$SANDBOX/demo" branch -q -D demo-developer-second 2>/dev/null

# (b) false: under the cap
set_up demo "max-open-prs: 3"
printf 'demo-developer %s\ndemo-developer-b %s\n' "$(ago 120)" "$(ago 600)" > "$STUB/prs-demo"
out=$("$TENDER" demo developer second 2>&1)
check "under the cap: starts" "0" "$?"
rm -rf "$SANDBOX/demo/.worktrees/demo-developer-second"
git -C "$SANDBOX/demo" worktree prune
git -C "$SANDBOX/demo" branch -q -D demo-developer-second 2>/dev/null

# (c) false: no other developer window running
set_up demo "max-open-prs: 2"
tmux kill-session -t =tender-demo >/dev/null 2>&1
: > "$GH_CALLS"
out=$("$TENDER" demo developer second 2>&1)
check "no developer running: the first session starts even at the cap" "0" "$?"
check "no developer running: gh is not asked" "" "$(grep 'pr list' "$GH_CALLS")"
rm -rf "$SANDBOX/demo/.worktrees/demo-developer-second"
git -C "$SANDBOX/demo" worktree prune
git -C "$SANDBOX/demo" branch -q -D demo-developer-second 2>/dev/null

echo "throttle: what counts as another developer session"
# Only the session's own window running — restarting/re-attaching the same
# worktree is not an additional session.
tmux new-session -d -s tender-demo -n "DEV" sleep 600
out=$("$TENDER" demo developer 2>&1)
check "its own window is not 'another'" "0" "$?"
# A different role's window that also abbreviates to DEV is not a developer.
tmux kill-session -t =tender-demo >/dev/null 2>&1
mkdir -p "$SANDBOX/demo/.worktrees/demo-devops/.agents"
printf 'devops\n' > "$SANDBOX/demo/.worktrees/demo-devops/.agents/ROLE"
rm -rf "$SANDBOX/demo/.worktrees/demo-developer"
tmux new-session -d -s tender-demo -n "DEV" sleep 600
out=$("$TENDER" demo developer second 2>&1)
check "a devops window tagged DEV is not a developer session (worktrees are walked, not DEV* windows)" "0" "$?"
rm -rf "$SANDBOX/demo/.worktrees/demo-developer-second"
git -C "$SANDBOX/demo" worktree prune
git -C "$SANDBOX/demo" branch -q -D demo-developer-second 2>/dev/null
tmux kill-session -t =tender-demo >/dev/null 2>&1
# A suffixed developer running counts as another session.
mkdir -p "$SANDBOX/demo/.worktrees/demo-developer-a11y/.agents"
printf 'developer\n' > "$SANDBOX/demo/.worktrees/demo-developer-a11y/.agents/ROLE"
tmux new-session -d -s tender-demo -n "DEV·a11y" sleep 600
out=$("$TENDER" demo developer 2>&1)
check "a running suffixed developer makes the unsuffixed start an additional one" "1" "$?"
tmux kill-session -t =tender-demo >/dev/null 2>&1
# Another repo's session whose name only starts with this one's does not count.
set_up de "max-open-prs: 1"
printf 'de-developer %s\n' "$(ago 60)" > "$STUB/prs-de"
mkdir -p "$SANDBOX/de/.worktrees/de-developer/.agents"
printf 'developer\n' > "$SANDBOX/de/.worktrees/de-developer/.agents/ROLE"
tmux new-session -d -s tender-demo -n "DEV" sleep 600
out=$("$TENDER" de developer second 2>&1)
check "tender-demo's window is not a session of repo 'de'" "0" "$?"
tmux kill-session -t =tender-demo >/dev/null 2>&1

echo "throttle: could not ask at start — start, with a warning"
set_up demo "max-open-prs: 1"
tmux new-session -d -s tender-demo -n "DEV·a11y" sleep 600
touch "$STUB/fail-demo"
out=$("$TENDER" demo developer 2>&1)
check "could not ask: starts" "0" "$?"
contains "could not ask: one-line warning with the reason" \
  "could not count open agent PRs (no git remotes found) — starting anyway, max-open-prs: 1 unchecked" "$out"
rm -f "$STUB/fail-demo"
tmux kill-session -t =tender-demo >/dev/null 2>&1

echo "throttle: other roles are never throttled"
tmux new-session -d -s tender-demo -n "DEV·a11y" sleep 600
: > "$GH_CALLS"
out=$("$TENDER" demo reviewer 2>&1)
check "a reviewer starts at the cap" "0" "$?"
check "and gh is not asked for it" "" "$(grep 'pr list' "$GH_CALLS")"
tmux kill-session -t =tender-demo >/dev/null 2>&1

summary
