#!/usr/bin/env bash
# `tender status` — the board: where work is waiting, across one owner's
# repositories. Its questions are defined here once, and both renderings ask
# them through the same engine: the text board below, and the JSON board
# (`tender status --json`, lib/status_json.sh). A JSON board that asked
# differently would be a second truth.
#
# Moved out of bin/tender when the JSON board (app issue #10) made the
# searches a shared engine and bin/tender reached its 450-line ceiling.
# Sourced by bin/tender on demand, for `status` only.
#
# Needs from bin/tender: die(), REVIEWER; throttle_status_section()
#   (lib/throttle.sh)
# Provides to it:     cmd_status(); to lib/status_json.sh: status_q_*(),
#   status_cmd(), status_section(), STATUS_SEC_*, STATUS_FAILED

STATUS_FAILED=0
STATUS_HAD_ROWS=0

# Every search asks for this many results, not gh's default 30. A section
# that comes back with exactly this many is said to be truncated — the rest
# may exist, and the board says so rather than presenting a cut as a count.
STATUS_LIMIT=100

# --- the questions ------------------------------------------------------------
# Each status_q_*() sets, for owner $1: STATUS_Q (gh's qualifiers), STATUS_F
# (JSON fields beyond the common ones, for its filter or extra), STATUS_FILTER
# (a jq filter over each result) and STATUS_X (a jq expression for the one
# extra value an item may carry — kind, merged_at — or '""').
#
# `gh search issues` — unlike `gh issue list` — has no --json blockedBy /
# dependency filter, and this asks across every repository in one call, so it
# cannot loop per-repo to get one either (see roles/developer.md for why the
# developer itself can and does filter). The text board says so rather than
# silently listing issues the developer would skip. An issue on hold
# (needs-decision) is left out, as the developer's own search does — it is
# listed under "waiting on you" instead.
STATUS_NOT_HELD='select(any((.labels // [])[]; .name == "needs-decision") | not)'
STATUS_NOT_BOT='select(.author.login | test("dependabot") | not)'
# A PR cleared by the `approved` label (single-account mode, where --approve
# is locked — roles/reviewer.md) is waiting for merge, not for review. The
# review approximation (--review none) cannot tell: no native review exists.
# A PR with needs-decision stays in the queue — a PR-level question does not
# block review (roles/_base.md, "Escalation").
STATUS_NOT_CLEARED='select(any((.labels // [])[]; .name == "approved") | not)'
STATUS_Q=() STATUS_F="" STATUS_FILTER="." STATUS_X='""'
status_q_set() { STATUS_F=$1 STATUS_FILTER=$2 STATUS_X=${3:-'""'}; }

status_q_ready() {
  STATUS_Q=(search issues --owner "$1" --state open --label ready)
  status_q_set labels "$STATUS_NOT_HELD"
}
status_q_review() {
  if [ -n "$REVIEWER" ]; then
    STATUS_Q=(search prs --owner "$1" --state open --draft=false --review-requested "$REVIEWER")
  else
    STATUS_Q=(search prs --owner "$1" --state open --draft=false --review none)
  fi
  status_q_set author,labels "$STATUS_NOT_BOT | $STATUS_NOT_CLEARED"
}
# "Approved" is two questions, one answer: natively approved, or — single-
# account mode — cleared with the label (not draft, labelled `approved`).
status_q_approved() {
  STATUS_Q=(search prs --owner "$1" --state open --review approved)
  status_q_set "" .
}
status_q_approved_label() {
  STATUS_Q=(search prs --owner "$1" --state open --draft=false --label approved)
  status_q_set "" .
}
# Issues and PRs: a question can be asked on either.
status_q_decisions() {
  STATUS_Q=(search issues --owner "$1" --state open --label needs-decision --include-prs)
  status_q_set isPullRequest . 'if .isPullRequest then "pr" else "issue" end'
}
# JSON board only, with --since $2. gh search prs has no mergedAt field;
# closedAt of a merged PR is the moment it was merged.
status_q_merged() {
  STATUS_Q=(search prs --owner "$1" --merged-at ">=$2")
  status_q_set closedAt . '(.closedAt // "")'
}

# The current question as one string of gh arguments separated by \x1f —
# \x1f because the --jq program has spaces and must stay one argument. "$@"
# goes after the qualifiers (the JSON board's --updated).
#
# The program prints the size of gh's listing first ("\x1d<N>" — before the
# filter, since that is what the limit cut), then one record per item: \x1e,
# then its fields separated by \x1f. Titles may hold quotes, tabs,
# backslashes or newlines and still arrive intact: nothing here escapes them,
# the renderer does, once. The separator comes first because gh ends every
# output with a newline, which the reader drops from the end of each record,
# where the last field is a date or a kind, never free text.
# shellcheck disable=SC2120  # lib/status_json.sh passes --updated
status_cmd() {
  local IFS=$'\x1f' fields=repository,number,title,url,updatedAt prog
  [ -z "$STATUS_F" ] || fields="$fields,$STATUS_F"
  prog=$(printf '"\\u001d\\(length)", (.[] | %s | "\\u001e" + ([.repository.name, (.number | tostring), .title, (.url // ""), (.updatedAt // ""), %s] | map((. // "") | tostring | gsub("[\\u001d-\\u001f]"; "")) | join("\\u001f")))' \
    "$STATUS_FILTER" "$STATUS_X")
  printf '%s' "${STATUS_Q[*]}${*:+$IFS$*}${IFS}--limit${IFS}$STATUS_LIMIT${IFS}--json${IFS}$fields${IFS}--jq${IFS}$prog"
}

# --- the engine ---------------------------------------------------------------
# Asks every command (a status_cmd() string) of one section and gathers its
# items into STATUS_SEC_REPO/NUMBER/TITLE/URL/UPDATED/EXTRA[0..COUNT-1],
# each repo#number once (the two questions of "approved" can both find a PR).
# Three outcomes that must never look alike: items, no items, and "could not
# ask" — STATUS_SEC_OK=0 with the reason in STATUS_SEC_ERROR, and
# STATUS_FAILED=1 so the command exits non-zero. STATUS_SEC_TRUNCATED=1 when
# any of its listings came back at the limit.
status_section() {
  local cmd
  local -a argv
  STATUS_SEC_OK=1 STATUS_SEC_ERROR="" STATUS_SEC_TRUNCATED=0 STATUS_SEC_COUNT=0 STATUS_SEC_SEEN=""
  STATUS_SEC_REPO=() STATUS_SEC_NUMBER=() STATUS_SEC_TITLE=() STATUS_SEC_URL=()
  STATUS_SEC_UPDATED=() STATUS_SEC_EXTRA=()
  for cmd in "$@"; do
    IFS=$'\x1f' read -r -a argv <<<"$cmd"
    status_collect "${argv[@]}" && continue
    STATUS_SEC_OK=0
    STATUS_FAILED=1
    return 0
  done
}

# One gh call of a section. stderr is kept apart from stdout, as in
# throttle_count(): a gh warning is not a record, and gh's first stderr line
# is the reason a failed call gives.
status_collect() {
  local out rc errfile rec size="" records repo number title url updated extra
  if ! command -v gh >/dev/null 2>&1; then STATUS_SEC_ERROR="gh is not installed"; return 1; fi
  errfile=$(mktemp) || { STATUS_SEC_ERROR="cannot create a temporary file"; return 1; }
  out=$(gh "$@" 2>"$errfile")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    STATUS_SEC_ERROR=$(head -1 "$errfile")
    STATUS_SEC_ERROR=${STATUS_SEC_ERROR:-gh exited $rc}
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"
  # Output the program above cannot have printed is not an empty section and
  # not an item either: it is an answer this cannot read.
  case $out in
    "") STATUS_SEC_ERROR="unexpected gh output: nothing at all"; return 1 ;;
    *$'\x1d'*|*$'\x1e'*) ;;
    *) STATUS_SEC_ERROR="unexpected gh output: $(printf '%s\n' "$out" | head -1)"; return 1 ;;
  esac
  case $out in
    *$'\x1d'*)
      size=${out#*$'\x1d'}
      size=${size%%[!0-9]*}
      [ -n "$size" ] && [ "$size" -ge "$STATUS_LIMIT" ] && STATUS_SEC_TRUNCATED=1 ;;
  esac
  # Without a filter the program prints one record per result, so a size the
  # records do not match is output this cannot trust, not a shorter section.
  if [ "$STATUS_FILTER" = "." ]; then
    records=${out//[!$'\x1e']/}
    if [ "${size:-x}" != "${#records}" ]; then
      STATUS_SEC_ERROR="unexpected gh output: ${size:-no} result(s) announced, ${#records} record(s) sent"
      return 1
    fi
  fi
  case $out in *$'\x1e'*) ;; *) return 0 ;; esac
  out=${out#*$'\x1e'}
  # shellcheck disable=SC2034  # URL, UPDATED and EXTRA are read by lib/status_json.sh
  while IFS= read -r -d $'\x1e' rec || [ -n "$rec" ]; do
    rec=${rec%$'\n'}
    IFS=$'\x1f' read -r -d '' repo number title url updated extra <<<"$rec"
    extra=${extra%$'\n'}   # the <<< above adds one
    updated=${updated%$'\n'}
    case "$STATUS_SEC_SEEN" in *"|$repo#$number|"*) continue ;; esac
    STATUS_SEC_SEEN="$STATUS_SEC_SEEN|$repo#$number|"
    STATUS_SEC_REPO[STATUS_SEC_COUNT]=$repo
    STATUS_SEC_NUMBER[STATUS_SEC_COUNT]=$number
    STATUS_SEC_TITLE[STATUS_SEC_COUNT]=$title
    STATUS_SEC_URL[STATUS_SEC_COUNT]=$url
    STATUS_SEC_UPDATED[STATUS_SEC_COUNT]=$updated
    STATUS_SEC_EXTRA[STATUS_SEC_COUNT]=$extra
    STATUS_SEC_COUNT=$((STATUS_SEC_COUNT + 1))
  done <<<"$out"
  return 0
}

# --- the text board -----------------------------------------------------------
# One section as text: heading, then its rows, "(none)", or "could not ask".
# STATUS_HAD_ROWS=1 on rows, so a caller can add a section-specific note
# without printing it over "(none)" or a failed query.
status_text() {
  local heading=$1 i=0
  shift
  status_section "$@"
  STATUS_HAD_ROWS=0
  printf '%s:\n' "$heading"
  if [ "$STATUS_SEC_OK" -eq 0 ]; then
    printf '  could not ask: %s\n' "$STATUS_SEC_ERROR"
    return 0
  fi
  if [ "$STATUS_SEC_COUNT" -eq 0 ]; then
    if [ "$STATUS_SEC_TRUNCATED" -eq 1 ]; then
      printf '  (none among the first %s — there may be more)\n' "$STATUS_LIMIT"
    else
      printf '  (none)\n'
    fi
    return 0
  fi
  while [ "$i" -lt "$STATUS_SEC_COUNT" ]; do
    printf '  %s#%s  %s\n' "${STATUS_SEC_REPO[i]}" "${STATUS_SEC_NUMBER[i]}" "${STATUS_SEC_TITLE[i]}"
    i=$((i + 1))
  done
  STATUS_HAD_ROWS=1
  [ "$STATUS_SEC_TRUNCATED" -eq 0 ] \
    || printf '  (showing the first %s — there may be more)\n' "$STATUS_LIMIT"
}

cmd_status() {
  local owner=${1:-${TENDER_OWNER:-}} native
  [ -n "$owner" ] || die "give an owner: tender status <owner>  (or set TENDER_OWNER)"

  STATUS_FAILED=0

  status_q_ready "$owner"
  status_text "ready to pick up" "$(status_cmd)"
  if [ "$STATUS_HAD_ROWS" -eq 1 ]; then
    printf '  (blocked issues are counted here — the developer skips them)\n'
  fi

  status_q_review "$owner"
  status_text "waiting for review" "$(status_cmd)"
  [ -n "$REVIEWER" ] \
    || printf '  (approximate — set TENDER_REVIEWER to your reviewer login for the exact queue)\n'

  status_q_approved "$owner"
  native=$(status_cmd)
  status_q_approved_label "$owner"
  status_text "approved, waiting for merge" "$native" "$(status_cmd)"

  status_q_decisions "$owner"
  status_text "waiting on you" "$(status_cmd)"

  throttle_status_section "$owner"   # per local project — lib/throttle.sh

  if [ "$STATUS_FAILED" -ne 0 ]; then
    printf '\nSome questions could not be asked — this board is incomplete.\n' >&2
    return 1
  fi
  return 0
}
