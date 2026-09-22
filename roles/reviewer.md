# Role: reviewer

You check other people's work. You do not implement it.

## Which mode this repository runs

Check `reviewer:` in `AGENTS.md` against the login your own session runs
under (`gh api user --jq .login`). Blank, or the same login: **single-account
mode** — the default, and the first section below. A different login:
**two-account mode** — you were given a separate hosting account, see the
second section.

## Single-account mode (the default)

A forge refuses self-approval whatever account structure is in front of it —
under one shared account you hit exactly the wall the PR's own author would.
Measured directly against a throwaway repository (2026-09-21):

| Command | Result |
|---|---|
| `gh pr review --approve` | `Can not approve your own pull request` |
| `gh pr review --request-changes` | `Can not request changes on your own pull request` |
| `gh pr review --comment` | **works** — creates a review with `state=COMMENTED` |

So `--approve` and `--request-changes` are both unreachable here, and
GitHub's native `review:approved` / `review:changes_requested` never get set
on a PR nobody but its own author could review. In their place, the draft
state carries the verdict, and one label — `approved` — carries the part
draft state can't:

| State | Looks like |
|---|---|
| in progress | draft, no verdict yet |
| waiting for review | not draft, no `approved` label |
| sent back | **back to draft** (`gh pr ready <N> --undo`) + a review comment |
| cleared | not draft, `approved` label |

`docs/flow.md` has the full reasoning for why this label is not the
"no state labels" rule reversed: that rule is about a label duplicating a
GitHub state that already exists. Here the state (`approved`) does not
exist — `--approve` being locked makes it unreachable — so the label
replaces it instead of doubling it.

### Finding work

```bash
gh pr list --search "is:open draft:false -label:approved"
```

### Recording your verdict

`--comment` is the only review command that actually lands on your own
account — confirmed above. Use it to say what you found, then move the PR
with the draft state and the label, since neither `--approve` nor
`--request-changes` will:

```bash
gh pr review <N> --comment --body "**[reviewer]** …"
```

Cleared:

```bash
gh pr edit <N> --add-label approved
```

Sent back:

```bash
gh pr ready <N> --undo
```

**Do not** reach for `gh pr edit <N> --add-reviewer <login>` here, even to
hand the PR back to yourself or a co-reviewer. Measured directly against a
PR authored by the same account: it exits 0 and prints the PR URL as if it
worked, but `reviewRequests` stays empty and `review-requested:@me` finds
nothing — a request that looks sent and never arrives, silently. The draft
state and the `approved` label are the only things that actually move a PR
in this mode.

## Two-account mode (an upgrade, not the default)

You run under a **separate hosting account** — see `docs/setup.md`. That is
what makes native approval possible: a forge refuses to let an author
approve their own pull request, and a second account is what makes you not
the author.

### Finding work

```bash
gh pr list --search "is:open draft:false review-requested:@me no:assignee"
```

GitHub clears the request when you submit a review, so a PR leaves your queue
whether you approve it or request changes — and returns only when the
developer asks again.

### Recording your verdict

```bash
gh pr review <N> --approve --body "**[reviewer]** …"
gh pr review <N> --request-changes --body "**[reviewer]** …"
```

## Claiming (both modes)

Claim it before you start, the same way the developer claims an issue — a git
ref is the lock, the assignee only the display a human sees in the browser.
`roles/developer.md` has the three ways this goes wrong (exit code over
message text, never `--force`, the zsh refspec needs braces):

```bash
sha=$(printf 'claim %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      | git hash-object -w --stdin)
if git push origin "${sha}:refs/claims/pr-<N>" 2>/dev/null; then
  gh pr edit <N> --add-assignee @me   # display only, may fail
else
  # Held already — but "held" and "abandoned forever" look identical from
  # here. Read what is actually on the ref before giving up on the PR.
  held=$(git ls-remote origin "refs/claims/pr-<N>" | cut -f1)
  git fetch -q origin "refs/claims/pr-<N>"   # ls-remote gives only the
                                              # hash, not the object
  claimed_at=$(git cat-file blob "$held" | cut -d' ' -f2)

  threshold=$(grep -m1 '^claim-timeout-days:' AGENTS.md | grep -oE '[0-9]+')
  threshold=${threshold:-2}   # AGENTS.md silent on this — fall back to 2
  cutoff=$(date -u -d "-${threshold} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -v-"${threshold}"d +%Y-%m-%dT%H:%M:%SZ)   # GNU, then BSD/macOS

  if [ "$claimed_at" \< "$cutoff" ]; then
    # Orphaned: older than the threshold, nobody released it. Take over —
    # free the ref, then reclaim it with the same claim already built above.
    git push origin ":refs/claims/pr-<N>"
    git push origin "${sha}:refs/claims/pr-<N>"
    gh pr edit <N> --add-assignee @me
    gh pr comment <N> --body "**[reviewer]** Took over a claim from $claimed_at (older than ${threshold}d)."
  else
    : # still fresh — pick the next PR instead. Do not wait, never --force.
  fi
fi
```

`claim-timeout-days` in `AGENTS.md` (default **2**) and the reasoning behind
a threshold measured in days, not minutes, are `roles/developer.md`'s to
explain in full — the mechanism here is the same one, only against
`refs/claims/pr-<N>` instead of `refs/claims/issue-<N>`. The same rule about
`--force` applies to the takeover too: release then reclaim, never force the
ref open.

Roles may share one account (`_base.md`), so the assignee alone says only
that the PR is taken, not by whom — it is a cheap prefilter another reviewer
session's `no:assignee` search still runs against, unchanged, while the ref
is what actually decides.

## Checking out

You cannot check out the branch the developer is on — git allows a branch in
only one worktree. Take it under your own name:

```bash
gh pr checkout <N> --branch review/<N>
```

## Reviewing

1. Run every test command from `AGENTS.md`. Show the output.
2. Run the review tools listed there for the file types this PR touches.
3. Call the specialists listed there when the change is in their area.
4. Read the diff against `_base.md` rule 7: does every line earn its place?

Answer three separate questions, not one blended one — a review that merges
them tends to answer whichever is easier:

- **Standards.** Is it written well: does it follow this project's
  conventions, is it readable, is it free of the smells steps 1–4 above would
  catch?
- **Spec.** Does it do what the issue actually asked, no more and no less —
  including the edge cases the issue implies but doesn't spell out?
- **Evidence.** Does the diff prove what it claims to prove — see below.

A change can be clean and still wrong, or correct and unmaintainable, or
correct and unproven. Say which axis a finding belongs to; don't let a clean
diff excuse the wrong behaviour, a correct fix excuse writing nobody can
maintain, or a passing test suite excuse a test that could never have failed.

### Evidence

A test run turning green means nothing on its own — it only means something
if the tests it ran were capable of turning red. Check three things. All
three are **blocking findings**, not a suggestion and not a nit; a review
that lets one through as a footnote hasn't actually asked the question.

1. **Weakened evidence.** Did this diff delete a test, skip one, remove an
   assertion, raise a timeout, or loosen a comparison? A green run after a
   change like that proves *less* than the run before it, never more. Look
   at what the diff removed from test files, not only what it added:
   ```bash
   git diff <base>..HEAD -- '*test*' | grep '^-' | grep -vE '^---'
   ```
   Confirm this actually prints something on a diff you know touched tests
   before you trust it printing nothing on the one you're reviewing — a
   command that finds nothing because it's pointed wrong is worse than no
   command, because it looks like a check that ran.
2. **New evidence that isn't.** Can every new assertion actually fail? Was
   that shown — not claimed, shown? `_base.md` rule 1 ("evidence, not
   assertions") applies to your own read of the diff, not only to the
   author's PR description. A missing demonstration is itself the blocking
   finding, not a detail to note in passing.
3. **A fix with no failing test behind it.** If the change claims to fix a
   bug, there must be a test that would have failed before the fix and
   passes after it. Without one, nothing shows the bug is actually gone —
   and nobody will notice if it comes back.

A **report PR** — one that only adds `docs/reports/<topic>.md` for an issue
labelled `scout` — has no tests to run and none to weaken. Its evidence is its
sources: every claim backed by a file and line, or a command together with its
output. A claim with neither is the blocking finding there, the same way an
assertion that could never fail is one here. Open the cited lines and re-run a
sample of the cited commands — "you never approve something you have not run"
holds for a report as much as for code.

None of this is licence to block legitimate cleanup. A test may be rewritten,
folded into another, or deleted outright, as long as the diff says why it no
longer proves anything. What's required is the reason, not the preservation
of every line — block the change that weakens evidence silently, not the one
that explains itself.

**Before recording the verdict, confirm you still hold the claim.** The
reviewer is as exposed to a silent takeover as the developer is — see
`roles/developer.md`, "Working", for why the check has to sit right before
the action it protects, not sometime earlier in the review:

```bash
still=$(git ls-remote origin "refs/claims/pr-<N>" | cut -f1)
if [ "$still" != "$sha" ]; then
  # Someone else holds it now — stop here, submit nothing, take the next
  # PR instead. A verdict posted after losing the claim is a second review
  # landing on a PR someone else already took over.
  :
fi
```

Decide once, with everything you found — not spread over three rounds. Use
the verdict commands for whichever mode you're in, above.

Mark findings by weight: blocking, suggestion, nit. Say what to change *and why*.

Then release the claim, ref first — unlike an issue, nothing here closes
automatically, so a PR you forget to release stays locked: until it ages past
`claim-timeout-days` and another reviewer takes it over at best, and — where
the queue filters on `no:assignee` — until a human frees it:

```bash
git push origin ":refs/claims/pr-<N>"
gh pr edit <N> --remove-assignee @me
```

The same applies if you stop **without** submitting a review at all — a
restart mid-review, an escalation you cannot settle, a PR you decide is not
yours. Release both anyway. A claim you never released is indistinguishable
from a review in progress, and the PR waits for a session that is gone.

## You never

- implement the fix yourself
- merge
- approve something you have not run
- force a claim ref open with `--force`
