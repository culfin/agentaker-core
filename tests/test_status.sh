#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
WTR="$PWD/bin/wtr"
make_sandbox
trap 'rm -rf "$SANDBOX"' EXIT

echo "wtr status: arguments"
out=$(WTR_OWNER= "$WTR" status 2>&1); check "no owner exits 1" "1" "$?"
contains "no owner is explained" "owner" "$out"

echo "wtr status: sections"
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

echo "wtr status: sections, without a reviewer login"
out=$(PATH="$STUB:$PATH" WTR_REVIEWER= "$WTR" status someowner 2>&1)
contains "shows ready work" "ready to pick up" "$out"
contains "shows review queue" "waiting for review" "$out"
contains "shows merge queue" "approved" "$out"
contains "shows human queue" "waiting on you" "$out"
contains "admits the queue is approximate" "WTR_REVIEWER" "$out"

calls=$(cat "$GH_CALLS")
contains "asks for the ready label" "--label ready" "$calls"
contains "falls back to review none" "review none" "$calls"
contains "asks for approved PRs" "review approved" "$calls"
contains "asks for decisions" "needs-decision" "$calls"
contains "filters out dependabot" "dependabot" "$calls"

echo "wtr status: with a reviewer login"
: > "$GH_CALLS"
out=$(PATH="$STUB:$PATH" WTR_REVIEWER=somereviewer "$WTR" status someowner 2>&1)
calls=$(cat "$GH_CALLS")
contains "asks for that reviewer's queue" "review-requested somereviewer" "$calls"
lacks "does not fall back" "review none" "$calls"
lacks "no approximation notice" "WTR_REVIEWER" "$out"

echo "wtr attach: arguments"
out=$("$WTR" attach 2>&1); check "attach without repo exits 2" "2" "$?"

summary
