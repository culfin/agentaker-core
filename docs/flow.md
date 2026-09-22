# Flow

This tool runs in one of two modes, and the flow below differs in the review
step depending on which. Check `reviewer:` in `AGENTS.md` against the login
a session runs under (`gh api user --jq .login`): blank, or the same login,
is **single-account mode** — the default, and the first diagram below. A
different login is **two-account mode** — the second diagram, and an upgrade
you opt into, not a requirement to start.

## Single-account mode (the default)

```
human       puts `ready` on an issue                      ← the only starting point
   |
developer   gh issue list --label ready --search "no:assignee -label:needs-decision"
            gh pr create --draft   …work…   gh pr ready <N>
                 |
reviewer    gh pr list --search "is:open draft:false -label:approved"
            gh pr review <N> --comment --body "…"
            gh pr edit <N> --add-label approved     -> maintainer
            gh pr ready <N> --undo                  -> back to developer
                 |
developer   fixes, then gh pr ready <N>   (re-ask)
                 |
maintainer  gh pr list --search "is:open draft:false label:approved"
            merge -> tag -> ship up to the production boundary
```

### The four states this mode moves through

1. **Draft** — the developer opens the PR immediately, before the work is
   finished, so it is visible from the start. `gh pr ready <N>` clears draft
   status once it's ready for a review.
2. **Not draft, no verdict** — waiting for review. This is the state the
   reviewer's queue is built from: `gh pr list --search "is:open draft:false
   -label:approved"`. The review itself answers three questions, not two —
   standards, spec, and whether the diff's own evidence (its tests) actually
   proves what it claims; `roles/reviewer.md` has all three.
3. **Back to draft** — `gh pr ready <N> --undo`, paired with a `--comment`
   review that explains why. Native `changes_requested` is unreachable on a
   PR reviewed by its own author (see "Why there is no `reviewed` label"
   below), so draft status carries what it would have meant instead. The PR
   stays here until the developer re-asks with `gh pr ready <N>`.
4. **Not draft, `approved` label** — `gh pr edit <N> --add-label approved`.
   This is what the maintainer's queue is built from: `gh pr list --search
   "is:open draft:false label:approved"`.

## Two-account mode (an upgrade, not the default)

```
human       puts `ready` on an issue                      ← the only starting point
   |
developer   gh issue list --label ready --search "no:assignee -label:needs-decision"
            gh pr create --draft   …work…   gh pr ready <N>
            gh pr edit <N> --add-reviewer <login from AGENTS.md>
                 |
reviewer    gh pr list --search "is:open draft:false review-requested:@me"
            gh pr review <N> --approve            -> maintainer
            gh pr review <N> --request-changes    -> back to developer
                 |
developer   fixes, then gh pr edit <N> --add-reviewer <login>   (re-request)
                 |
maintainer  gh pr list --search "is:open review:approved"
            merge -> tag -> ship up to the production boundary
```

### The four GitHub states this mode moves through

1. **Draft** — the developer opens the PR immediately, before the work is
   finished, so it is visible from the start. `gh pr ready <N>` clears draft
   status once it's ready for a review.
2. **Review requested** — `gh pr edit <N> --add-reviewer <login>` asks a
   specific reviewer. This is the state the reviewer's queue is built from:
   `gh pr list --search "is:open draft:false review-requested:@me"`.
3. **`changes_requested`** — the result of `gh pr review <N>
   --request-changes`. The PR stays in this state until the developer acts;
   nothing about it changes on its own.
4. **`approved`** — the result of `gh pr review <N> --approve`. This is what
   the maintainer's queue is built from: `gh pr list --search "is:open
   review:approved"`.

## The round trip, and why it needed a fix

This section is two-account-mode history: it is about `--add-reviewer`, which
single-account mode does not use for its round trip at all — see above.

The first draft of this flow had the developer re-request review with `gh pr
review --request-review`. That flag does not exist — `gh pr review` only
offers `--approve`, `--comment` and `--request-changes`. It also had the
reviewer look for new work with a search on `review:none`, which is wrong
independently: after `--request-changes` a PR's review state is
`changes_requested`, not `none`, and it stays `changes_requested` — so that
search would never have shown the PR again. The loop this tool exists to
support had no second lap.

The fix reuses GitHub's own review-request mechanism instead of inventing a
second one. `gh pr edit --help` describes `--add-reviewer` as adding **or
re-requesting** reviewers by login — one command serves both the first ask and
every later one:

```bash
gh pr edit <N> --add-reviewer <login>
```

GitHub clears a review request the moment that reviewer submits a review —
whether that review approves or requests changes — which is what empties the
reviewer's queue in both directions. The PR only returns to the queue when the
developer re-requests, i.e. runs that same command again after fixing
whatever the review flagged.

## The label vocabulary

| Label | Sits on | Set by | Means |
|---|---|---|---|
| `ready` | Issue | **only a human** | may be picked up |
| `needs-decision` | PR or issue | anyone | waiting on a human decision — on an issue, a hold: no session picks it up until the human removes the label or closes the issue. A session that paused on it keeps the issue and is not woken by that — tell it in its window (the issue comment says how) |
| `approved` | PR | reviewer, **single-account mode only** | cleared for the maintainer |
| `scout` | Issue | **only a human**, next to `ready` | answer with a report, not a change — optional |

The first two exist in both modes, and so does `scout` where a project uses
it: a `scout` issue ends in a comment on the issue, or in a PR that only adds
`docs/reports/<topic>.md` and is reviewed on its sources instead of tests
(`roles/developer.md`, "A report instead of a change"). Draft status, the review request, and
`review:approved` / `review:changes_requested` are all native GitHub states,
already visible in `gh pr list`, and none of them need maintaining by hand —
in two-account mode that covers the whole loop, and the `approved` label
plays no part at all.

## Why there is no `reviewed` label — and why `approved` is not that label

The obvious alternative design tracks review outcome with labels:
`needs-review`, `reviewed`, `changes-requested`. This tool doesn't, in
two-account mode, because GitHub already carries that state natively, and a
label duplicating it can drift from the truth (nobody removes it, or two
labels end up applied at once).

The concrete fact that makes the native state usable at all is the same one
that makes the reviewer's own account necessary in that mode. Measured
directly, on a PR authored by the account attempting to review it:

    $ gh pr review 42 --approve
    failed to create review: Can not approve your own pull request

GitHub refuses both `--approve` and `--request-changes` on your own pull
request. Without a second account for the reviewer, this design would have had
no native "approved" or "changes requested" state to search on for anything a
single account authored — and would have had to fake both with labels, which
is exactly the fragility this design avoids. The reviewer's separate account
(`docs/setup.md`) is what lets the flow run on GitHub's real review state
instead — in two-account mode.

Single-account mode does not have that second account, so it does not have
that native state either — `--approve` is locked on a shared account exactly
as shown above, confirmed again directly, and so is `--request-changes`
(`Can not request changes on your own pull request`). This is the difference
that matters: the `reviewed`/`needs-review`/`changes-requested` labels this
section argues against would have **duplicated** a GitHub state that already
existed, and could silently drift from it. `approved` **replaces** a state
that does not exist here at all — there is nothing for it to drift from,
because there is nothing native underneath it to disagree with. Adding a
label back in looks like the reversal this section just argued against; it
is the opposite move, made necessary by the same account constraint that
makes it safe.

## Multiple agents in the same role

Nothing stops two developer sessions from running against the same repository
at once, and `roles/maintainer.md` calls that out explicitly for its own role
("There is exactly one of you per repository") precisely because it is *not*
true for developer or reviewer. Two developers reading the same `ready` list
can reach for the same issue; two reviewers reading `review-requested:@me` can
reach for the same PR. `docs/concept.md` explains why the worktree split
doesn't touch this: it keeps roles from colliding on files, not a role from
colliding with itself.

The GitHub assignee alone can't fix this: two `--assignee @me` calls seconds
apart both succeed, because the assignee field is a signal, not a lock —
whoever reads `no:assignee` second still sees the issue as free until the
first call lands, and the collision surfaces only later, after both sessions
have already done the work.

The fix is a git ref instead. Pushing a new ref is a single operation the
forge serializes on its own server: of two simultaneous pushes to the same
new `refs/claims/...` ref, exactly one can ever win, and the forge decides —
no client-side timing, no assumption about who asked first, nothing for a
later reconciliation step to untangle. Measured against a disposable
repository (2026-09-21, `scripts/burst-claim.sh`), not assumed:

| Measurement | Result |
|---|---|
| 10 runs × 3 concurrent pushes to the same new ref | always exactly 1 winner, 0 deviations |
| 1 run × 5 concurrent pushes | 1 winner, 4 rejected |
| Delete the ref, claim again | works |
| Push against an already-held ref | rejected, ref unchanged |
| Duration | claim 1.4s · release 1.3s · look up 0.8s |

So the developer pushes a claim ref for the issue before opening the draft
PR, and the reviewer pushes one for the PR before starting the review —
`roles/developer.md` and `roles/reviewer.md` have the exact commands and the
three ways this goes wrong in practice (checking the push's exit code rather
than its message text, never `--force`, and a zsh refspec quoting trap).
Because the ref is what now decides, the old reconciliation rule — the lower
of two duplicate PR numbers wins — no longer applies: two sessions can no
longer both start the same issue, so there is nothing left for a PR-number
tiebreak to resolve.

The GitHub assignee stays anyway, but only as a display: it's the one of the
two a human sees glancing at the issue or PR in a browser, where a ref is
invisible. It remains the cheap prefilter the `no:assignee` search runs
against — unchanged — while the ref is what actually decides.

A claim that's never released is worse than no claim at all: it hides the
issue or PR from every other session until it is old enough for a takeover —
days, not a safety net for the next few minutes; see "Orphaned claims" below.
A developer who abandons an issue releases it; a reviewer releases a PR the
moment its review is submitted, since — unlike an issue closing a PR —
nothing here does that step automatically.

## Across machines

Nothing above assumes one computer. A claim is a push to
`refs/claims/issue-<N>` on the forge, and the forge serializes pushes to a new
ref no matter where they come from: a developer on a laptop and one on a
server compete for an issue exactly as two sessions on one machine do, and
exactly one wins. Issues, PRs, labels and reviews live on the forge too. So
running agents on several machines needs no central process, no SSH
orchestration and no shared state beyond the repository — clone it on each
machine, install `tender` there, and start sessions as usual.

**What each machine needs of its own:** its own clone under
`TENDER_PROJECTS_DIR`, its own tmux server, its own keychain entries (the
reviewer token, named credentials — `docs/setup.md`, sections 7 and 8), and its
coding agent's trust in that clone (`docs/limits.md`, "A coding agent may ask
whether to trust a folder").

**Give each machine's sessions a suffix.** A worktree's branch is named after
it — `<repo>-<role>[-<suffix>]`, the same name on every machine. Two machines
that both run `tender acme developer` push to one remote branch,
`acme-developer`: the second push is refused as not a fast-forward, and a
`git pull` to get past it mixes two sessions' work in one branch and one PR. `tender acme developer laptop` on one and `tender acme
developer server` on the other keep them apart. The same holds for a reviewer
on two machines. The maintainer needs none: there is one per repository, on
whichever machine it runs (see the top of `docs/limits.md`).

**What sees every machine, and what only this one:**

| Command | Sees |
|---|---|
| `tender status` — issues, reviews, approvals, decisions | every machine: it asks the forge |
| `tender status` — "agent PRs open" | this checkout's count (`docs/limits.md`, `max-open-prs`) |
| `tender claims <repo>` | every machine: it reads the claim refs on the forge |
| `tender list`, `attach`, `restart`, `drop` | this machine only: its worktrees and its tmux server |
| the `max-open-prs` start refusal ("another developer session running") | this machine only |

There is no overview of the sessions running on *other* machines — which
windows are open where, which agent is waiting on you there. That is the one
real gap, and closing it (for example `tender status --remote <ssh-alias>`) is
its own piece of work, not something the coordination needs.

## Orphaned claims: age-based release

A held claim used to have no way back short of a human running the release
command by hand — `docs/limits.md` documented that as a limit, not a
mechanism. It still can't tell a session that crashed from one still working
quietly, but it no longer has to wait forever to find out: every claim
already carries its own timestamp (`claim <ISO-8601 UTC>`, in the blob
`roles/developer.md`'s claim push writes), and nothing ever read it back
until now.

`roles/developer.md` and `roles/reviewer.md` have the exact mechanism: a
session whose claim attempt loses reads the timestamp on the ref it lost to
(`git ls-remote` for the hash, then `git fetch` and `git cat-file blob` for
the content — `ls-remote` alone leaves the object unfetched, and reading it
straight off that fails with `could not get object info`). Older than
`claim-timeout-days` in `AGENTS.md` (default **2**, see `docs/limits.md` for
why days rather than minutes) and the claim counts as orphaned: the session
releases it and reclaims it in two ordinary pushes — never `--force` — and
says so on the issue or PR, so a human reading it later can see whose claim
it was and why it changed hands.

`tender claims <repo>` (`--json` for a script or a GUI) lists every claim this
way — name, timestamp, age, and whether it's past the threshold — without
waiting for a second session to collide with one first. `tender claim-release
<repo> <N>` runs the same release-then-reclaim by hand, and refuses exactly
where the mechanism above would: a claim younger than `claim-timeout-days`.

Taking over an orphaned claim can still be wrong — the session that held it
may be alive and simply slow, not gone. That is the reason
`roles/developer.md`'s "Working" step 1 and `roles/reviewer.md`'s verdict
step both check, right before the action that would otherwise ship
duplicated work, whether the claim they started with is still theirs. The
age-based release makes eviction possible; that check is what keeps eviction
from silently producing a second PR or a second review.
