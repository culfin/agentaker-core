#!/usr/bin/env bash
# `tender status --json [--since <time>]` (lib/status_json.sh), and the proof
# that the text board did not move while its queries were shared with it.
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

# A gh stand-in: logs its argv one call per line, picks a canned listing by
# the qualifiers it was asked with, and applies the --jq program to it with
# jq -r — the way gh prints --jq strings, raw, one per line. FAIL_ON, if
# set, is a glob of argv that fails like gh does: a message on stderr, rc 1.
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
q=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && q=$a; prev=$a; done
if [ -n "${FAIL_ON:-}" ]; then
  case "$*" in $FAIL_ON) printf 'HTTP 502: bad gateway\nsecond line\n' >&2; exit 1 ;; esac
fi
case "$*" in
  *"--label ready"*) data='[{"repository":{"name":"acme"},"number":1,"title":"free","url":"https://x/acme/issues/1","updatedAt":"2026-09-22T09:00:00Z","labels":[{"name":"ready"}]},{"repository":{"name":"acme"},"number":2,"title":"held","url":"https://x/acme/issues/2","updatedAt":"2026-09-22T09:00:00Z","labels":[{"name":"ready"},{"name":"needs-decision"}]}]' ;;
  *"--review approved"*) data='[{"repository":{"name":"acme"},"number":5,"title":"approved one","url":"https://x/acme/pull/5","updatedAt":"2026-09-22T09:05:00Z"}]' ;;
  *"--label approved"*) data='[{"repository":{"name":"acme"},"number":5,"title":"approved one","url":"https://x/acme/pull/5","updatedAt":"2026-09-22T09:05:00Z"},{"repository":{"name":"acme"},"number":6,"title":"cleared by label","url":"https://x/acme/pull/6","updatedAt":"2026-09-22T09:06:00Z"}]' ;;
  *"needs-decision"*) data='[{"repository":{"name":"web"},"number":7,"title":"decide me","url":"https://x/web/issues/7","updatedAt":"2026-09-22T09:07:00Z","isPullRequest":false},{"repository":{"name":"web"},"number":8,"title":"a PR on hold","url":"https://x/web/pull/8","updatedAt":"2026-09-22T09:08:00Z","isPullRequest":true}]' ;;
  *"--merged-at"*) data='[{"repository":{"name":"web"},"number":9,"title":"shipped","url":"https://x/web/pull/9","updatedAt":"2026-09-22T10:01:00Z","closedAt":"2026-09-22T10:00:00Z"}]' ;;
  *) data='[{"repository":{"name":"acme"},"number":3,"title":"review me","url":"https://x/acme/pull/3","updatedAt":"2026-09-22T09:03:00Z","author":{"login":"alice"}},{"repository":{"name":"acme"},"number":4,"title":"bump","url":"https://x/acme/pull/4","updatedAt":"2026-09-22T09:04:00Z","author":{"login":"dependabot[bot]"}}]' ;;
esac
[ -z "${GH_DATA:-}" ] || data=$GH_DATA
printf '%s' "$data" | jq -r "$q"
# After the listing, so that stderr mixed into stdout would land in a record.
[ -z "${GH_WARN:-}" ] || echo "warning: a gh notice on stderr" >&2
exit 0
STUBEOF
chmod +x "$STUB/gh"
run() { PATH="$STUB:$PATH" "$TENDER" "$@"; }

echo "tender status: the text board is byte-identical to before the JSON board"
# Both halves below were captured from bin/tender at 89824dd — the commit
# before the queries were shared — with this very stub: the output, and the
# exact argv of every gh call. Not a re-derivation: a copy of what it did.
EXPECTED_APPROX=$(cat <<'EOF'
ready to pick up:
  acme#1  free
  (blocked issues are counted here — the developer skips them)
waiting for review:
  acme#3  review me
  (approximate — set TENDER_REVIEWER to your reviewer login for the exact queue)
approved, waiting for merge:
  acme#5  approved one
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
approved, waiting for merge:
  acme#5  approved one
waiting on you:
  web#7  decide me
  web#8  a PR on hold
EOF
)
EXPECTED_CALLS=$(cat <<'EOF'
search issues --owner someowner --state open --label ready --json repository,number,title,labels --jq .[] | select(any(.labels[]; .name == "needs-decision") | not) | "  \(.repository.name)#\(.number)  \(.title)"
search prs --owner someowner --state open --draft=false --review none --json repository,number,title,author --jq .[] | select(.author.login | test("dependabot") | not) | "  \(.repository.name)#\(.number)  \(.title)"
search prs --owner someowner --state open --review approved --json repository,number,title --jq .[] | "  \(.repository.name)#\(.number)  \(.title)"
search issues --owner someowner --state open --label needs-decision --json repository,number,title --jq .[] | "  \(.repository.name)#\(.number)  \(.title)"
search issues --owner someowner --state open --label ready --json repository,number,title,labels --jq .[] | select(any(.labels[]; .name == "needs-decision") | not) | "  \(.repository.name)#\(.number)  \(.title)"
search prs --owner someowner --state open --draft=false --review-requested rev --json repository,number,title,author --jq .[] | select(.author.login | test("dependabot") | not) | "  \(.repository.name)#\(.number)  \(.title)"
search prs --owner someowner --state open --review approved --json repository,number,title --jq .[] | "  \(.repository.name)#\(.number)  \(.title)"
search issues --owner someowner --state open --label needs-decision --json repository,number,title --jq .[] | "  \(.repository.name)#\(.number)  \(.title)"
EOF
)
: > "$GH_CALLS"
out=$(TENDER_REVIEWER= run status someowner 2>&1); rc_a=$?
out_b=$(TENDER_REVIEWER=rev run status someowner 2>&1); rc_b=$?
check "text board, approximate queue: same output" "$EXPECTED_APPROX" "$out"
check "text board, reviewer login: same output" "$EXPECTED_EXACT" "$out_b"
check "text board: the same gh calls, argument for argument" "$EXPECTED_CALLS" "$(cat "$GH_CALLS")"
check "text board: same exit status" "0 0" "$rc_a $rc_b"
out=$(FAIL_ON='*' TENDER_REVIEWER= run status someowner 2>/dev/null); rc=$?
check "text board: a failed query still exits 1" "1" "$rc"
contains "text board: and still says what gh said" "could not ask: HTTP 502: bad gateway" "$out"

echo "tender status --json: the board"
: > "$GH_CALLS"
json=$(TENDER_REVIEWER= run status someowner --json); rc=$?
check "exits 0 when every section was asked" "0" "$rc"
check "is one valid JSON object" "object" "$(printf '%s' "$json" | jq -r type 2>&1)"
check "carries the owner" "someowner" "$(printf '%s' "$json" | jq -r .owner)"
check "since is null without --since" "null" "$(printf '%s' "$json" | jq -c .since)"
contains "generated_at is an ISO-8601 UTC time" "T" "$(printf '%s' "$json" | jq -r '.generated_at | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))')"
check "exactly the four sections, merged only with --since" \
  "approved,generated_at,owner,ready,since,waiting_for_review,waiting_on_you" \
  "$(printf '%s' "$json" | jq -r 'keys | join(",")')"
check "every section is ok" "true true true true" \
  "$(printf '%s' "$json" | jq -r '[.waiting_on_you.ok, .approved.ok, .waiting_for_review.ok, .ready.ok] | map(tostring) | join(" ")')"
check "waiting_on_you: issues and PRs, each with its kind" "web#7 issue,web#8 pr" \
  "$(printf '%s' "$json" | jq -r '[.waiting_on_you.items[] | "\(.repo)#\(.number) \(.kind)"] | join(",")')"
check "an item carries repo, number, title, url, updated_at" \
  '{"repo":"web","number":7,"title":"decide me","url":"https://x/web/issues/7","updated_at":"2026-09-22T09:07:00Z","kind":"issue"}' \
  "$(printf '%s' "$json" | jq -c '.waiting_on_you.items[0]')"
check "approved: natively approved and label-cleared, each once" "5,6" \
  "$(printf '%s' "$json" | jq -r '[.approved.items[].number] | map(tostring) | join(",")')"
check "waiting_for_review: dependabot's PRs are left out" "3" \
  "$(printf '%s' "$json" | jq -r '[.waiting_for_review.items[].number] | map(tostring) | join(",")')"
check "ready: an issue on hold (needs-decision) is not ready" "1" \
  "$(printf '%s' "$json" | jq -r '[.ready.items[].number] | map(tostring) | join(",")')"
calls=$(cat "$GH_CALLS")
contains "waiting_on_you asks for PRs too" "--label needs-decision --include-prs" "$calls"
contains "approved asks for the single-account label" "--draft=false --label approved" "$calls"
contains "the review queue is the text board's approximation" "--draft=false --review none" "$calls"
lacks "without --since, no date filter" "--updated" "$calls"
lacks "without --since, nothing about merges" "--merged-at" "$calls"

: > "$GH_CALLS"
TENDER_REVIEWER=somereviewer run status someowner --json >/dev/null
contains "with TENDER_REVIEWER, the review queue is that login's" \
  "--review-requested somereviewer" "$(cat "$GH_CALLS")"

echo "tender status --json --since: gh's own date filters"
: > "$GH_CALLS"
T=2026-09-22T08:00:00Z
json=$(TENDER_REVIEWER= run status someowner --json --since "$T"); rc=$?
check "exits 0" "0" "$rc"
check "since is echoed" "$T" "$(printf '%s' "$json" | jq -r .since)"
calls=$(cat "$GH_CALLS")
check "every open-work question carries --updated >=T" "5" \
  "$(grep -c -- "--updated >=$T --json" "$GH_CALLS")"
check "and the merged question does not" "0" "$(grep -- '--merged-at' "$GH_CALLS" | grep -c -- '--updated')"
contains "merged asks gh for --merged-at >=T" "search prs --owner someowner --merged-at >=$T --json" "$calls"
check "merged: its items carry merged_at" "web#9 2026-09-22T10:00:00Z" \
  "$(printf '%s' "$json" | jq -r '.merged.items[] | "\(.repo)#\(.number) \(.merged_at)"')"
: > "$GH_CALLS"
run status someowner --json --since="$T" >/dev/null
check "--since=T works as well" "5" "$(grep -c -- "--updated >=$T --json" "$GH_CALLS")"

echo "tender status: usage errors"
for bad in 2026-09-22 2026-09-22T08:00:00+02:00 2026-02-30T00:00:00Z 2026-13-01T00:00:00Z yesterday ""; do
  : > "$GH_CALLS"
  out=$(run status someowner --json --since "$bad" 2>&1); rc=$?
  check "--since '$bad' exits 2" "2" "$rc"
  check "--since '$bad' asks gh nothing" "" "$(cat "$GH_CALLS")"
done
contains "the refusal names the expected shape" "YYYY-MM-DDTHH:MM:SSZ" "$out"
out=$(run status someowner --json --since 2>&1); check "--since without a value exits 2" "2" "$?"
: > "$GH_CALLS"
out=$(run status someowner --since "$T" 2>&1); check "--since without --json exits 2" "2" "$?"
contains "and says --json is what it needs" "--since needs --json" "$out"
check "and asks gh nothing" "" "$(cat "$GH_CALLS")"
out=$(run status someowner --jsno 2>&1); check "an unknown option exits 2" "2" "$?"
out=$(run status --help); check "status --help exits 0" "0" "$?"
contains "status --help says --since is an approximation" "approximates" "$out"
out=$(TENDER_OWNER= run status --json 2>&1); check "--json with no owner exits 1" "1" "$?"
contains "and asks for one" "give an owner" "$out"
json=$(TENDER_OWNER=envowner run status --json)
check "--json takes the owner from TENDER_OWNER" "envowner" "$(printf '%s' "$json" | jq -r .owner)"

echo "tender status --json: a section that could not be asked"
for pair in "waiting_on_you:*--label needs-decision*" "approved:*--review approved*" \
            "approved:*--label approved*" "waiting_for_review:*--review none*" \
            "ready:*--label ready*" "merged:*--merged-at*"; do
  key=${pair%%:*} glob=${pair#*:}
  json=$(FAIL_ON=$glob TENDER_REVIEWER= run status someowner --json --since "$T" 2>/dev/null); rc=$?
  check "$key ($glob fails): exit 1" "1" "$rc"
  check "$key ($glob fails): still valid JSON" "object" "$(printf '%s' "$json" | jq -r type 2>&1)"
  check "$key ($glob fails): ok false, gh's first line, no items" \
    '{"ok":false,"error":"HTTP 502: bad gateway"}' "$(printf '%s' "$json" | jq -c ".$key")"
  check "$key ($glob fails): the other sections are still ok" "4" \
    "$(printf '%s' "$json" | jq "[to_entries[] | select(.value | type == \"object\") | select(.key != \"$key\") | .value.ok] | map(select(.)) | length")"
done

echo "tender status --json: titles that JSON has to escape"
GH_DATA='[{"repository":{"name":"acme"},"number":11,"title":"say \"hi\" \\ or\nnot\tnow","url":"https://x/11","updatedAt":"2026-09-22T09:00:00Z","isPullRequest":false,"labels":[{"name":"ready"}],"author":{"login":"a"},"closedAt":"2026-09-22T09:00:00Z"}]'
export GH_DATA
json=$(run status someowner --json --since "$T"); rc=$?
check "exits 0" "0" "$rc"
check "parses" "object" "$(printf '%s' "$json" | jq -r type 2>&1)"
check "the title comes back exactly: quotes, backslash, newline, tab" \
  "$(printf 'say "hi" \\ or\nnot\tnow')" "$(printf '%s' "$json" | jq -r '.ready.items[0].title')"
unset GH_DATA
export GH_WARN=1
json=$(run status someowner --json)
unset GH_WARN
check "a gh warning on stderr is not part of an item" "issue,pr" \
  "$(printf '%s' "$json" | jq -r '[.waiting_on_you.items[].kind] | join(",")')"
export GH_DATA='[]'
json=$(run status someowner --json)
unset GH_DATA
check "an empty listing is ok with no items" '{"ok":true,"items":[]}' "$(printf '%s' "$json" | jq -c .ready)"

summary
