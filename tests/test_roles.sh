#!/usr/bin/env bash
# Checks that the same-role work-claim mechanism is actually documented in the
# role prose and in the docs that explain it. This is prose, not code, so the
# assertions are substring checks against the shipped files themselves --
# there is nothing else to execute.
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh

DEV=$(cat roles/developer.md)
REV=$(cat roles/reviewer.md)
FLOW=$(cat docs/flow.md)
CONCEPT=$(cat docs/concept.md)

echo "roles: developer only looks at unassigned ready issues"
contains "finding-work filters no:assignee" '--search "no:assignee"' "$DEV"

echo "roles: developer claims an issue before working it"
contains "claims with --add-assignee @me" "gh issue edit <N> --add-assignee @me" "$DEV"

echo "roles: developer releases a claim on abandon"
contains "releases with --remove-assignee @me" "gh issue edit <N> --remove-assignee @me" "$DEV"

echo "roles: developer states the tiebreaker for a duplicate draft PR"
contains "lower PR number wins" "lower PR number" "$DEV"

echo "roles: reviewer only looks at unassigned review requests"
contains "finding-work filters no:assignee" "review-requested:@me no:assignee" "$REV"

echo "roles: reviewer claims a PR before reviewing it"
contains "claims with --add-assignee @me" "gh pr edit <N> --add-assignee @me" "$REV"

echo "roles: reviewer releases the claim after submitting a review"
contains "releases with --remove-assignee @me" "gh pr edit <N> --remove-assignee @me" "$REV"

echo "roles: reviewer releases the claim even without submitting a review"
contains "covers the abandoned-review case" "submitting a review at all" "$REV"

echo "docs: flow.md documents the same-role collision and its fix"
contains "has the new section heading" "## Multiple agents in the same role" "$FLOW"
contains "states the tiebreaker" "lower PR number" "$FLOW"

echo "docs: flow.md diagram no longer shows the stale short form"
contains "diagram line carries the filter" "gh issue list --label ready --search no:assignee" "$FLOW"

echo "docs: concept.md no longer claims the worktree split fixes same-role collisions"
lacks "drops the unqualified 'for free' collision claim" "fixes the collision problem for free" "$CONCEPT"
contains "points to flow.md for the same-role case" "docs/flow.md" "$CONCEPT"

summary
