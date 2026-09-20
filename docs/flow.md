# Flow

```
human       puts `ready` on an issue                      ← the only starting point
   |
developer   gh issue list --label ready
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

    $ gh pr review 163 --approve
    failed to create review: Can not approve your own pull request

GitHub refuses both `--approve` and `--request-changes` on your own pull
request. Without a second account for the reviewer, this design would have had
no native "approved" or "changes requested" state to search on for anything a
single account authored — and would have had to fake both with labels, which
is exactly the fragility this design avoids. The reviewer's separate account
(`docs/setup.md`) is what lets the flow run on GitHub's real review state
instead.
