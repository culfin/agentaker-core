#!/usr/bin/env bash
# `tender status [owner] --json [--since <time>]` — the board `tender status`
# prints, as one JSON object, for a program that shows it (app issue #10, "what
# happened since you were away"). Owner decision 2026-09-22: the GitHub side
# of that view comes from here, not from the app — a GUI building its own `gh`
# searches would be a second board, drifting from this one.
#
# It asks exactly the questions the text board asks: the qualifiers and the
# filters of each section are defined once, by the status_q_*() functions and
# STATUS_NOT_HELD / STATUS_NOT_BOT in bin/tender. This file only adds what the
# text board does not have — the --since date filter, the fields an item
# carries, the `approved` label of single-account mode, and `merged`.
#
# Sourced by bin/tender on demand, for `status` only: status_dispatch() is
# also what sends a plain `tender status` on to cmd_status(), unchanged.
#
# Needs from bin/tender: die(), REVIEWER, cmd_status(), status_q_*(),
#   STATUS_Q, STATUS_NOT_HELD, STATUS_NOT_BOT; json_escape() (lib/json.sh)
# Provides to it:     status_dispatch()

status_usage() {
  cat <<'EOF'
Usage:
  tender status [owner]                         the board, as text
  tender status [owner] --json                  the same board, as one JSON object
  tender status [owner] --json --since <time>   only what changed since <time>

  <owner> defaults to TENDER_OWNER. <time> is ISO-8601 UTC, exactly
  YYYY-MM-DDTHH:MM:SSZ (e.g. 2026-09-22T08:00:00Z); anything else is refused.

JSON sections — each {"ok": true, "items": [...]}, or {"ok": false, "error":
"<first line of gh's error>"} when it could not be asked (never an empty list):
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
anything else that touches the item — it is not a list of events. Each
section holds at most gh's default 30 results, as on the text board.

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
    status_json_valid_time "$since" \
      || die "--since '$since' is not ISO-8601 UTC (YYYY-MM-DDTHH:MM:SSZ, e.g. 2026-09-22T08:00:00Z)" 2
  fi
  status_json "$owner" "$since"
}

# rc 0 if $1 is a real ISO-8601 UTC time in exactly the shape gh's date
# filters and GitHub's own timestamps use. The shape is checked first, then
# the date itself by a round trip through date(1) (GNU, then BSD/macOS):
# BSD date quietly rolls 2026-02-30 over to March, so "it parsed" is not
# enough — it has to come back unchanged.
status_json_valid_time() {
  local t=$1 back fmt='%Y-%m-%dT%H:%M:%SZ'
  case $t in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  back=$(date -u -d "$t" +"$fmt" 2>/dev/null \
         || date -u -j -f "$fmt" "$t" +"$fmt" 2>/dev/null) || return 1
  [ "$back" = "$t" ]
}

# The --jq program that turns gh's listing into one record per item, for
# filter $1 (a jq expression, or "." for none) and extra field $2 (a jq
# expression yielding a string). A record starts with \x1e and its fields are
# separated by \x1f, so a title may hold quotes, tabs, backslashes or newlines
# and still arrive intact: it is escaped once, by json_escape(), not by jq.
# The separator comes first because gh ends every output with a newline,
# which the reader below drops from the end of each record — where the last
# field is a date or a kind, never text that could end in one.
status_json_program() {
  printf '.[] | %s | "\\u001e" + ([.repository.name, (.number | tostring), .title, (.url // ""), (.updatedAt // ""), %s] | map(. // "") | join("\\u001f"))' "$1" "$2"
}

# Runs `gh "$@"` and appends its records to STATUS_JSON_ITEMS as JSON items,
# skipping any repo#number already in STATUS_JSON_SEEN (the two queries of
# `approved` can find the same PR). $1 is the name the extra field carries in
# an item ("" for none), the rest is the gh command. rc 1 = could not ask,
# with gh's first stderr line in STATUS_JSON_ERROR. stderr is kept apart from
# stdout, as in throttle_count(): a gh warning is not a record.
STATUS_JSON_ITEMS="" STATUS_JSON_SEEN="" STATUS_JSON_ERROR=""
status_json_collect() {
  local extra_key=$1 out rc errfile rec repo number title url updated extra item
  shift
  STATUS_JSON_ERROR=""
  if ! command -v gh >/dev/null 2>&1; then STATUS_JSON_ERROR="gh is not installed"; return 1; fi
  errfile=$(mktemp) || { STATUS_JSON_ERROR="cannot create a temporary file"; return 1; }
  out=$(gh "$@" 2>"$errfile")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    STATUS_JSON_ERROR=$(head -1 "$errfile")
    STATUS_JSON_ERROR=${STATUS_JSON_ERROR:-gh exited $rc}
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"
  out=${out#*$'\x1e'}   # whatever precedes the first record is not one
  [ -n "$out" ] || return 0
  while IFS= read -r -d $'\x1e' rec || [ -n "$rec" ]; do
    rec=${rec%$'\n'}
    IFS=$'\x1f' read -r -d '' repo number title url updated extra <<<"$rec"
    extra=${extra%$'\n'}   # the <<< above adds one
    updated=${updated%$'\n'}
    case "$STATUS_JSON_SEEN" in *"|$repo#$number|"*) continue ;; esac
    STATUS_JSON_SEEN="$STATUS_JSON_SEEN|$repo#$number|"
    case $number in ''|*[!0-9]*) number=null ;; esac
    item=$(printf '{"repo":"%s","number":%s,"title":"%s","url":"%s","updated_at":"%s"' \
      "$(json_escape "$repo")" "$number" "$(json_escape "$title")" \
      "$(json_escape "$url")" "$(json_escape "$updated")")
    [ -z "$extra_key" ] || item="$item,\"$extra_key\":\"$(json_escape "$extra")\""
    STATUS_JSON_ITEMS="${STATUS_JSON_ITEMS:+$STATUS_JSON_ITEMS,}$item}"
  done <<<"$out"
  return 0
}

# One section of the board as `"key":{…}`, printed. $1 key, $2 extra key,
# then one or more gh commands, each a single string of words separated by
# \x1f (so that a --jq program with spaces stays one argument) — all of
# them must be asked for the section to be ok. Sets STATUS_JSON_FAILED on a
# could-not-ask.
STATUS_JSON_FAILED=0
status_json_section() {
  local key=$1 extra_key=$2 cmd err=""
  local -a argv
  shift 2
  STATUS_JSON_ITEMS="" STATUS_JSON_SEEN=""
  for cmd in "$@"; do
    IFS=$'\x1f' read -r -a argv <<<"$cmd"
    status_json_collect "$extra_key" "${argv[@]}" || { err=$STATUS_JSON_ERROR; break; }
  done
  if [ -n "$err" ]; then
    STATUS_JSON_FAILED=1
    printf '"%s":{"ok":false,"error":"%s"}' "$key" "$(json_escape "$err")"
  else
    printf '"%s":{"ok":true,"items":[%s]}' "$key" "$STATUS_JSON_ITEMS"
  fi
}

# STATUS_Q (set by a status_q_*() in bin/tender) plus the given extra words,
# joined with \x1f into the one-string form status_json_section() takes.
status_json_cmd() {
  local IFS=$'\x1f'
  printf '%s' "${STATUS_Q[*]}${*:+$IFS$*}"
}

# The two questions only the JSON board asks, beside the text board's own in
# bin/tender: a PR cleared by label (the `approved` of single-account mode —
# not draft, labelled; roles/reviewer.md), and what was merged since $2.
status_q_approved_label() { STATUS_Q=(search prs --owner "$1" --state open --draft=false --label approved); }
status_q_merged()         { STATUS_Q=(search prs --owner "$1" --merged-at ">=$2"); }

# The whole board for owner $1, changed since $2 (empty: everything).
#
# The date filters are gh's own, not a local filter over a full listing:
# `gh search issues|prs --updated ">=T"` and `gh search prs --merged-at ">=T"`
# (gh 2.100.0, `--help`: "--updated date  Filter on last updated at date",
# "--merged-at date  Filter on merged at date"; `--merged` is only a boolean
# there). gh search prs has no mergedAt JSON field, so merged_at is closedAt,
# which for a merged PR is the moment it was merged.
status_json() {
  local owner=$1 since=$2 now fields='repository,number,title,url,updatedAt'
  local -a upd
  upd=()
  [ -z "$since" ] || upd=(--updated ">=$since")
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  STATUS_JSON_FAILED=0

  printf '{"owner":"%s","since":%s,"generated_at":"%s",' "$(json_escape "$owner")" \
    "$([ -n "$since" ] && printf '"%s"' "$(json_escape "$since")" || printf null)" "$now"

  # Issues and PRs: the text board asks for issues only.
  status_q_decisions "$owner"
  status_json_section waiting_on_you kind \
    "$(status_json_cmd --include-prs ${upd[@]+"${upd[@]}"} --json "$fields,isPullRequest" \
       --jq "$(status_json_program . 'if .isPullRequest then "pr" else "issue" end')")"
  printf ','

  # Natively approved, or — single-account mode, where --approve is locked
  # (roles/reviewer.md) — cleared with the label: not draft, `approved`.
  local native label
  status_q_approved "$owner"
  native=$(status_json_cmd ${upd[@]+"${upd[@]}"} --json "$fields" --jq "$(status_json_program . '""')")
  status_q_approved_label "$owner"
  label=$(status_json_cmd ${upd[@]+"${upd[@]}"} --json "$fields" --jq "$(status_json_program . '""')")
  status_json_section approved "" "$native" "$label"
  printf ','

  status_q_review "$owner"
  status_json_section waiting_for_review "" \
    "$(status_json_cmd ${upd[@]+"${upd[@]}"} --json "$fields,author" \
       --jq "$(status_json_program "$STATUS_NOT_BOT" '""')")"
  printf ','

  status_q_ready "$owner"
  status_json_section ready "" \
    "$(status_json_cmd ${upd[@]+"${upd[@]}"} --json "$fields,labels" \
       --jq "$(status_json_program "$STATUS_NOT_HELD" '""')")"

  if [ -n "$since" ]; then
    printf ','
    status_q_merged "$owner" "$since"
    status_json_section merged merged_at \
      "$(status_json_cmd --json "$fields,closedAt" --jq "$(status_json_program . '(.closedAt // "")')")"
  fi
  printf '}\n'
  [ "$STATUS_JSON_FAILED" -eq 0 ]
}
