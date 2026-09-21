# Flow

```
human       puts `ready` on an issue                      ← the only starting point
   |
developer   gh issue list --label ready --search no:assignee
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

## The four GitHub states the flow moves through

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

## The two labels

| Label | Sits on | Set by | Means |
|---|---|---|---|
| `ready` | Issue | **only a human** | may be picked up |
| `needs-decision` | PR or issue | anyone | waiting on a human decision |

That's the entire label vocabulary. Draft status, the review request, and
`review:approved` / `review:changes_requested` are all native GitHub states,
already visible in `gh pr list`, and none of them need maintaining by hand.

## Why there is no `reviewed` label

The obvious alternative design tracks review outcome with labels:
`needs-review`, `reviewed`, `changes-requested`. This tool doesn't, because
GitHub already carries that state natively, and a label duplicating it can
drift from the truth (nobody removes it, or two labels end up applied at
once).

The concrete fact that makes the native state usable at all is the same one
that makes the reviewer's own account necessary. Measured directly, on a PR
authored by the account attempting to review it:

    $ gh pr review 42 --approve
    failed to create review: Can not approve your own pull request

GitHub refuses both `--approve` and `--request-changes` on your own pull
request. Without a second account for the reviewer, this design would have had
no native "approved" or "changes requested" state to search on for anything a
single account authored — and would have had to fake both with labels, which
is exactly the fragility this design avoids. The reviewer's separate account
(`docs/setup.md`) is what lets the flow run on GitHub's real review state
instead.

## Multiple agents in the same role

Nothing stops two developer sessions from running against the same repository
at once, and `roles/maintainer.md` calls that out explicitly for its own role
("There is exactly one of you per repository") precisely because it is *not*
true for developer or reviewer. Two developers reading the same `ready` list
can reach for the same issue; two reviewers reading `review-requested:@me` can
reach for the same PR. `docs/concept.md` explains why the worktree split
doesn't touch this: it keeps roles from colliding on files, not a role from
colliding with itself.

The fix reuses the GitHub assignee for state rather than identity.
`roles/_base.md` established that roles may share one account, so `--assignee
@me` cannot tell two developer sessions apart — but it doesn't need to. It only
needs to say an issue or PR is *taken*, which the next session's `no:assignee`
search then excludes. So the developer assigns itself an issue before opening
the draft PR, and the reviewer assigns itself a PR before starting the review.

The claim is a signal, not a lock, so two sessions can still land on the same
issue seconds apart. If a second draft PR for the same issue turns up anyway,
the **lower PR number wins**: the other session closes its PR, removes its
assignment, and takes the next issue instead — no lock, no timestamp, the
collision becomes visible rather than silently duplicated work.

A claim that's never released is worse than no claim at all: it hides the
issue or PR from every other session forever. A developer who abandons an
issue releases it; a reviewer releases a PR the moment its review is
submitted, since — unlike an issue closing a PR — nothing here does that step
automatically.
