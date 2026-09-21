#!/usr/bin/env bash
# Measures how often the HISTORICAL issue-claim race in roles/developer.md
# used to collide, back when claiming an issue meant `gh issue edit --add-
# assignee @me` (step 2) after `gh issue list --label ready --search
# "no:assignee"` (step 1) - a signal, not a lock, with an unprotected window
# between the two steps.
#
# As of commit 33faccc ("feat(roles): make the claim a git ref, not just an
# assignee"), roles/developer.md no longer works this way: the claim is a
# `git push` of a uniquely-named commit to `refs/claims/issue-<N>`, which the
# forge serializes server-side, so this script's race no longer exists in the
# live role. Re-pointing this script at the new mechanism would mean racing
# `git push` against the same ref instead of `gh issue edit`, which is a
# different script - if you need THAT measurement, do not reuse this one
# under the same name, or a later reader will assume it covers the current
# mechanism when its numbers are about the retired one.
#
# This script reproduces the retired race with K concurrent "agents" (real
# parallelism: `&` + `wait`, never artificially staggered) against a pool of
# N disposable issues, and reports:
#
#   m1  the collision rate for a K/N combination: how often two or more
#       agents settle on the same issue, and the width of the window
#       (end of step 1 to end of step 2) in milliseconds.
#   m3  the same-account blind spot: two concurrent `--add-assignee @me`
#       calls against ONE issue, by the one account every role in a project
#       may share (roles/_base.md). Reports whether either call fails, and
#       what the assignee list and issue events show afterwards.
#
# Does NOT run in CI: it needs a real GitHub repo reachable via `gh` and a
# token with issue write access, and it leaves real (if cleaned-up) API
# traffic and history in whatever repo you point it at. Run it by hand
# against a disposable repo.
#
# Usage:
#   scripts/burst-claim.sh <owner/repo> [m1|m3] [reps]
#
#   <owner/repo>  required, no default - this writes real issues and
#                 assignments, so it never guesses a target.
#   m1|m3         which measurement to run (default: m1).
#   reps          how many times to repeat each case (default: 10 for m1,
#                 5 for m3).
#
# m1 runs the three K/N combinations from the burst-test brief: K=2,N=1
# (everyone wants the same issue), K=3,N=3 (exactly enough work), K=5,N=10
# (supply exceeds demand). Override with BURST_COMBOS="K:N K:N ...".
#
# Cleans up after itself: every issue it creates is unassigned and closed
# again before the script exits (even on error or interrupt), so a second
# run never inherits the first run's leftovers. Each run tags its issues
# with a unique id and searches only for that id, so a leftover from a
# failed cleanup cannot inflate a later run's pool either.

set -uo pipefail

# Forces plain-C number/sort behaviour regardless of the caller's locale -
# without it, awk's "%.2f" prints a comma decimal separator under e.g.
# LANG=de_DE.UTF-8, which silently breaks the CSV output below.
export LC_ALL=C

REPO=${1:-}
MODE=${2:-m1}
REPS_ARG=${3:-}

usage() {
  echo "Usage: $0 <owner/repo> [m1|m3] [reps]" >&2
  echo "Refuses to guess a repo - this writes real issues and assignments." >&2
}

if [ -z "$REPO" ]; then
  usage
  exit 1
fi

if [ "$MODE" != "m1" ] && [ "$MODE" != "m3" ]; then
  usage
  exit 1
fi

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/burst-claim.XXXXXX")
CLEANUP_LIST="$WORKDIR/cleanup-issues"
: > "$CLEANUP_LIST"

# now_ms: millisecond timestamp. python3 is used because $EPOCHREALTIME needs
# bash 5, and this script is meant to also run under macOS's bash 3.2. Falls
# back to second resolution (padded) if python3 is unavailable - coarser than
# the window it is timing, but it keeps the script runnable everywhere.
now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    echo "$(( $(date +%s) * 1000 ))"
  fi
}

cleanup_all() {
  local rc=$? num
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    gh issue edit "$num" --repo "$REPO" --remove-assignee @me >/dev/null 2>&1 &
  done < "$CLEANUP_LIST"
  wait
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    gh issue close "$num" --repo "$REPO" >/dev/null 2>&1 &
  done < "$CLEANUP_LIST"
  wait
  rm -rf "$WORKDIR"
  exit "$rc"
}
trap cleanup_all EXIT INT TERM

track_for_cleanup() {
  printf '%s\n' "$1" >> "$CLEANUP_LIST"
}

# create_issue_async: creates one issue and writes its number to $2.
# Backgrounded by callers so a whole pool can be created in parallel -
# creation speed has no bearing on what is being measured, only the claim
# step does.
create_issue_async() {
  local title=$1 outfile=$2 url num
  url=$(gh issue create --repo "$REPO" --title "$title" \
    --body "Disposable issue created by scripts/burst-claim.sh. Safe to ignore or close by hand." \
    --label ready 2>"$outfile.err")
  num=${url##*/}
  printf '%s' "$num" > "$outfile"
}

# wait_for_pool_visible: GitHub's issue search index (used by `--search`, the
# same call roles/developer.md makes) lags plain issue creation - measured
# directly while building this script at 5-8s on a freshly created issue.
# Waiting here, before the timed race starts, keeps that lag out of the M2
# window measurement; it would otherwise show up as false NO_CANDIDATES
# picks instead of a collision measurement.
wait_for_pool_visible() {
  local expected=$1 tag=$2 tries=0 found=0
  while [ "$tries" -lt 30 ]; do
    found=$(gh issue list --repo "$REPO" --label ready --search "no:assignee $tag" \
      --json number --jq '.[].number' 2>/dev/null | grep -c .)
    [ "$found" -ge "$expected" ] && return 0
    tries=$((tries + 1))
    sleep 1
  done
  echo "warning: search index only showed $found/$expected issues for $tag after 30s" >&2
  return 1
}

# stats_from_column: reads numbers on stdin, prints "min median max count".
stats_from_column() {
  sort -n | awk '
    { a[NR] = $1; sum += $1 }
    END {
      if (NR == 0) { print "n/a n/a n/a 0"; exit }
      mid = int((NR + 1) / 2)
      if (NR % 2 == 1) { med = a[mid] } else { med = (a[mid] + a[mid + 1]) / 2 }
      printf "%s %s %s %d\n", a[1], med, a[NR], NR
    }'
}

# agent_claim: one simulated agent. Runs the real step-1 query from
# roles/developer.md, picks uniformly at random among the candidates it
# gets back (the role file does not say how to pick when several qualify,
# so "which one" is itself part of what this measures), then runs the real
# step-2 claim. Appends one CSV line to $2/results.csv:
#   agent_id,chosen_issue,t_list_end_ms,t_claim_end_ms,edit_exit_code
agent_claim() {
  local agent_id=$1 combo_dir=$2
  local list_out t_list_end candidates=() line idx chosen edit_rc t_claim_end

  list_out=$(gh issue list --repo "$REPO" --label ready --search "no:assignee $RUN_TAG" \
    --json number,blockedBy --jq '.[] | select(.blockedBy.totalCount == 0) | .number' \
    2>"$combo_dir/list_err.$agent_id")
  t_list_end=$(now_ms)

  while IFS= read -r line; do
    [ -n "$line" ] && candidates+=("$line")
  done <<LISTOUT
$list_out
LISTOUT

  if [ "${#candidates[@]}" -eq 0 ]; then
    printf '%s,,%s,%s,NO_CANDIDATES\n' "$agent_id" "$t_list_end" "$(now_ms)" >> "$combo_dir/results.csv"
    return
  fi

  idx=$(( RANDOM % ${#candidates[@]} ))
  chosen=${candidates[$idx]}

  gh issue edit "$chosen" --repo "$REPO" --add-assignee @me >/dev/null 2>"$combo_dir/edit_err.$agent_id"
  edit_rc=$?
  t_claim_end=$(now_ms)

  printf '%s,%s,%s,%s,%s\n' "$agent_id" "$chosen" "$t_list_end" "$t_claim_end" "$edit_rc" >> "$combo_dir/results.csv"
}

run_m1_once() {
  local k=$1 n=$2 rep=$3
  RUN_TAG="burstm1-$$-$(now_ms)-k${k}n${n}r${rep}"
  local combo_dir="$WORKDIR/$RUN_TAG"
  mkdir -p "$combo_dir"
  : > "$combo_dir/results.csv"

  local j pool=()
  for j in $(seq 1 "$n"); do
    create_issue_async "burst-test $RUN_TAG issue $j" "$combo_dir/pool.$j" &
  done
  wait
  for j in $(seq 1 "$n"); do
    pool[$j]=$(cat "$combo_dir/pool.$j" 2>/dev/null)
    [ -n "${pool[$j]}" ] && track_for_cleanup "${pool[$j]}"
  done

  wait_for_pool_visible "$n" "$RUN_TAG"

  local a
  for a in $(seq 1 "$k"); do
    agent_claim "$a" "$combo_dir" &
  done
  wait

  # Collision: two or more agents' picks landed on the same issue number,
  # regardless of whether the (idempotent, single-account) assignment call
  # itself reported an error - see M3, it never does.
  local dup_issues collided=0
  dup_issues=$(awk -F, '$2 != "" { print $2 }' "$combo_dir/results.csv" | sort | uniq -d | wc -l | tr -d ' ')
  [ "$dup_issues" -gt 0 ] && collided=1

  local windows
  windows=$(awk -F, '$3 != "" && $4 != "" { print $4 - $3 }' "$combo_dir/results.csv")

  printf '%s,%s,%s,%s,%s\n' "$k" "$n" "$rep" "$collided" "$dup_issues" >> "$WORKDIR/m1-collisions.csv"
  if [ -n "$windows" ]; then
    printf '%s\n' "$windows" >> "$WORKDIR/m1-windows.txt"
  fi
}

run_m1() {
  local reps=${REPS_ARG:-10}
  local combos=${BURST_COMBOS:-"2:1 3:3 5:10"}
  : > "$WORKDIR/m1-collisions.csv"
  : > "$WORKDIR/m1-windows.txt"

  echo "K,N,reps,collided_reps,collision_rate,total_duplicate_picks" > "$WORKDIR/m1-summary.csv"

  local combo k n rep
  for combo in $combos; do
    k=${combo%%:*}
    n=${combo##*:}
    echo "=== K=$k N=$n (${reps} reps) ==="
    for rep in $(seq 1 "$reps"); do
      run_m1_once "$k" "$n" "$rep"
    done
    local collided_reps total_dups
    collided_reps=$(awk -F, -v k="$k" -v n="$n" '$1==k && $2==n { s += $4 } END { print s+0 }' "$WORKDIR/m1-collisions.csv")
    total_dups=$(awk -F, -v k="$k" -v n="$n" '$1==k && $2==n { s += $5 } END { print s+0 }' "$WORKDIR/m1-collisions.csv")
    printf 'K=%s,N=%s,%s,%s,%s,%s\n' "$k" "$n" "$reps" "$collided_reps" \
      "$(awk -v c="$collided_reps" -v r="$reps" 'BEGIN { printf "%.2f", c / r }')" "$total_dups" \
      >> "$WORKDIR/m1-summary.csv"
    echo "  collided reps: $collided_reps / $reps"
  done

  echo
  echo "=== M1 summary (combo,K,N,reps,collided_reps,collision_rate,total_duplicate_picks) ==="
  cat "$WORKDIR/m1-summary.csv"
  echo
  echo "=== M2: claim window (list end -> assign end), milliseconds, all attempts pooled ==="
  echo "min median max count"
  stats_from_column < "$WORKDIR/m1-windows.txt"
}

run_m3_once() {
  local rep=$1
  RUN_TAG="burstm3-$$-$(now_ms)-r${rep}"
  local dir="$WORKDIR/$RUN_TAG"
  mkdir -p "$dir"

  local url num
  url=$(gh issue create --repo "$REPO" --title "burst-test $RUN_TAG same-account double claim" \
    --body "Disposable issue created by scripts/burst-claim.sh (m3)." --label ready)
  num=${url##*/}
  track_for_cleanup "$num"

  gh issue edit "$num" --repo "$REPO" --add-assignee @me >"$dir/out.a" 2>"$dir/err.a" &
  local pid_a=$!
  gh issue edit "$num" --repo "$REPO" --add-assignee @me >"$dir/out.b" 2>"$dir/err.b" &
  local pid_b=$!
  local rc_a=0 rc_b=0
  wait "$pid_a" || rc_a=$?
  wait "$pid_b" || rc_b=$?

  local assignees events
  assignees=$(gh issue view "$num" --repo "$REPO" --json assignees --jq '[.assignees[].login] | join("|")')
  events=$(gh api "repos/$REPO/issues/$num/events" --jq '[.[] | select(.event == "assigned")] | length')

  printf 'issue=%s rc_a=%s rc_b=%s assignees=[%s] assigned_events=%s\n' \
    "$num" "$rc_a" "$rc_b" "$assignees" "$events" >> "$WORKDIR/m3-results.txt"
}

run_m3() {
  local reps=${REPS_ARG:-5}
  : > "$WORKDIR/m3-results.txt"
  local rep
  for rep in $(seq 1 "$reps"); do
    run_m3_once "$rep"
  done
  echo "=== M3: two concurrent --add-assignee @me on ONE issue, same account, ${reps} reps ==="
  cat "$WORKDIR/m3-results.txt"
  local fails
  fails=$(grep -cvE 'rc_a=0 rc_b=0' "$WORKDIR/m3-results.txt" || true)
  echo
  echo "reps where either call reported a non-zero exit: $fails / $reps"
}

case "$MODE" in
  m1) run_m1 ;;
  m3) run_m3 ;;
esac
