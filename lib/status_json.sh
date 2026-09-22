#!/usr/bin/env bash
# `tender status [owner] --json [--since <time>]` — the board `tender status`
# prints, as one JSON object, for a program that shows it (app issue #10, "what
# happened since you were away"). Owner decision 2026-09-22: the GitHub side
# of that view comes from here, not from the app — a GUI building its own `gh`
# searches would be a second board, drifting from this one.
#
# It asks exactly the questions the text board asks, through the same engine:
# the questions, the gh call and the reading of its answer are lib/status.sh.
# This file only adds what the text board does not have — the --since date
# filter, the JSON rendering, and `merged`.
#
# Sourced by bin/tender on demand, for `status` only, after lib/status.sh:
# status_dispatch() is also what sends a plain `tender status` on to
# cmd_status().
#
# Needs from bin/tender: die(); from lib/status.sh: cmd_status(),
#   status_q_*(), status_cmd(), status_section(), STATUS_SEC_*,
#   STATUS_FAILED; json_escape() (lib/json.sh)
# Provides to it:     status_dispatch()

status_usage() {
  cat <<'EOF'
Usage:
  tender status [owner]                         the board, as text
  tender status [owner] --json                  the same board, as one JSON object
  tender status [owner] --json --since <time>   only what changed since <time>

  <owner> defaults to TENDER_OWNER. <time> is ISO-8601 UTC with a date and
  a time: 2026-09-22T08:00:00Z, also with fractional seconds
  (2026-09-22T08:00:00.000Z) or +00:00 instead of Z. It is handed to gh — and
  echoed as "since" — as YYYY-MM-DDTHH:MM:SSZ, fractions dropped. Any other
  offset, or a date alone, is refused.

JSON sections — each {"ok": true, "truncated": false, "items": [...]}, or
{"ok": false, "error": "<first line of gh's error>"} when it could not be
asked (never an empty list):
  waiting_on_you       open issues and PRs labelled needs-decision
  approved             open PRs approved — natively, or by the `approved` label
                       (single-account mode, see roles/reviewer.md)
  waiting_for_review   as on the text board (TENDER_REVIEWER, or the approximation)
  ready                open issues labelled ready, not needs-decision
  merged               only with --since: PRs merged at or after <time>

An item is {"repo", "number", "title", "url", "updated_at"}, plus "kind"
("issue" or "pr") in waiting_on_you and "merged_at" in merged. The top level
also carries "owner", "since" (or null) and "generated_at".

--since keeps what was *updated* at or after <time>. That approximates
"changed since": a new label or a comment counts as an update, and so does
anything else that touches the item — it is not a list of events.

Each search asks for at most 100 results, as on the text board. A section
whose search came back with exactly 100 has "truncated": true — there may be
more, which the text board says as "(showing the first 100 …)".

Exit status: 0 when every section could be asked, 1 when any could not,
2 for a usage error (--since without --json, a malformed <time>).
EOF
}

# Parses status's arguments and runs the text board or the JSON one. Without
# --json nothing differs from before: cmd_status() gets the owner, and owner
# resolution, output and exit codes are its own.
status_dispatch() {
  local owner="" json=0 since="" have_since=0
  while [ $# -gt 0 ]; do
    case $1 in
      -h|--help) status_usage; exit 0 ;;
      --json) json=1 ;;
      --since)
        [ $# -ge 2 ] || { status_usage >&2; exit 2; }
        since=$2 have_since=1
        shift
        ;;
      --since=*) since=${1#--since=} have_since=1 ;;
      -*) printf 'tender: unknown option %s\n' "$1" >&2; status_usage >&2; exit 2 ;;
      *) [ -n "$owner" ] || owner=$1 ;;
    esac
    shift
  done
  if [ "$json" -eq 0 ]; then
    [ "$have_since" -eq 0 ] || die "--since needs --json (see tender status --help)" 2
    cmd_status "$owner"
    return
  fi
  owner=${owner:-${TENDER_OWNER:-}}
  [ -n "$owner" ] || die "give an owner: tender status <owner> --json  (or set TENDER_OWNER)"
  if [ "$have_since" -eq 1 ]; then
    since=$(status_json_normal_time "$since") \
      || die "--since '$since' is not an ISO-8601 UTC time (e.g. 2026-09-22T08:00:00Z)" 2
  fi
  status_json "$owner" "$since"
}

# $1 as YYYY-MM-DDTHH:MM:SSZ — the shape gh's date filters and GitHub's own
# timestamps use — or rc 1. Accepted on the way in: Z or +00:00, and
# fractional seconds (JavaScript's toISOString() writes .000Z), which are
# dropped: the search qualifiers take whole seconds. Anything else, another
# offset included, is refused rather than converted — a local time guessed
# wrong would silently shift the whole since-view.
#
# The shape is checked first, then the date itself by a round trip through
# date(1) (GNU, then BSD/macOS): BSD date quietly rolls 2026-02-30 over to
# March, so "it parsed" is not enough — it has to come back unchanged.
status_json_normal_time() {
  local t=$1 frac back fmt='%Y-%m-%dT%H:%M:%SZ'
  case $t in
    *Z) t=${t%Z} ;;
    *+00:00) t=${t%+00:00} ;;
    *) return 1 ;;
  esac
  case $t in
    *.*)
      frac=${t#*.}
      case $frac in ''|*[!0-9]*) return 1 ;; esac
      t=${t%%.*} ;;
  esac
  t="${t}Z"
  case $t in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  back=$(date -u -d "$t" +"$fmt" 2>/dev/null \
         || date -u -j -f "$fmt" "$t" +"$fmt" 2>/dev/null) || return 1
  [ "$back" = "$t" ] || return 1
  printf '%s' "$t"
}

# One section as `"key":{…}`, printed: asks it through status_section()
# (lib/status.sh) with the commands given after $1 (key) and $2 (the name
# the extra value carries in an item, "" for none).
status_json_section() {
  local key=$1 extra_key=$2 i=0 items="" item number
  shift 2
  status_section "$@"
  if [ "$STATUS_SEC_OK" -eq 0 ]; then
    printf '"%s":{"ok":false,"error":"%s"}' "$key" "$(json_escape "$STATUS_SEC_ERROR")"
    return 0
  fi
  while [ "$i" -lt "$STATUS_SEC_COUNT" ]; do
    number=${STATUS_SEC_NUMBER[i]}
    case $number in ''|*[!0-9]*) number=null ;; esac
    item=$(printf '{"repo":"%s","number":%s,"title":"%s","url":"%s","updated_at":"%s"' \
      "$(json_escape "${STATUS_SEC_REPO[i]}")" "$number" "$(json_escape "${STATUS_SEC_TITLE[i]}")" \
      "$(json_escape "${STATUS_SEC_URL[i]}")" "$(json_escape "${STATUS_SEC_UPDATED[i]}")")
    [ -z "$extra_key" ] || item="$item,\"$extra_key\":\"$(json_escape "${STATUS_SEC_EXTRA[i]}")\""
    items="${items:+$items,}$item}"
    i=$((i + 1))
  done
  if [ "$STATUS_SEC_TRUNCATED" -eq 1 ]; then item=true; else item=false; fi
  printf '"%s":{"ok":true,"truncated":%s,"items":[%s]}' "$key" "$item" "$items"
}

# The whole board for owner $1, changed since $2 (empty: everything).
#
# The date filters are gh's own, not a local filter over a full listing:
# `gh search issues|prs --updated ">=T"` and `gh search prs --merged-at ">=T"`
# (gh 2.100.0, `--help`: "--updated date  Filter on last updated at date",
# "--merged-at date  Filter on merged at date"; `--merged` is only a boolean
# there).
status_json() {
  local owner=$1 since=$2 now native
  local -a upd
  upd=()
  [ -z "$since" ] || upd=(--updated ">=$since")
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  STATUS_FAILED=0

  printf '{"owner":"%s","since":%s,"generated_at":"%s",' "$(json_escape "$owner")" \
    "$([ -n "$since" ] && printf '"%s"' "$(json_escape "$since")" || printf null)" "$now"

  status_q_decisions "$owner"
  status_json_section waiting_on_you kind "$(status_cmd ${upd[@]+"${upd[@]}"})"
  printf ','
  status_q_approved "$owner"
  native=$(status_cmd ${upd[@]+"${upd[@]}"})
  status_q_approved_label "$owner"
  status_json_section approved "" "$native" "$(status_cmd ${upd[@]+"${upd[@]}"})"
  printf ','
  status_q_review "$owner"
  status_json_section waiting_for_review "" "$(status_cmd ${upd[@]+"${upd[@]}"})"
  printf ','
  status_q_ready "$owner"
  status_json_section ready "" "$(status_cmd ${upd[@]+"${upd[@]}"})"
  if [ -n "$since" ]; then
    printf ','
    status_q_merged "$owner" "$since"
    status_json_section merged merged_at "$(status_cmd)"
  fi
  printf '}\n'
  [ "$STATUS_FAILED" -eq 0 ]
}
