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
BASE=$(cat roles/_base.md)
FLOW=$(cat docs/flow.md)
LIMITS=$(cat docs/limits.md)
CONCEPT=$(cat docs/concept.md)

echo "roles: developer only looks at unassigned ready issues"
contains "finding-work filters no:assignee" '--search "no:assignee"' "$DEV"

echo "roles: developer claims an issue before working it"
contains "claims with --add-assignee @me" "gh issue edit <N> --add-assignee @me" "$DEV"

echo "roles: developer claims a ref before the assignee"
contains "pushes the claim ref" "refs/claims/issue-<N>" "$DEV"

echo "roles: developer checks the push exit code, not the message text"
contains "names the race message" "reference already exists" "$DEV"
contains "names the held-ref message" "non-fast-forward" "$DEV"
contains "tells the reader to branch on the exit code" "exit code" "$DEV"

echo "roles: developer is told never to force the claim ref"
contains "forbids --force on the claim push" "\`--force\` defeats the lock" "$DEV"

echo "roles: developer is warned about the zsh refspec trap"
contains "documents the zsh :r modifier trap" "zsh" "$DEV"
contains "shows the braced refspec fix" '${sha}:refs/claims/issue-<N>' "$DEV"

echo "roles: developer no longer carries the superseded PR-number tiebreaker"
lacks "dropped the lower-PR-number rule" "lower PR number" "$DEV"

echo "roles: developer releases a claim on abandon"
contains "releases with --remove-assignee @me" "gh issue edit <N> --remove-assignee @me" "$DEV"

echo "roles: developer releases the claim ref, not just the assignee"
contains "releases the claim ref" 'git push origin ":refs/claims/issue-<N>"' "$DEV"

echo "roles: reviewer only looks at unassigned review requests"
contains "finding-work filters no:assignee" "review-requested:@me no:assignee" "$REV"

echo "roles: reviewer claims a PR before reviewing it"
contains "claims with --add-assignee @me" "gh pr edit <N> --add-assignee @me" "$REV"

echo "roles: reviewer claims a ref before the assignee"
contains "pushes the claim ref" "refs/claims/pr-<N>" "$REV"

echo "roles: reviewer is told never to force the claim ref"
contains "forbids --force on the claim push" "force a claim ref open with \`--force\`" "$REV"

echo "roles: reviewer releases the claim after submitting a review"
contains "releases with --remove-assignee @me" "gh pr edit <N> --remove-assignee @me" "$REV"

echo "roles: reviewer releases the claim ref, not just the assignee"
contains "releases the claim ref" 'git push origin ":refs/claims/pr-<N>"' "$REV"

echo "roles: reviewer releases the claim even without submitting a review"
contains "covers the abandoned-review case" "submitting a review at all" "$REV"

echo "roles: _base.md states the cleanup duty for a claim ref"
contains "names the ref pattern" "refs/claims/" "$BASE"
contains "says there is no timeout" "no timeout" "$BASE"

echo "docs: flow.md documents the same-role collision and its fix"
contains "has the new section heading" "## Multiple agents in the same role" "$FLOW"
contains "names the claim ref mechanism" "refs/claims/" "$FLOW"
contains "carries the measured numbers" "always exactly 1 winner, 0 deviations" "$FLOW"

echo "docs: flow.md no longer carries the superseded PR-number tiebreaker"
lacks "dropped the lower-PR-number rule" "lower PR number" "$FLOW"

echo "docs: flow.md diagram no longer shows the stale short form"
contains "diagram line carries the filter" "gh issue list --label ready --search no:assignee" "$FLOW"

echo "docs: limits.md is honest about what the claim ref does not cover"
contains "has the new section heading" "## The claim ref locks task selection, not the work after it" "$LIMITS"
contains "names the crash case" "crashes" "$LIMITS"
contains "says there is no timeout" "no timeout" "$LIMITS"

echo "docs: concept.md no longer claims the worktree split fixes same-role collisions"
lacks "drops the unqualified 'for free' collision claim" "fixes the collision problem for free" "$CONCEPT"
contains "points to flow.md for the same-role case" "docs/flow.md" "$CONCEPT"

summary
