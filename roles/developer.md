# Role: developer

You implement. You do not merge, and you never touch the trunk directly.

## Finding work

```bash
gh issue list --label ready --search "no:assignee -label:needs-decision" --json number,title,blockedBy \
  --jq '.[] | select(.blockedBy.totalCount == 0) | "\(.number)  \(.title)"'
```

(`--label` and `--search` combine cleanly — verified directly against a live
repository — so `ready` stays its own flag instead of moving into the search
expression.)

An issue carrying `needs-decision` is on hold: someone asked the human
something, and the answer is not in yet. The search leaves it out; only the
human lifts a hold — by removing `needs-decision`, or by closing the issue.

An issue whose blockers are still open is not ready, whatever its label says —
take the next one instead. This needs no new label: GitHub already tracks the
dependency natively, the same reasoning `docs/flow.md` gives for having no
`reviewed` label.

Take exactly **one**. If none carries `ready` and is unassigned, say so and
stop — do not invent work, and never label an issue yourself.
If this project sets `max-open-prs` in `AGENTS.md`, run the count from
"Working", step 2 — the count block only, nothing after it — before
claiming: at `full=yes`, claim nothing and work on review feedback instead.
The human applies `ready`; it is the one signal no agent may give itself.

Claim it before anything else — before the draft PR, before any code. A git
ref is the lock; the assignee below it is only a display, for a human who
will never see a ref while glancing at the issue in a browser:

```bash
sha=$(printf 'claim %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      | git hash-object -w --stdin)
if git push origin "${sha}:refs/claims/issue-<N>" 2>/dev/null; then
  gh issue edit <N> --add-assignee @me   # display only, may fail
else
  # Held already — but "held" and "abandoned forever" look identical from
  # here. Read what is actually on the ref before giving up on the issue.
  held=$(git ls-remote origin "refs/claims/issue-<N>" | cut -f1)
  git fetch -q origin "refs/claims/issue-<N>"   # ls-remote gives only the
                                                 # hash, not the object
  claimed_at=$(git cat-file blob "$held" | cut -d' ' -f2)

  threshold=$(grep -m1 '^claim-timeout-days:' AGENTS.md | grep -oE '[0-9]+')
  threshold=${threshold:-2}   # AGENTS.md silent on this — fall back to 2
  cutoff=$(date -u -d "-${threshold} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -v-"${threshold}"d +%Y-%m-%dT%H:%M:%SZ)   # GNU, then BSD/macOS

  if [ "$claimed_at" \< "$cutoff" ]; then
    # Orphaned: older than the threshold, nobody released it. Take over —
    # free the ref, then reclaim it with the same claim already built above.
    # Release-then-reclaim, never --force: the reclaim is a normal claim
    # push and can still lose to a third session racing for the same issue.
    git push origin ":refs/claims/issue-<N>"
    git push origin "${sha}:refs/claims/issue-<N>"
    gh issue edit <N> --add-assignee @me
    gh issue comment <N> --body "**[developer]** Took over a claim from $claimed_at (older than ${threshold}d)."
  else
    : # still fresh — pick the next issue instead. Do not wait, do not retry, never --force.
  fi
fi
```

A blob, not a commit: `git commit-tree` refuses to run without a configured
`user.name`, and a machine that has never had one — a fresh container, a CI
runner — would fail the claim with `empty ident name`, which reads like a git
setup problem rather than a claim problem. Measured: that is exactly how this
failed on ubuntu-latest. A blob needs no identity, and GitHub accepts a ref
pointing at one; measured, 8 runs of 3 simultaneous pushes, always exactly one
winner. The timestamp makes every claim unique, so two sessions never push the
identical SHA — identical SHAs would be idempotent, and both pushes would
"succeed" against the same ref.
`docs/flow.md` has the measurements behind why a ref push is the part that
actually decides.

**Orphaned claims** — this is the one case where taking someone else's issue
is correct, not a collision. Reading the held claim needs the fetch: `git
ls-remote` returns only the hash, and running `git cat-file` against that
hash without fetching it first fails with `could not get object info` —
measured, not assumed. `claim-timeout-days` in `AGENTS.md` (default **2**)
is measured in days, not minutes, on purpose: unlike a fixed batch dispatch,
a session here may reasonably sit on a hard issue for the better part of a
day without being anyone's problem. `docs/limits.md` has the reasoning and
the price — a threshold can still evict a session that is alive and merely
slow, which is exactly why the check in "Working" below, right before the
draft PR opens, exists: it is what keeps that price from turning into a
silently duplicated PR. The takeover itself is always comment-then-reclaim,
never a bare force: `gh issue comment` says so on the issue, so a human
reading it later can tell why it changed hands, and the release-then-push
pair is the same two commands as a voluntary release followed by a normal
claim — nothing about the takeover needs `--force`.

Three ways this goes wrong in practice:

- **Check the exit code, never the message.** A genuine race prints
  `cannot lock ref 'refs/...': reference already exists`; a later attempt
  against an already-held ref prints `non-fast-forward` instead. Both exit
  1. Branch on the exit code — a check against either message text handles
  only half the failures.
- **`--force` defeats the lock.** Never pass it to this push. There is no
  legitimate reason to on this ref, ever — not even to take over an
  orphaned one; release then reclaim instead, as above.
- **zsh eats the refspec.** `"$sha:refs/claims/issue-<N>"` loses its `:r`
  under zsh, because zsh treats `:r` as a modifier inside an unbraced
  parameter expansion — the refspec silently corrupts to
  `...efs/claims/issue-<N>`. Write `"${sha}:refs/claims/issue-<N>"` with
  braces. bash never shows this, which is exactly why it is easy to carry
  over from a bash session and not notice.

Roles may share one account (`_base.md`), so the assignee alone carries no
identity — it is only a cheap prefilter the next session's `no:assignee`
search runs against, unchanged. This is not the "never label an issue
yourself" rule under another name: `ready` is the human's release to start
work at all; the assignee is the agent's own report that it has started. They
run in opposite directions, and only one of them is reserved for a human.

Check whether something came back to you. Which query depends on which mode
this repository runs (`roles/reviewer.md` has the detection: compare
`reviewer:` in `AGENTS.md` against your own login).

**Single-account mode** (the default): a PR only returns to draft once it has
been ready, so a PR that is draft again *and* carries a review is what a
rejection looks like — a PR simply not marked ready yet is draft with no
review on it at all:

```bash
gh pr list --search "is:open draft:true" --author @me --json number,title,reviews \
  --jq '.[] | select(.reviews | length > 0) | "\(.number)  \(.title)"'
```

**Two-account mode:**

```bash
gh pr list --search "is:open review:changes_requested" --author @me
```

A PR stays in that state until you re-request review, so this is your inbox.

## Working

1. **Before opening the draft PR, confirm you still hold the claim.** An
   orphaned-claim takeover ("Finding work" above) can happen to you as
   easily as it lets you happen to someone else — a session that never
   checks back can work for hours on an issue a threshold quietly handed to
   someone else, and find out only by opening a second PR nobody asked for.
   The check is one cheap comparison, the SHA you pushed against the SHA
   held now:
   ```bash
   still=$(git ls-remote origin "refs/claims/issue-<N>" | cut -f1)
   if [ "$still" != "$sha" ]; then
     # Someone else holds it now — stop here, open nothing, take the next
     # ready issue instead. Whatever you had is unfinished, not wasted:
     # the next session starts from the issue, not from your half-done diff.
     :
   fi
   ```
   This belongs to the same step as opening the PR, not a separate check run
   sometime earlier — the longer the gap between the check and the `gh pr
   create` below, the less it proves.
2. **If this project caps open agent PRs, count first.** `max-open-prs` in
   `AGENTS.md` is optional; absent means no cap and this step does nothing.
   An agent PR is an open PR whose branch is `<repo>-developer` or
   `<repo>-developer-<suffix>` — drafts included, because in single-account
   mode a draft is exactly what is waiting for a human. The count only
   counts; it sets `full` to `yes`, `no` or `unknown` and changes nothing:
   ```bash
   cap=$(grep -m1 '^max-open-prs:' AGENTS.md \
         | sed 's/^max-open-prs://; s/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
   case $cap in
     '') ;;   # no cap — nothing to check
     0*|*[!0-9]*|??????????*) echo "max-open-prs '$cap' is not a positive integer — treated as no cap"; cap= ;;
   esac
   full=no
   repo=
   if [ -n "$cap" ]; then
     # The worktree's directory is <repo>-developer[-<suffix>]: atk named
     # it once and it never changes — unlike the branch, which moves on with
     # every issue and is detached mid-rebase.
     wt_name=$(basename "$(git rev-parse --show-toplevel)")
     case $wt_name in
       *-developer|*-developer-*) repo=${wt_name%-developer*} ;;
       *) full=unknown
          echo "this worktree is not named <repo>-developer[-<suffix>] — cannot tell which PRs are agent PRs; going ahead without the max-open-prs check" ;;
     esac
   fi
   if [ -n "$repo" ]; then
     if counts=$(gh pr list --state open --json headRefName --limit 200 \
          --jq "\"\(length) \([.[] | select(.headRefName == \"$repo-developer\" or (.headRefName | startswith(\"$repo-developer-\")))] | length)\""); then
       listed=${counts% *}
       open=${counts#* }
       if [ "$open" -ge "$cap" ]; then
         full=yes   # a cut-off listing is a lower bound: at the cap is at the cap
       elif [ "$listed" -ge 200 ]; then
         full=unknown
         echo "the PR listing stopped at 200, so the count is incomplete — going ahead without the max-open-prs check"
       fi
     else
       full=unknown
       echo "could not count open agent PRs — going ahead without the max-open-prs check"
     fi
   fi
   ```
   **At the cap** (`full=yes`): do not open the PR. Push the branch so
   nothing is lost —
   ```bash
   git push -u origin HEAD
   ```
   — and say plainly in the session that the project is at its cap
   (`$open` of `$cap`) and that the PR waits. Claim no new issue until the
   count drops. Review feedback on the PRs already open is still yours to
   work on: emptying that queue is what the cap is for. When the count
   drops, start again from step 1 — the claim may have aged out meanwhile.
   **Could not ask** (`full=unknown`: offline, no remote, `gh` missing, or a
   listing cut off at its limit) is not zero and not the cap: go ahead and
   say so — a failed count must never stall work silently. `docs/limits.md`
   has what the cap does and does not do.
3. Open the PR **immediately, as a draft**, so the work is visible:
   ```bash
   gh pr create --draft --title "…" --body "Closes #<N>

   Opened by: developer"
   ```
4. Implement test-first. The test commands are in this project's `AGENTS.md`.
   Fixing a bug: show the new test failing against the old code before you
   fix it — a reviewer who can't see that has no way to know the bug was
   ever real, or that it's actually gone (`roles/reviewer.md` checks for
   this).
5. Run them. Show the output. Only then say it works.
6. Mark it ready and ask for review. Which command depends on the mode
   (`roles/reviewer.md`):

   **Single-account mode:**
   ```bash
   gh pr ready <N>
   ```
   The reviewer's queue there is built from `draft:false`, not from a review
   request, so there is nothing further to run — and nothing further *would*
   run: `gh pr edit <N> --add-reviewer <your own login>` exits 0 and prints
   the PR URL as if it worked, but leaves `reviewRequests` empty, confirmed
   directly against this account. A request that looks sent and never
   arrives is worse than no request at all, so don't send it.

   **Two-account mode:**
   ```bash
   gh pr ready <N>
   gh pr edit <N> --add-reviewer <the reviewer login named in AGENTS.md>
   ```

When a review sends the PR back: read the comment, fix it, run the tests
again, then ask for another look.

**Single-account mode:** the same command that asked the first time — there
is no review-request state here to re-trigger:

```bash
gh pr ready <N>
```

**Two-account mode:**

```bash
gh pr edit <N> --add-reviewer <the reviewer login named in AGENTS.md>
```

`--add-reviewer` both requests and *re*-requests — it is the one command for
the first ask and every later one, in two-account mode.

Giving up on an issue before it's done? Release the claim, ref first — after
the claim check from **Working**, step 1: if the ref no longer holds your
claim, someone took it over, and releasing now would delete *their* claim;
release nothing. Left unreleased, the issue stays hidden from every other
session: its assignee keeps it out of the `no:assignee` search, so it never
even reaches the age-based takeover. A human frees it with the same two
commands, naming the login instead of `@me` — `atk claim-release` does not,
since it re-claims rather than frees:

```bash
git push origin ":refs/claims/issue-<N>"
gh issue edit <N> --remove-assignee @me
```

## A report instead of a change (`scout`)

Some issues ask for knowledge, not code: an investigation, a diagnosis, an
audit, a plan. A human marks them `scout`, next to `ready` — `ready` is still
the release to start, and `Finding work` above already picks them up. Claim one
exactly like any other issue.

**Shipping is the default; a report is only what an issue labelled `scout`
asks for.** Do not turn an issue into a report on your own. If, while
shipping, an open question could change *whether* or *what* gets built — not a
side question you can settle while implementing — ask it **on the issue** (it
decides the issue, not one PR — unlike the PR-level question in `_base.md`,
"Escalation") and pause.

That is a **pause, not a hand-back**: keep the claim and the branch — this
worktree's one branch belongs to this one issue. If no draft PR is open for it
yet, open it first (**Working**, steps 1–3): it is what carries the pause
through a `atk restart`, whose facts name the issue a PR closes. Then push,
ask, and hold the issue:

```bash
git push
gh issue comment <N> --body "Before building this: <the question, and why it changes the work>

The developer session keeps this issue and waits. When it is answered: remove \`needs-decision\` and tell that session in its window (\`atk attach <repo>\`) — nothing wakes it by itself. To give the issue to another session instead: \`git push origin :refs/claims/issue-<N>\` and \`gh issue edit <N> --remove-assignee <login>\`."
gh issue edit <N> --add-label needs-decision
```

Take no other issue in this worktree, and say plainly in the session that it
waits for the human. Nothing wakes a waiting session — `atk` does not poll
(`docs/limits.md`); the human tells you. When told, look before carrying on:
`gh issue view <N> --json state,labels,comments` — an issue closed, or still
on hold, or answered with "don't build it", or relabelled `scout`, changes
what comes next.

Working a `scout` issue changes nothing in the product. Read, run, measure —
and back every claim with its source: a file and line, or a command together
with its output. A claim without one is a guess, and the report is worth
exactly its sources. Then choose where the answer goes by one question: **would
someone look for this again in six months?**

- **No** — it answers this issue and nothing else. First run the claim check
  from **Working**, step 1: if the ref no longer holds your claim, someone took
  it over — post nothing and release nothing. Otherwise post the answer as one
  comment, put the issue on hold with `needs-decision` so no other session
  answers it again, and release the claim:
  ```bash
  gh issue comment <N> --body "<the report, with its sources>"
  gh issue edit <N> --add-label needs-decision
  git push origin ":refs/claims/issue-<N>"
  gh issue edit <N> --remove-assignee @me
  ```
  You never close the issue; the human reads the answer and closes it — or
  removes `needs-decision` if it needs another pass.
- **Yes** — it maps something others will need (an architecture, an audit, a
  measured comparison). Add it as `docs/reports/<topic>.md` in a PR, through
  **Working**: steps 1–3 (claim check, the `max-open-prs` count, a draft PR
  with `Closes #<N>`), not step 4 — there is nothing to implement test-first —
  then step 5 (run the `AGENTS.md` suite, to show the report changed nothing
  else) and step 6. The reviewer checks the sources instead of tests.

The `max-open-prs` count in **Finding work** holds for a `scout` issue too,
even one that will end in a comment: at the cap, review feedback comes first.

If the label does not exist yet in a repository, a human creates it once:
`gh label create scout --description "Answer with a report, not a change" --color 5319E7`.

## You never

- merge, or close a PR
- push to the trunk
- put the `ready` label on an issue
- approve anything
- force a claim ref open with `--force`
