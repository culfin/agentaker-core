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
contains "names the age-based release instead of claiming there is none" "claim-timeout-days" "$BASE"
lacks "no longer claims a claim ref locks forever with no way back" "there is no timeout" "$BASE"

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
lacks "no longer claims a claim ref locks forever with no way back" "there is no timeout" "$LIMITS"
contains "documents the age-based release" "claim-timeout-days" "$LIMITS"
contains "admits the release is lazy, not a sweep" "still lazy, not a sweep" "$LIMITS"
contains "admits a threshold can evict a live, slow session" "evicts a session mid-task" "$LIMITS"

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

echo "roles: developer takes over an orphaned claim after reading its timestamp, never a fresh one"
contains "reads the hash via ls-remote first" 'held=$(git ls-remote origin "refs/claims/issue-<N>" | cut -f1)' "$DEV"
contains "fetches the object before cat-file can read it" 'git fetch -q origin "refs/claims/issue-<N>"' "$DEV"
contains "reads claim-timeout-days from AGENTS.md" "grep -m1 '^claim-timeout-days:' AGENTS.md" "$DEV"
contains "falls back to a 2-day default when AGENTS.md is silent" 'threshold=${threshold:-2}' "$DEV"
contains "computes the cutoff across both GNU and BSD/macOS date" "date -u -v-" "$DEV"
contains "compares the claimed timestamp against the cutoff before touching the ref" '[ "$claimed_at" \< "$cutoff" ]' "$DEV"
contains "releases before reclaiming — never forces the ref open, even for a takeover" 'git push origin ":refs/claims/issue-<N>"' "$DEV"
contains "comments on the issue so a human can see the takeover happened" 'gh issue comment <N> --body "**[developer]** Took over a claim from' "$DEV"
contains "a claim still inside the threshold is left alone" "still fresh" "$DEV"

echo "roles: developer confirms it still holds the claim before opening the draft PR"
contains "compares the held sha against its own, right before opening" 'still=$(git ls-remote origin "refs/claims/issue-<N>" | cut -f1)' "$DEV"
contains "opens nothing and moves to the next issue if it lost the claim" "open nothing" "$DEV"
contains "explains why the check has to sit right at that step, not earlier" "the less it proves" "$DEV"

echo "roles: reviewer takes over an orphaned claim the same way, against a PR claim"
contains "reads the hash via ls-remote first" 'held=$(git ls-remote origin "refs/claims/pr-<N>" | cut -f1)' "$REV"
contains "fetches the object before cat-file can read it" 'git fetch -q origin "refs/claims/pr-<N>"' "$REV"
contains "comments on the PR so a human can see the takeover happened" 'gh pr comment <N> --body "**[reviewer]** Took over a claim from' "$REV"
contains "points to developer.md for the full reasoning, rather than repeating it" "roles/developer.md\`'s to" "$REV"

echo "roles: reviewer confirms it still holds the claim before recording the verdict"
contains "compares the held sha against its own before the verdict" 'still=$(git ls-remote origin "refs/claims/pr-<N>" | cut -f1)' "$REV"
contains "submits nothing and moves to the next PR if it lost the claim" "submit nothing" "$REV"

echo "roles: neither role's takeover ever reaches for --force"
contains "developer names the takeover explicitly in the --force warning" "not even to take over an" "$DEV"

echo "docs: flow.md documents the age-based release, honestly bounded"
contains "has the new section heading" "## Orphaned claims: age-based release" "$FLOW"
contains "names the AGENTS.md field and its default" "claim-timeout-days\` in \`AGENTS.md\` (default **2**" "$FLOW"
contains "names the measured object-info failure that makes the fetch necessary" "could not get object info" "$FLOW"
contains "is honest that a live, slow session can still be evicted" "may be alive and simply slow, not gone" "$FLOW"

echo "docs: limits.md's orphaned-claim update is honest about what it does not fix"
contains "still lazy" "still lazy" "$LIMITS"
lacks "old sentence gone — nothing checks on a stale claim used to be flatly true" \
  "nothing checks on it again" "$LIMITS"

echo "AGENTS.md: the claim-timeout-days field ships with every template"
INIT=$(cat lib/init.sh)
contains "lib/init.sh proposes the field with a 2-day default" "claim-timeout-days: 2" "$INIT"
for ex in examples/*.AGENTS.md; do
  contains "$ex ships claim-timeout-days" "claim-timeout-days: 2" "$(cat "$ex")"
done

echo "AGENTS.md: max-open-prs ships as a commented hint only (issue #1)"
contains "lib/init.sh carries the hint next to claim-timeout-days" \
  "<!-- max-open-prs: 3  cap on open agent PRs — see docs/limits.md -->" "$INIT"
check "the hint is not a Markdown heading" "0" "$(grep -c '^#[^!]*max-open-prs' lib/init.sh)"
check "no uncommented max-open-prs line in the template — default stays no cap" "0" \
  "$(grep -c '^max-open-prs:' lib/init.sh)"

echo "roles: the developer checks max-open-prs before opening a PR"
contains "reads max-open-prs from AGENTS.md" "grep -m1 '^max-open-prs:' AGENTS.md" "$DEV"
contains "counts only this repo's developer branches" 'startswith(\"$repo-developer-\")' "$DEV"
contains "at the cap: keeps the branch pushed, as prose after the count" "**At the cap** (\`full=yes\`): do not open the PR. Push the branch" "$DEV"
contains "at the cap: no new claim" "Claim no new issue until the" "$DEV"
contains "at the cap: review feedback continues" "Review feedback on the" "$DEV"
contains "could not ask: proceeds and says so" "going ahead without the max-open-prs check" "$DEV"
contains "finding work runs only the count before claiming" "the count block only, nothing after it" "$DEV"
contains "the repo name comes from the branch tender named" 'repo=${branch%-developer*}' "$DEV"
check "the cap check comes before gh pr create" "yes" \
  "$([ "$(grep -n "grep -m1 '^max-open-prs:'" roles/developer.md | head -1 | cut -d: -f1)" -lt "$(grep -n 'gh pr create --draft' roles/developer.md | head -1 | cut -d: -f1)" ] && echo yes || echo no)"
contains "limits says the cap binds the project, not the tool" "It binds the project, not the tool" "$LIMITS"
contains "limits says the first developer session is never refused" "never stops the first developer session" "$LIMITS"
lacks "limits no longer says there is no such knob" "has no such" "$LIMITS"

summary
