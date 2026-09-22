#!/usr/bin/env bash
# `tender status` through its shared engine (lib/status.sh): the text board,
# and `tender status --json [--since <time>]` (lib/status_json.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
TENDER="$PWD/bin/tender"
make_sandbox
STUB=$(mktemp -d)
trap 'rm -rf "$SANDBOX" "$STUB"' EXIT
export GH_CALLS="$STUB/calls"

# Everything below runs the --jq programs for real, and parses the output
# with a real JSON parser — both need jq. CI has it (ubuntu-latest ships it).
if ! command -v jq >/dev/null 2>&1; then
  echo "  skip (jq not installed — the --jq programs and the JSON output need a real jq)"
  summary
  exit $?
fi

# A gh stand-in. It logs its argv one argument per line, each in <…>, and a
# "---" after every call — so an argument split in two, or two merged into
# one, shows up in the log instead of reading the same as "$*" would. It
# picks a canned listing by the qualifiers it was asked with, and applies the
# --jq program to it with jq -r — the way gh prints --jq strings, raw, one
# per line.
#   FAIL_ON  a glob over "$*": fail like gh does, message on stderr, rc 1
#   GH_WARN  print a warning on stderr after the listing
#   GH_DATA  use this listing for every call
#   GH_RAW   print this instead of running the --jq program at all
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
printf '<%s>\n' "$@" >> "$GH_CALLS"
echo --- >> "$GH_CALLS"
q=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && q=$a; prev=$a; done
if [ -n "${FAIL_ON:-}" ]; then
  case "$*" in $FAIL_ON) printf 'HTTP 502: bad gateway\nsecond line\n' >&2; exit 1 ;; esac
fi
if [ -n "${GH_RAW+x}" ]; then printf '%s' "$GH_RAW"; exit 0; fi
case "$*" in
  *"--label ready"*) data='[{"repository":{"name":"acme"},"number":1,"title":"free","url":"https://x/acme/issues/1","updatedAt":"2026-09-22T09:00:00Z","labels":[{"name":"ready"}]},{"repository":{"name":"acme"},"number":2,"title":"held","url":"https://x/acme/issues/2","updatedAt":"2026-09-22T09:00:00Z","labels":[{"name":"ready"},{"name":"needs-decision"}]}]' ;;
  *"--review approved"*) data='[{"repository":{"name":"acme"},"number":5,"title":"approved one","url":"https://x/acme/pull/5","updatedAt":"2026-09-22T09:05:00Z"}]' ;;
  *"--label approved"*) data='[{"repository":{"name":"acme"},"number":5,"title":"approved one","url":"https://x/acme/pull/5","updatedAt":"2026-09-22T09:05:00Z"},{"repository":{"name":"acme"},"number":6,"title":"cleared by label","url":"https://x/acme/pull/6","updatedAt":"2026-09-22T09:06:00Z"}]' ;;
  *"needs-decision"*) data='[{"repository":{"name":"web"},"number":7,"title":"decide me","url":"https://x/web/issues/7","updatedAt":"2026-09-22T09:07:00Z","isPullRequest":false},{"repository":{"name":"web"},"number":8,"title":"a PR on hold","url":"https://x/web/pull/8","updatedAt":"2026-09-22T09:08:00Z","isPullRequest":true}]' ;;
  *"--merged-at"*) data='[{"repository":{"name":"web"},"number":9,"title":"shipped","url":"https://x/web/pull/9","updatedAt":"2026-09-22T10:01:00Z","closedAt":"2026-09-22T10:00:00Z"}]' ;;
  *) data='[{"repository":{"name":"acme"},"number":3,"title":"review me","url":"https://x/acme/pull/3","updatedAt":"2026-09-22T09:03:00Z","author":{"login":"alice"},"labels":[]},{"repository":{"name":"acme"},"number":4,"title":"bump","url":"https://x/acme/pull/4","updatedAt":"2026-09-22T09:04:00Z","author":{"login":"dependabot[bot]"},"labels":[]},{"repository":{"name":"acme"},"number":6,"title":"cleared by label","url":"https://x/acme/pull/6","updatedAt":"2026-09-22T09:06:00Z","author":{"login":"alice"},"labels":[{"name":"approved"}]},{"repository":{"name":"acme"},"number":12,"title":"a question on it","url":"https://x/acme/pull/12","updatedAt":"2026-09-22T09:12:00Z","author":{"login":"alice"},"labels":[{"name":"needs-decision"}]}]' ;;
esac
[ -z "${GH_DATA:-}" ] || data=$GH_DATA
printf '%s' "$data" | jq -r "$q"
# After the listing, so that stderr mixed into stdout would land in a record.
[ -z "${GH_WARN:-}" ] || echo "warning: a gh notice on stderr" >&2
exit 0
STUBEOF
chmod +x "$STUB/gh"
run() { PATH="$STUB:$PATH" "$TENDER" "$@"; }
# The value of jq expression $1 over JSON $2, compact.
jqc() { printf '%s' "$2" | jq -c "$1" 2>&1; }

echo "tender status: the text board, exactly"
# The whole output and every gh argument, pinned. Against bin/tender at
# 89824dd (before the shared engine) the output differs in exactly what the
# review of app issue #10 asked for — a PR on hold under "waiting on you", a
# label-cleared PR under "approved" (once) and not under "waiting for
# review" — and the argv in --include-prs, --limit 100, the labels field and
# the record-printing --jq program.
EXPECTED_APPROX=$(cat <<'EOF'
ready to pick up:
  acme#1  free
  (blocked issues are counted here — the developer skips them)
waiting for review:
  acme#3  review me
  acme#12  a question on it
  (approximate — set TENDER_REVIEWER to your reviewer login for the exact queue)
approved, waiting for merge:
  acme#5  approved one
  acme#6  cleared by label
waiting on you:
  web#7  decide me
  web#8  a PR on hold
EOF
)
EXPECTED_EXACT=$(cat <<'EOF'
ready to pick up:
  acme#1  free
  (blocked issues are counted here — the developer skips them)
waiting for review:
  acme#3  review me
  acme#12  a question on it
approved, waiting for merge:
  acme#5  approved one
  acme#6  cleared by label
waiting on you:
  web#7  decide me
  web#8  a PR on hold
EOF
)
EXPECTED_CALLS_APPROX=$(cat <<'EOF'
<search>
<issues>
<--owner>
<someowner>
<--state>
<open>
<--label>
<ready>
<--limit>
<100>
<--json>
<repository,number,title,url,updatedAt,labels>
<--jq>
<"\u001d\(length)", (.[] | select(any((.labels // [])[]; .name == "needs-decision") | not) | "\u001e" + ([.repository.name, (.number | tostring), .title, (.url // ""), (.updatedAt // ""), ""] | map((. // "") | tostring | gsub("[\u001d-\u001f]"; "")) | join("\u001f")))>
---
<search>
<prs>
<--owner>
<someowner>
<--state>
<open>
<--draft=false>
<--review>
<none>
<--limit>
<100>
<--json>
<repository,number,title,url,updatedAt,author,labels>
<--jq>
<"\u001d\(length)", (.[] | select(.author.login | test("dependabot") | not) | select(any((.labels // [])[]; .name == "approved") | not) | "\u001e" + ([.repository.name, (.number | tostring), .title, (.url // ""), (.updatedAt // ""), ""] | map((. // "") | tostring | gsub("[\u001d-\u001f]"; "")) | join("\u001f")))>
---
<search>
<prs>
<--owner>
<someowner>
<--state>
<open>
<--review>
<approved>
<--limit>
<100>
<--json>
<repository,number,title,url,updatedAt>
<--jq>
<"\u001d\(length)", (.[] | . | "\u001e" + ([.repository.name, (.number | tostring), .title, (.url // ""), (.updatedAt // ""), ""] | map((. // "") | tostring | gsub("[\u001d-\u001f]"; "")) | join("\u001f")))>
---
<search>
<prs>
<--owner>
<someowner>
<--state>
<open>
<--draft=false>
<--label>
<approved>
<--limit>
<100>
<--json>
<repository,number,title,url,updatedAt>
<--jq>
<"\u001d\(length)", (.[] | . | "\u001e" + ([.repository.name, (.number | tostring), .title, (.url // ""), (.updatedAt // ""), ""] | map((. // "") | tostring | gsub("[\u001d-\u001f]"; "")) | join("\u001f")))>
---
<search>
<issues>
<--owner>
<someowner>
<--state>
<open>
<--label>
<needs-decision>
<--include-prs>
<--limit>
<100>
<--json>
<repository,number,title,url,updatedAt,isPullRequest>
<--jq>
<"\u001d\(length)", (.[] | . | "\u001e" + ([.repository.name, (.number | tostring), .title, (.url // ""), (.updatedAt // ""), if .isPullRequest then "pr" else "issue" end] | map((. // "") | tostring | gsub("[\u001d-\u001f]"; "")) | join("\u001f")))>
---
EOF
)
EXPECTED_CALLS_EXACT=$(cat <<'EOF'
<search>
<issues>
<--owner>
<someowner>
<--state>
<open>
<--label>
<ready>
<--limit>
<100>
<--json>
<repository,number,title,url,updatedAt,labels>
<--jq>
<"\u001d\(length)", (.[] | select(any((.labels // [])[]; .name == "needs-decision") | not) | "\u001e" + ([.repository.name, (.number | tostring), .title, (.url // ""), (.updatedAt // ""), ""] | map((. // "") | tostring | gsub("[\u001d-\u001f]"; "")) | join("\u001f")))>
---
<search>
<prs>
<--owner>
<someowner>
<--state>
<open>
<--draft=false>
<--review-requested>
<rev>
<--limit>
<100>
<--json>
<repository,number,title,url,updatedAt,author,labels>
<--jq>
<"\u001d\(length)", (.[] | select(.author.login | test("dependabot") | not) | select(any((.labels // [])[]; .name == "approved") | not) | "\u001e" + ([.repository.name, (.number | tostring), .title, (.url // ""), (.updatedAt // ""), ""] | map((. // "") | tostring | gsub("[\u001d-\u001f]"; "")) | join("\u001f")))>
---
<search>
<prs>
<--owner>
<someowner>
<--state>
<open>
<--review>
<approved>
<--limit>
<100>
<--json>
<repository,number,title,url,updatedAt>
<--jq>
<"\u001d\(length)", (.[] | . | "\u001e" + ([.repository.name, (.number | tostring), .title, (.url // ""), (.updatedAt // ""), ""] | map((. // "") | tostring | gsub("[\u001d-\u001f]"; "")) | join("\u001f")))>
---
<search>
<prs>
<--owner>
<someowner>
<--state>
<open>
<--draft=false>
<--label>
<approved>
<--limit>
<100>
<--json>
<repository,number,title,url,updatedAt>
<--jq>
<"\u001d\(length)", (.[] | . | "\u001e" + ([.repository.name, (.number | tostring), .title, (.url // ""), (.updatedAt // ""), ""] | map((. // "") | tostring | gsub("[\u001d-\u001f]"; "")) | join("\u001f")))>
---
<search>
<issues>
<--owner>
<someowner>
<--state>
<open>
<--label>
<needs-decision>
<--include-prs>
<--limit>
<100>
<--json>
<repository,number,title,url,updatedAt,isPullRequest>
<--jq>
<"\u001d\(length)", (.[] | . | "\u001e" + ([.repository.name, (.number | tostring), .title, (.url // ""), (.updatedAt // ""), if .isPullRequest then "pr" else "issue" end] | map((. // "") | tostring | gsub("[\u001d-\u001f]"; "")) | join("\u001f")))>
---
EOF
)
: > "$GH_CALLS"
out=$(TENDER_REVIEWER= run status someowner 2>&1); rc_a=$?
calls_a=$(cat "$GH_CALLS")
: > "$GH_CALLS"
out_b=$(TENDER_REVIEWER=rev run status someowner 2>&1); rc_b=$?
calls_b=$(cat "$GH_CALLS")
check "approximate queue: the whole board" "$EXPECTED_APPROX" "$out"
check "reviewer login: the whole board" "$EXPECTED_EXACT" "$out_b"
check "approximate queue: every gh argument, one by one" "$EXPECTED_CALLS_APPROX" "$calls_a"
check "reviewer login: every gh argument, one by one" "$EXPECTED_CALLS_EXACT" "$calls_b"
check "exit status 0 both times" "0 0" "$rc_a $rc_b"
contains "waiting on you lists a PR on hold" "web#8  a PR on hold" "$out"
lacks "a label-cleared PR is not waiting for review" "$(printf 'waiting for review:\n  acme#3  review me\n  acme#6')" "$out"
contains "a PR with a question stays in the review queue" "acme#12  a question on it" "$out"
check "a PR both approved and labelled is listed once" "1" "$(printf '%s\n' "$out" | grep -c 'acme#5  approved one')"
out=$(FAIL_ON='*' TENDER_REVIEWER= run status someowner 2>/dev/null); rc=$?
check "a failed query exits 1" "1" "$rc"
contains "and says what gh said, first line" "could not ask: HTTP 502: bad gateway" "$out"

echo "tender status --json: the board"
: > "$GH_CALLS"
json=$(TENDER_REVIEWER= run status someowner --json); rc=$?
check "exits 0 when every section was asked" "0" "$rc"
check "is one valid JSON object" '"object"' "$(jqc type "$json")"
check "carries the owner" '"someowner"' "$(jqc .owner "$json")"
check "since is null without --since" "null" "$(jqc .since "$json")"
check "generated_at is ISO-8601 UTC" "true" \
  "$(jqc '.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$json")"
check "exactly the four sections, merged only with --since" \
  '["approved","generated_at","owner","ready","since","waiting_for_review","waiting_on_you"]' "$(jqc keys "$json")"
check "every section: ok, not truncated" '[[true,false],[true,false],[true,false],[true,false]]' \
  "$(jqc '[.waiting_on_you, .approved, .waiting_for_review, .ready] | map([.ok, .truncated])' "$json")"
check "waiting_on_you: issues and PRs, each with its kind" '["web#7 issue","web#8 pr"]' \
  "$(jqc '[.waiting_on_you.items[] | "\(.repo)#\(.number) \(.kind)"]' "$json")"
check "an item carries repo, number, title, url, updated_at" \
  '{"repo":"web","number":7,"title":"decide me","url":"https://x/web/issues/7","updated_at":"2026-09-22T09:07:00Z","kind":"issue"}' \
  "$(jqc '.waiting_on_you.items[0]' "$json")"
check "approved: natively approved and label-cleared, each once" "[5,6]" "$(jqc '[.approved.items[].number]' "$json")"
check "waiting_for_review: no dependabot, no label-cleared PR, the PR with a question kept" "[3,12]" \
  "$(jqc '[.waiting_for_review.items[].number]' "$json")"
check "ready: an issue on hold (needs-decision) is not ready" "[1]" "$(jqc '[.ready.items[].number]' "$json")"
calls=$(cat "$GH_CALLS")
lacks "without --since, no date filter" "<--updated>" "$calls"
lacks "without --since, nothing about merges" "<--merged-at>" "$calls"
check "every question asks for 100 results" "5" "$(grep -A1 -x '<--limit>' "$GH_CALLS" | grep -c -x '<100>')"

: > "$GH_CALLS"
json=$(TENDER_REVIEWER=somereviewer run status someowner --json)
contains "with TENDER_REVIEWER, the review queue is that login's" \
  "$(printf '<--review-requested>\n<somereviewer>')" "$(cat "$GH_CALLS")"
check "and it leaves label-cleared PRs out as well" "[3,12]" "$(jqc '[.waiting_for_review.items[].number]' "$json")"

echo "tender status --json --since: gh's own date filters"
: > "$GH_CALLS"
T=2026-09-22T08:00:00Z
json=$(TENDER_REVIEWER= run status someowner --json --since "$T"); rc=$?
check "exits 0" "0" "$rc"
check "since is echoed" "\"$T\"" "$(jqc .since "$json")"
check "every open-work question carries --updated >=T" "5" \
  "$(grep -A1 -x '<--updated>' "$GH_CALLS" | grep -c -x "<>=$T>")"
contains "merged asks gh for --merged-at >=T, and nothing else about time" \
  "$(printf '<--owner>\n<someowner>\n<--merged-at>\n<>=%s>\n<--limit>' "$T")" "$(cat "$GH_CALLS")"
check "merged: its items carry merged_at" '["web#9 2026-09-22T10:00:00Z"]' \
  "$(jqc '[.merged.items[] | "\(.repo)#\(.number) \(.merged_at)"]' "$json")"
: > "$GH_CALLS"
run status someowner --json --since="$T" >/dev/null
check "--since=T works as well" "6" "$(grep -c -x "<>=$T>" "$GH_CALLS")"

echo "tender status --json --since: what is normalised, what is refused"
for good in "2026-09-22T08:00:00.000Z" "2026-09-22T08:00:00.5Z" "2026-09-22T08:00:00+00:00" \
            "2026-09-22T08:00:00.123+00:00"; do
  : > "$GH_CALLS"
  json=$(run status someowner --json --since "$good"); rc=$?
  check "--since $good: exits 0" "0" "$rc"
  check "--since $good: echoed as $T" "\"$T\"" "$(jqc .since "$json")"
  check "--since $good: handed to gh as $T, six times" "6" "$(grep -c -x "<>=$T>" "$GH_CALLS")"
done
for bad in 2026-09-22 2026-09-22T08:00:00+02:00 2026-09-22T08:00:00-05:00 2026-09-22T08:00:00-00:00 \
           2026-09-22T08:00:00 2026-09-22T08:00Z 2026-09-22T08:00:00.Z 2026-09-22T08:00:00.1xZ \
           2026-02-30T00:00:00Z 2026-13-01T00:00:00Z yesterday ""; do
  : > "$GH_CALLS"
  out=$(run status someowner --json --since "$bad" 2>&1); rc=$?
  check "--since '$bad' exits 2" "2" "$rc"
  check "--since '$bad' asks gh nothing" "" "$(cat "$GH_CALLS")"
done
contains "the refusal says what it expects" "is not an ISO-8601 UTC time" "$out"
out=$(run status someowner --json --since 2026-02-30T00:00:00Z 2>&1)
contains "the refusal names the value it refused" "--since '2026-02-30T00:00:00Z' is not" "$out"

echo "tender status: usage errors"
out=$(run status someowner --json --since 2>&1); check "--since without a value exits 2" "2" "$?"
: > "$GH_CALLS"
out=$(run status someowner --since "$T" 2>&1); check "--since without --json exits 2" "2" "$?"
contains "and says --json is what it needs" "--since needs --json" "$out"
check "and asks gh nothing" "" "$(cat "$GH_CALLS")"
out=$(run status someowner --jsno 2>&1); check "an unknown option exits 2" "2" "$?"
out=$(run status --help); check "status --help exits 0" "0" "$?"
contains "status --help says --since is an approximation" "approximates" "$out"
contains "status --help names the truncation flag" '"truncated": true' "$out"
out=$(TENDER_OWNER= run status --json 2>&1); check "--json with no owner exits 1" "1" "$?"
contains "and asks for one" "give an owner" "$out"
json=$(TENDER_OWNER=envowner run status --json)
check "--json takes the owner from TENDER_OWNER" '"envowner"' "$(jqc .owner "$json")"

echo "tender status --json: a section that could not be asked"
for pair in "waiting_on_you:*--label needs-decision*" "approved:*--review approved*" \
            "approved:*--label approved*" "waiting_for_review:*--review none*" \
            "ready:*--label ready*" "merged:*--merged-at*"; do
  key=${pair%%:*} glob=${pair#*:}
  json=$(FAIL_ON=$glob TENDER_REVIEWER= run status someowner --json --since "$T" 2>/dev/null); rc=$?
  check "$key ($glob fails): exit 1" "1" "$rc"
  check "$key ($glob fails): still valid JSON" '"object"' "$(jqc type "$json")"
  check "$key ($glob fails): ok false, gh's first line, no items" \
    '{"ok":false,"error":"HTTP 502: bad gateway"}' "$(jqc ".$key" "$json")"
  check "$key ($glob fails): the other sections are still ok" "4" \
    "$(jqc "[to_entries[] | select(.value | type == \"object\") | select(.key != \"$key\") | .value.ok] | map(select(.)) | length" "$json")"
done

echo "tender status: output that is not records"
export GH_RAW="  demo#1  a row in some other shape"
json=$(run status someowner --json); rc=$?
check "--json: exits 1" "1" "$rc"
check "--json: the section is ok false, saying what came back" \
  '{"ok":false,"error":"unexpected gh output:   demo#1  a row in some other shape"}' "$(jqc .ready "$json")"
out=$(run status someowner 2>/dev/null); rc=$?
check "text: exits 1" "1" "$rc"
contains "text: could not ask, saying what came back" "could not ask: unexpected gh output:" "$out"
lacks "text: it is not shown as a row" "$(printf 'ready to pick up:\n  demo#1')" "$out"
export GH_RAW=""
json=$(run status someowner --json); rc=$?
check "empty output: exits 1 — the program always prints a size" "1" "$rc"
check "empty output: not ok" '{"ok":false,"error":"unexpected gh output: nothing at all"}' "$(jqc .ready "$json")"
export GH_RAW=$'\x1d3\n<html>'
json=$(run status someowner --json)
check "3 announced, none sent: not ok" "false" "$(jqc .approved.ok "$json")"
unset GH_RAW

echo "tender status: a section at the limit says it may be cut"
# 100 results come back — the limit — and the held filter keeps 99 of them:
# the cut is judged on what gh returned, not on what survived the filter.
GH_DATA=$(jq -nc '[range(100) | {repository:{name:"acme"}, number:(.+1), title:"t\(.)", url:"u", updatedAt:"d", author:{login:"a"}, isPullRequest:false, closedAt:"d", labels:(if . == 0 then [{name:"needs-decision"}] else [] end)}]')
export GH_DATA
json=$(run status someowner --json --since "$T")
check "at the limit: every section truncated" '[true,true,true,true,true]' \
  "$(jqc '[.waiting_on_you, .approved, .waiting_for_review, .ready, .merged] | map(.truncated)' "$json")"
check "and still lists what it got" "99" "$(jqc '.ready.items | length' "$json")"
out=$(run status someowner 2>&1)
check "text: one line under each of the four sections" "4" \
  "$(printf '%s\n' "$out" | grep -c -x '  (showing the first 100 — there may be more)')"
GH_DATA=$(jq -nc '[range(99) | {repository:{name:"acme"}, number:(.+1), title:"t", url:"u", updatedAt:"d", labels:[]}]')
json=$(run status someowner --json)
check "at 99: not truncated" "false" "$(jqc .ready.truncated "$json")"
out=$(run status someowner 2>&1)
lacks "text at 99: no truncation line" "showing the first" "$out"
GH_DATA=$(jq -nc '[range(100) | {repository:{name:"acme"}, number:(.+1), title:"t", url:"u", updatedAt:"d", labels:[{name:"needs-decision"}]}]')
out=$(run status someowner 2>&1)
contains "text: all 100 filtered out still says it may be cut" "$(printf 'ready to pick up:\n  (none among the first 100 — there may be more)')" "$out"
unset GH_DATA

echo "tender status --json: titles that JSON has to escape"
GH_DATA='[{"repository":{"name":"acme"},"number":11,"title":"say \"hi\" \\ or\nnot\tnow","url":"https://x/11","updatedAt":"2026-09-22T09:00:00Z","isPullRequest":false,"labels":[{"name":"ready"}],"author":{"login":"a"},"closedAt":"2026-09-22T09:00:00Z"}]'
export GH_DATA
json=$(run status someowner --json --since "$T"); rc=$?
check "exits 0" "0" "$rc"
check "parses" '"object"' "$(jqc type "$json")"
check "the title comes back exactly: quotes, backslash, newline, tab" \
  "$(printf 'say "hi" \\ or\nnot\tnow')" "$(printf '%s' "$json" | jq -r '.ready.items[0].title')"
GH_DATA=$(jq -nc '[{repository:{name:"acme"}, number:11, title:"x\u001fy\u001ez", url:"u", updatedAt:"d", labels:[]}]')
json=$(run status someowner --json)
check "separator characters in a title are dropped, one item stays one" '["xyz"]' "$(jqc '[.ready.items[].title]' "$json")"
unset GH_DATA
export GH_WARN=1
json=$(run status someowner --json)
unset GH_WARN
check "a gh warning on stderr is not part of an item" '["issue","pr"]' \
  "$(jqc '[.waiting_on_you.items[].kind]' "$json")"

summary
