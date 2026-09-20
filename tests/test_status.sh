#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
WTC="$PWD/bin/wtc"
make_sandbox
trap 'rm -rf "$SANDBOX"' EXIT

echo "wtc status: arguments"
out=$(WTC_OWNER= "$WTC" status 2>&1); check "no owner exits 1" "1" "$?"
contains "no owner is explained" "owner" "$out"

echo "wtc status: sections"
# gh is stubbed so the test needs neither network nor credentials.
STUB=$(mktemp -d); trap 'rm -rf "$SANDBOX" "$STUB"' EXIT
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
# Records its arguments and prints one fake row, so the test can assert
# both the output shape and the search terms used.
printf '%s\n' "$*" >> "$GH_CALLS"
echo "  demo#1  a fake row"
STUBEOF
chmod +x "$STUB/gh"
export GH_CALLS="$STUB/calls"
: > "$GH_CALLS"

echo "wtc status: sections, without a reviewer login"
out=$(PATH="$STUB:$PATH" WTC_REVIEWER= "$WTC" status someowner 2>&1)
contains "shows ready work" "ready to pick up" "$out"
contains "shows review queue" "waiting for review" "$out"
contains "shows merge queue" "approved" "$out"
contains "shows human queue" "waiting on you" "$out"
contains "admits the queue is approximate" "WTC_REVIEWER" "$out"

calls=$(cat "$GH_CALLS")
contains "asks for the ready label" "--label ready" "$calls"
contains "falls back to review none" "review none" "$calls"
contains "asks for approved PRs" "review approved" "$calls"
contains "asks for decisions" "needs-decision" "$calls"
# This proves the filter is REQUESTED, not that it filters: the stub replaces gh,
# so the --jq expression never runs. Real filtering is verified against a live
# organisation — see the task report.
contains "filters out dependabot" "dependabot" "$calls"

echo "wtc status: with a reviewer login"
: > "$GH_CALLS"
out=$(PATH="$STUB:$PATH" WTC_REVIEWER=somereviewer "$WTC" status someowner 2>&1)
calls=$(cat "$GH_CALLS")
contains "asks for that reviewer's queue" "review-requested somereviewer" "$calls"
lacks "does not fall back" "review none" "$calls"
lacks "no approximation notice" "WTC_REVIEWER" "$out"

echo "wtc status: a failed query is not an empty board"
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
echo "gh: could not authenticate" >&2
exit 1
STUBEOF
chmod +x "$STUB/gh"
out=$(PATH="$STUB:$PATH" WTC_REVIEWER=r "$WTC" status someowner 2>&1)
check "failed queries exit 1" "1" "$?"
contains "says it could not ask" "could not ask" "$out"
lacks "does not claim an empty queue" "(none)" "$out"
contains "warns the board is incomplete" "incomplete" "$out"

echo "wtc attach: arguments"
out=$("$WTC" attach 2>&1); check "attach without repo exits 2" "2" "$?"

echo "wtc attach: missing tmux is diagnosed as missing tmux"
NOTMUX=$(mktemp -d)
out=$(PATH="$NOTMUX:$(dirname "$(command -v git)"):/usr/bin:/bin" "$WTC" attach demo 2>&1)
check "exits 1" "1" "$?"
contains "names tmux" "tmux is not installed" "$out"
rm -rf "$NOTMUX"

summary
