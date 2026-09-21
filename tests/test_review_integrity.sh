#!/usr/bin/env bash
# Checks that the reviewer's third axis -- whether the diff's own tests still
# prove anything -- is actually documented, not just the two it had before.
# This is prose, not code, so the assertions are substring checks against the
# shipped files themselves -- there is nothing else to execute.
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh

REV=$(cat roles/reviewer.md)
DEV=$(cat roles/developer.md)
FLOW=$(cat docs/flow.md)

echo "roles: reviewer answers three questions, not two"
contains "counts three questions" "Answer three separate questions" "$REV"
contains "names the third as Evidence" "**Evidence.**" "$REV"

echo "roles: reviewer has a dedicated Evidence section"
contains "has the Evidence heading" "### Evidence" "$REV"

echo "roles: reviewer checks for weakened tests, not just missing ones"
contains "names weakened evidence" "**Weakened evidence.**" "$REV"
contains "covers deleted, skipped, and loosened tests" "delete a test, skip one, remove an" "$REV"
contains "gives the command that finds removed test lines" \
  "git diff <base>..HEAD -- '*test*' | grep '^-' | grep -vE '^---'" "$REV"
contains "warns against trusting an empty result blindly" \
  "actually prints something on a diff you know touched tests" "$REV"

echo "roles: reviewer requires new assertions to be shown failing, not just written"
contains "names new evidence that isn't" "**New evidence that isn't.**" "$REV"
contains "demands the assertion was shown to fail, not just claimed" \
  "not claimed, shown?" "$REV"
contains "ties the check back to _base.md rule 1" "_base.md\` rule 1" "$REV"

echo "roles: reviewer requires a fix to carry the test that would have failed before it"
contains "names the fix-without-proof case" "**A fix with no failing test behind it.**" "$REV"
contains "requires a test that would have failed before the fix" \
  "a test that would have failed before the fix" "$REV"

echo "roles: reviewer treats all three evidence checks as blocking, not a suggestion"
contains "marks the checks blocking" "blocking findings" "$REV"
contains "rejects treating them as a footnote" "a footnote" "$REV"

echo "roles: reviewer explicitly allows explained test cleanup"
contains "carves out legitimate cleanup" "licence to block legitimate cleanup" "$REV"
contains "requires a reason, not preservation of every line" \
  "the reason, not the preservation" "$REV"

echo "roles: developer shows a bugfix test failing before the fix"
contains "tells the developer to show the failing test first" \
  "show the new test failing against the old code" "$DEV"

echo "docs: flow.md's review step mentions all three axes, not just the queue filter"
contains "names the third axis at the review step" \
  "The review itself answers three questions, not two" "$FLOW"

summary
