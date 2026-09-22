#!/usr/bin/env bash
# Agent PRs counted, and capped where AGENTS.md asks (issue #1, lib/throttle.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
TENDER="$PWD/bin/tender"
DEV_ROLE="$PWD/roles/developer.md"
make_sandbox
STUB=$(mktemp -d)
trap 'tmux kill-session -t =tender-demo >/dev/null 2>&1; tmux kill-session -t =tender-acme >/dev/null 2>&1; rm -rf "$SANDBOX" "$STUB"' EXIT

# gh is stubbed: `pr list -R <owner>/<name>` answers from $STUB/prs-<name>
# ("branch createdAt" lines — what the real call's --jq turns gh's JSON
# into), or fails if $STUB/fail-<name> exists. Every other gh call (status's
# searches) prints nothing. Every call is logged, so a test can prove gh was
# NOT asked.
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
slug=""
prev=""
for a in "$@"; do [ "$prev" = "-R" ] && slug=$a; prev=$a; done
name=${slug#*/}
case "$*" in
  "pr list"*)
    if [ -e "$STUB_DIR/fail-$name" ]; then echo "gh: could not authenticate" >&2; exit 1; fi
    echo "a warning on stderr that must not be counted" >&2
    cat "$STUB_DIR/prs-$name" 2>/dev/null
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

# $1 repo, $2 extra AGENTS.md line (optional), $3 origin URL (default: a
# GitHub repo of someowner; "none" for no origin at all).
set_up() {
  [ -e "$SANDBOX/$1/.git" ] || {
    git init -q -b main "$SANDBOX/$1"
    git -C "$SANDBOX/$1" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
  }
  git -C "$SANDBOX/$1" remote remove origin 2>/dev/null
  local url=${3:-https://github.com/someowner/$1.git}
  [ "$url" = none ] || git -C "$SANDBOX/$1" remote add origin "$url"
  printf 'trunk: main\nreviewer: x\n%s\n' "${2:-}" > "$SANDBOX/$1/AGENTS.md"
}

# A running session pane: repo $1, worktree directory name $2, window name $3
# — started in the worktree with -c, exactly as cmd_start() does it.
run_pane() {
  local wt="$SANDBOX/$1/.worktrees/$2"
  mkdir -p "$wt"
  if tmux has-session -t "=tender-$1" 2>/dev/null; then
    tmux new-window -t "=tender-$1" -c "$wt" -n "$3" sleep 600
  else
    tmux new-session -d -s "tender-$1" -c "$wt" -n "$3" sleep 600
  fi
}
stop_panes() { tmux kill-session -t "=tender-$1" >/dev/null 2>&1; }
# Removes the worktree a successful start of `developer second` created.
forget_second() {
  rm -rf "$SANDBOX/$1/.worktrees/$1-developer-second"
  git -C "$SANDBOX/$1" worktree prune
  git -C "$SANDBOX/$1" branch -q -D "$1-developer-second" 2>/dev/null
}
status() { TENDER_REVIEWER=r "$TENDER" status someowner 2>&1; }

echo "throttle: counting — exact branch rule, oldest"
set_up acme "max-open-prs: 5"
set_up acme-web
# acme's listing: two agent PRs plus lookalikes that must not count.
cat > "$STUB/prs-acme" <<EOF
acme-developer $(ago $((2 * DAY + 60)))
acme-developer-a11y $(ago 3600)
acme-developerx $(ago $((9 * DAY)))
acme-web-developer $(ago $((9 * DAY)))
acme-reviewer $(ago $((9 * DAY)))
feature/login $(ago $((9 * DAY)))
EOF
: > "$STUB/prs-acme-web"
out=$(status)
contains "counts exact and suffixed branches, oldest from createdAt" \
  "acme: 2 agent PRs open, oldest waiting 2d (cap 5)" "$out"
lacks "a repo with none gets no line" "acme-web:" "$out"
contains "the section has its heading" "agent PRs open:" "$out"
calls=$(cat "$GH_CALLS")
contains "asks gh pr list for origin's repository" \
  "pr list -R someowner/acme --state open --json headRefName,createdAt --limit 200" "$calls"
# The stub cannot tell a draft from a ready PR — what is provable here is
# that the call carries no draft filter, so gh returns both.
lacks "passes no draft filter to gh pr list" "draft" "$(grep 'pr list' "$GH_CALLS")"

echo "throttle: one PR reads in the singular"
printf 'acme-developer %s\n' "$(ago $((5 * 3600 + 60)))" > "$STUB/prs-acme"
out=$(status)
contains "singular, hours" "acme: 1 agent PR open, waiting 5h (cap 5)" "$out"

echo "throttle: at the cap reads full"
set_up acme "max-open-prs: 2  # keep it small"
printf 'acme-developer %s\nacme-developer-b %s\n' "$(ago 120)" "$(ago 600)" > "$STUB/prs-acme"
out=$(status)
contains "full at the cap, trailing comment allowed" "acme: 2 agent PRs open, oldest waiting 10m (cap 2 — full)" "$out"

echo "throttle: no cap — just the count"
set_up acme
out=$(status)
contains "no cap note without a cap" "acme: 2 agent PRs open, oldest waiting 10m" "$out"
lacks "says nothing about a cap" "cap" "$(printf '%s\n' "$out" | grep '^  acme:')"

echo "throttle: the template's commented hint is no cap"
printf 'trunk: main\n<!-- max-open-prs: 3  cap on open agent PRs — see docs/limits.md -->\n' > "$SANDBOX/acme/AGENTS.md"
out=$(status)
lacks "an HTML-commented hint is not read as a cap" "cap" "$(printf '%s\n' "$out" | grep '^  acme:')"

echo "throttle: invalid cap — reported, and never treated as 0"
for bad in "0" "-1" "three" "3x" "" "03" "1234567890"; do
  set_up acme "max-open-prs: $bad"
  out=$(status)
  contains "'$bad' is reported as not a positive integer" \
    "(max-open-prs '$bad' in AGENTS.md is not a positive integer — no cap applied)" "$out"
  lacks "'$bad' is not shown as a full cap" "full" "$out"
done
set_up acme "max-open-prs: 999999999"
out=$(status)
contains "nine digits is still a valid cap" "(cap 999999999)" "$out"
: > "$STUB/prs-acme"
set_up acme "max-open-prs: zero"
out=$(status)
contains "an invalid cap is reported even with no PRs open" \
  "acme: no agent PRs open (max-open-prs 'zero'" "$out"

echo "throttle: could not ask is not zero"
set_up acme "max-open-prs: 2"
touch "$STUB/fail-acme"
out=$(status)
check "a failed count fails the board" "1" "$?"
contains "says it could not ask, with gh's reason" "acme: could not ask: gh: could not authenticate" "$out"
lacks "does not claim zero" "no agent PRs" "$out"
contains "warns the board is incomplete" "incomplete" "$out"
rm -f "$STUB/fail-acme"
: > "$STUB/prs-acme"
out=$(status)
check "asked, and none open: exits 0" "0" "$?"
contains "asked, and none open: (none)" "agent PRs open:
  (none)" "$out"

echo "throttle: only GitHub origins of the given owner are asked"
set_up acme "max-open-prs: 2" none
set_up acme-web "" "https://gitlab.com/someowner/acme-web.git"
set_up other "" "https://github.com/otherowner/other.git"
printf 'other-developer %s\n' "$(ago 60)" > "$STUB/prs-other"
: > "$GH_CALLS"
out=$(status)
check "no GitHub origin, other owner: board exits 0" "0" "$?"
lacks "no section when nothing was asked" "agent PRs open:" "$out"
check "none of them was asked" "" "$(grep 'pr list' "$GH_CALLS")"
out=$(TENDER_REVIEWER=r "$TENDER" status OtherOwner 2>&1)
contains "the owner is matched case-insensitively" "other: 1 agent PR open" "$out"
for url in "git@github.com:someowner/acme.git" "ssh://git@github.com/someowner/acme" \
           "https://someone@github.com/someowner/acme.git/"; do
  set_up acme "" "$url"
  : > "$GH_CALLS"
  status >/dev/null
  contains "origin $url is read as someowner/acme" "-R someowner/acme " "$(cat "$GH_CALLS")"
done
rm -rf "$SANDBOX/other" "$SANDBOX/acme-web"

echo "throttle: a listing cut off at its limit is a lower bound"
set_up acme "max-open-prs: 2"
{
  printf 'acme-developer %s\n' "$(ago 60)"
  i=1; while [ "$i" -lt 200 ]; do printf 'feature-%s %s\n' "$i" "$(ago 60)"; i=$((i + 1)); done
} > "$STUB/prs-acme"
out=$(status)
contains "says ≥N and that the list was truncated" "acme: ≥1 agent PRs open (list truncated at 200)" "$out"
lacks "no cap verdict on a lower bound" "(cap 2" "$out"
sed '$d' "$STUB/prs-acme" > "$STUB/prs-acme.199" && mv "$STUB/prs-acme.199" "$STUB/prs-acme"
out=$(status)
contains "199 listed is a complete answer (and gh's stderr warning is not a listed line)" "acme: 1 agent PR open, waiting 1m (cap 2)" "$out"

echo "throttle: the start refusal needs all three conditions"
set_up demo "max-open-prs: 2"
printf 'demo-developer %s\ndemo-developer-b %s\n' "$(ago 120)" "$(ago 600)" > "$STUB/prs-demo"
run_pane demo demo-developer DEV

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
forget_second demo
set_up demo "max-open-prs: nope"
out=$("$TENDER" demo developer second 2>&1)
check "invalid cap: starts (treated as no cap, not 0)" "0" "$?"
forget_second demo

# (b) false: under the cap
set_up demo "max-open-prs: 3"
printf 'demo-developer %s\ndemo-developer-b %s\n' "$(ago 120)" "$(ago 600)" > "$STUB/prs-demo"
out=$("$TENDER" demo developer second 2>&1)
check "under the cap: starts" "0" "$?"
forget_second demo

# (c) false: no other developer session running
set_up demo "max-open-prs: 2"
stop_panes demo
: > "$GH_CALLS"
out=$("$TENDER" demo developer second 2>&1)
check "no developer running: the first session starts even at the cap" "0" "$?"
check "no developer running: gh is not asked" "" "$(grep 'pr list' "$GH_CALLS")"
forget_second demo

echo "throttle: what counts as another developer session — the pane's path"
# Only the session's own pane running — re-running the same worktree is not
# an additional session.
run_pane demo demo-developer DEV
out=$("$TENDER" demo developer 2>&1)
check "its own pane is not 'another'" "0" "$?"
stop_panes demo
# The developer worktree exists but is not running; a devops session — whose
# window role_tag() also names DEV — is. At the cap, the start proceeds.
run_pane demo demo-devops DEV
out=$("$TENDER" demo developer second 2>&1)
check "a devops window named DEV, next to an idle developer worktree, is not a developer session" "0" "$?"
forget_second demo
stop_panes demo
# The suffix variant: `devops x` runs in window DEV·x, the very name a
# running `developer x` would have — and worktree demo-developer-x exists.
mkdir -p "$SANDBOX/demo/.worktrees/demo-developer-x"
run_pane demo demo-devops-x "DEV·x"
out=$("$TENDER" demo developer second 2>&1)
check "window DEV·x from devops x is not developer x" "0" "$?"
forget_second demo
stop_panes demo
# A suffixed developer running counts as another session.
run_pane demo demo-developer-a11y "DEV·a11y"
out=$("$TENDER" demo developer 2>&1)
check "a running suffixed developer makes the unsuffixed start an additional one" "1" "$?"
# Found by path even after the window was renamed.
tmux rename-window -t "=tender-demo:DEV·a11y" "whatever"
out=$("$TENDER" demo developer 2>&1)
check "a renamed window is still found by its path" "1" "$?"
# A tmux older than 3.3 prints pane_start_path as nothing. Played by a thin
# wrapper around the real (private-socket) tmux that blanks that one field:
# the start must go ahead and say why, not refuse or stay silent.
OLDTMUX=$(mktemp -d)
REAL_TMUX=$(command -v tmux)
cat > "$OLDTMUX/tmux" <<EOF
#!/usr/bin/env bash
if [ "\$1" = list-panes ]; then
  "$REAL_TMUX" "\$@" | sed 's|^x.*|x|'
else
  exec "$REAL_TMUX" "\$@"
fi
EOF
chmod +x "$OLDTMUX/tmux"
out=$(PATH="$OLDTMUX:$PATH" "$TENDER" demo developer 2>&1)
check "tmux < 3.3: starts, it cannot tell the sessions apart" "0" "$?"
contains "tmux < 3.3: says so instead of staying silent" "pane_start_path needs tmux 3.3" "$out"
rm -rf "$OLDTMUX"
stop_panes demo
# Another repo's session whose name only starts with this one's does not count.
set_up de "max-open-prs: 1"
printf 'de-developer %s\n' "$(ago 60)" > "$STUB/prs-de"
mkdir -p "$SANDBOX/de/.worktrees/de-developer"
run_pane demo demo-developer DEV
out=$("$TENDER" de developer second 2>&1)
check "tender-demo's pane is not a session of repo 'de'" "0" "$?"
stop_panes demo

echo "throttle: could not ask at start — start, with a warning"
set_up demo "max-open-prs: 1"
run_pane demo demo-developer-a11y "DEV·a11y"
touch "$STUB/fail-demo"
out=$("$TENDER" demo developer 2>&1)
check "could not ask: starts" "0" "$?"
contains "could not ask: one-line warning with the reason" \
  "could not count open agent PRs (gh: could not authenticate) — starting anyway, max-open-prs: 1 unchecked" "$out"
rm -f "$STUB/fail-demo"
set_up demo "max-open-prs: 1" none
out=$("$TENDER" demo developer 2>&1)
check "no GitHub origin: starts" "0" "$?"
contains "no GitHub origin: says why it could not count" "(origin is not a GitHub remote) — starting anyway" "$out"
truncated_listing() {
  {
    printf 'demo-developer %s\n' "$(ago 60)"
    i=1; while [ "$i" -lt 200 ]; do printf 'feature-%s %s\n' "$i" "$(ago 60)"; i=$((i + 1)); done
  } > "$STUB/prs-demo"
}
# One agent PR seen before the cut: a lower bound of 1.
set_up demo "max-open-prs: 2"
truncated_listing
out=$("$TENDER" demo developer 2>&1)
check "truncated listing below the cap: starts, like could not ask" "0" "$?"
contains "truncated listing below the cap: says the count is incomplete" "stopped at 200 open PRs, so the count is incomplete" "$out"
set_up demo "max-open-prs: 1"
truncated_listing
out=$("$TENDER" demo developer 2>&1)
check "truncated listing whose lower bound reaches the cap: refused" "1" "$?"
contains "... as a full queue, not as could-not-ask" "at its cap (max-open-prs: 1" "$out"
stop_panes demo

echo "throttle: gh missing is could-not-ask too"
# A PATH without gh at all. bin/tender itself still needs bash, git, date,
# sed, grep — so shadow only gh, like test_status.sh shadows tmux.
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
run_pane demo demo-developer-a11y "DEV·a11y"
out=$(PATH="${NOGH_PATH#:}" "$TENDER" demo developer 2>&1)
check "no gh: the start proceeds" "0" "$?"
contains "no gh: says so in one line" "could not count open agent PRs (gh is not installed) — starting anyway" "$out"
rm -rf "$NOGH"

echo "throttle: other roles are never throttled"
: > "$GH_CALLS"
out=$("$TENDER" demo reviewer 2>&1)
check "a reviewer starts at the cap" "0" "$?"
check "and gh is not asked for it" "" "$(grep 'pr list' "$GH_CALLS")"
stop_panes demo

echo "throttle: the developer role's count block, executed"
# The count block of roles/developer.md "Working" step 2, run as written in
# a real developer worktree, against a gh stub that applies the snippet's
# own --jq to a JSON listing — so the branch rule in the prose is what is
# tested, not a copy of it.
if command -v jq >/dev/null 2>&1; then
  SNIP="$STUB/count.sh"
  awk '/^2\. \*\*If this project caps open agent PRs/ { in_step = 1 }
       in_step && /^   ```bash$/ { grab = 1; next }
       grab && /^   ```$/ { exit }
       grab { sub(/^   /, ""); print }' "$DEV_ROLE" > "$SNIP"
  printf '\necho "RESULT full=$full open=${open:-}"\n' >> "$SNIP"
  contains "the count block was found" "gh pr list" "$(cat "$SNIP")"
  lacks "the count block pushes nothing" "git push" "$(cat "$SNIP")"

  JQSTUB=$(mktemp -d)
  cat > "$JQSTUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
[ -e "$STUB_DIR/snip-fail" ] && { echo "gh: offline" >&2; exit 1; }
q=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && q=$a; prev=$a; done
jq -r "$q" "$STUB_DIR/snip.json"
STUBEOF
  chmod +x "$JQSTUB/gh"
  set_up snip
  git -C "$SANDBOX/snip" worktree add -q "$SANDBOX/snip/.worktrees/snip-developer-x" -b snip-developer-x
  SWT="$SANDBOX/snip/.worktrees/snip-developer-x"
  printf '[{"headRefName":"snip-developer"},{"headRefName":"snip-developer-b"},{"headRefName":"snip-developerx"},{"headRefName":"snip-web-developer"},{"headRefName":"other"}]\n' > "$STUB/snip.json"
  runsnip() { (cd "$SWT" && PATH="$JQSTUB:$PATH" bash "$SNIP" 2>&1); }

  printf 'max-open-prs: 3\n' > "$SWT/AGENTS.md"
  contains "lookalike branches are not counted (2 of 5 listed, cap 3)" "RESULT full=no open=2" "$(runsnip)"
  printf 'max-open-prs: 2  # small\n' > "$SWT/AGENTS.md"
  contains "at the cap: full=yes" "RESULT full=yes open=2" "$(runsnip)"
  # The branch moves on with every issue, and is detached mid-rebase; the
  # count must not: it reads the repo off the worktree's directory name.
  git -C "$SWT" checkout -q -b feature-42
  contains "on another branch: still counts this repo's agent PRs" "RESULT full=yes open=2" "$(runsnip)"
  git -C "$SWT" checkout -q --detach
  contains "on a detached HEAD: still counts" "RESULT full=yes open=2" "$(runsnip)"
  git -C "$SWT" checkout -q snip-developer-x
  OTHER_WT="$SANDBOX/snip/.worktrees/scratch"
  git -C "$SANDBOX/snip" worktree add -q "$OTHER_WT" -b scratch
  printf 'max-open-prs: 2\n' > "$OTHER_WT/AGENTS.md"
  out=$(cd "$OTHER_WT" && PATH="$JQSTUB:$PATH" bash "$SNIP" 2>&1)
  contains "a worktree not named <repo>-developer: full=unknown, never a silent zero" "RESULT full=unknown" "$out"
  contains "... and says why" "cannot tell which PRs are agent PRs" "$out"
  printf 'trunk: main\n' > "$SWT/AGENTS.md"
  contains "no cap: full=no, gh not needed" "RESULT full=no open=" "$(runsnip)"
  printf 'max-open-prs: 1234567890\n' > "$SWT/AGENTS.md"
  out=$(runsnip)
  contains "ten digits: reported" "is not a positive integer — treated as no cap" "$out"
  contains "ten digits: no cap" "RESULT full=no" "$out"
  printf 'max-open-prs: 2\n' > "$SWT/AGENTS.md"
  touch "$STUB/snip-fail"
  out=$(runsnip)
  contains "could not ask: full=unknown" "RESULT full=unknown" "$out"
  contains "could not ask: says so" "going ahead without the max-open-prs check" "$out"
  rm -f "$STUB/snip-fail"
  # A listing cut off at 200 with one agent PR in it: a lower bound of 1,
  # below the cap of 2 — proves nothing.
  { printf '[{"headRefName":"snip-developer"}'; i=1; while [ "$i" -lt 200 ]; do printf ',{"headRefName":"feature-%s"}' "$i"; i=$((i + 1)); done; printf ']\n'; } > "$STUB/snip.json"
  out=$(runsnip)
  contains "listing cut off below the cap: full=unknown" "RESULT full=unknown" "$out"
  contains "listing cut off below the cap: says so" "count is incomplete" "$out"
  # Cut off, but 200 agent PRs already seen: at the cap whatever lies past it.
  { printf '['; i=0; while [ "$i" -lt 200 ]; do [ "$i" -gt 0 ] && printf ','; printf '{"headRefName":"snip-developer-%s"}' "$i"; i=$((i + 1)); done; printf ']\n'; } > "$STUB/snip.json"
  out=$(runsnip)
  contains "listing cut off at or above the cap: full=yes" "RESULT full=yes open=200" "$out"
  lacks "... without the could-not-ask note" "count is incomplete" "$out"
  rm -rf "$JQSTUB"
else
  echo "  skip (jq not installed — the role snippet's --jq needs a real jq to run)"
fi

summary
