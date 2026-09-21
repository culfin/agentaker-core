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
MAINT=$(cat roles/maintainer.md)
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

echo "roles: reviewer detects its mode from AGENTS.md against the session's own login"
contains "names the AGENTS.md field" "reviewer:\` in \`AGENTS.md\`" "$REV"
contains "shows the command that gets a session's own login" "gh api user --jq .login" "$REV"

echo "roles: reviewer's single-account queue excludes already-approved PRs"
contains "finds work by the approved label, not a review request" 'gh pr list --search "is:open draft:false -label:approved"' "$REV"

echo "roles: reviewer's single-account verdict uses the label and draft state, not --approve"
contains "clears with --add-label approved" "gh pr edit <N> --add-label approved" "$REV"
contains "sends back with --undo" "gh pr ready <N> --undo" "$REV"
contains "documents --comment as the only working verdict command" "state=COMMENTED" "$REV"

echo "roles: reviewer is warned --add-reviewer is silently ineffective on its own account"
contains "names the empty reviewRequests result" "\`reviewRequests\` stays empty" "$REV"

echo "roles: developer's single-account inbox distinguishes not-ready-yet from sent-back"
contains "filters own draft PRs that already carry a review" 'gh pr list --search "is:open draft:true" --author @me --json number,title,reviews' "$DEV"

echo "roles: developer is warned against requesting review from itself"
contains "names the empty reviewRequests result" "leaves \`reviewRequests\` empty" "$DEV"

echo "roles: maintainer's single-account queue reads the approved label, not review:approved"
contains "finds work by the approved label" 'gh pr list --search "is:open draft:false label:approved"' "$MAINT"
contains "explains the label stands in for the locked native state" "label stands in for it instead" "$MAINT"

echo "docs: flow.md's diagrams and states cover both operating modes"
contains "names the mode-detection command" "gh api user --jq .login" "$FLOW"
contains "single-account diagram searches by the approved label" 'gh pr list --search "is:open draft:false -label:approved"' "$FLOW"
contains "label vocabulary scopes approved to single-account mode" "single-account mode only" "$FLOW"

echo "docs: flow.md explains approved replaces an unreachable state rather than duplicating one"
contains "makes the duplication-vs-replacement distinction" "does not exist here at all" "$FLOW"

echo "docs: limits.md is honest that single-account separation is agreed, not enforced"
contains "says a self-approval is physically impossible only with two accounts" "physically impossible" "$LIMITS"
contains "says a label proves a command ran, not who ran it" "proves a review command ran, not who ran it" "$LIMITS"

summary
