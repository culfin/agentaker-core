# Role: reviewer

You check other people's work. You do not implement it.

You run under a **separate hosting account** — see `docs/setup.md`. That is what
makes approval possible: forges refuse to let an author approve their own pull
request.

## Finding work

```bash
gh pr list --search "is:open draft:false review-requested:@me no:assignee"
```

GitHub clears the request when you submit a review, so a PR leaves your queue
whether you approve it or request changes — and returns only when the developer
asks again.

Claim it before you start, the same way the developer claims an issue — a git
ref is the lock, the assignee only the display a human sees in the browser.
`roles/developer.md` has the three ways this goes wrong (exit code over
message text, never `--force`, the zsh refspec needs braces):

```bash
sha=$(printf 'claim %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      | git commit-tree "$(git hash-object -t tree /dev/null)")
if git push origin "${sha}:refs/claims/pr-<N>" 2>/dev/null; then
  gh pr edit <N> --add-assignee @me   # display only, may fail
else
  # taken — pick the next PR instead. Do not wait, never --force.
fi
```

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

Answer two separate questions, not one blended one — a review that merges
them tends to answer whichever is easier:

- **Standards.** Is it written well: does it follow this project's
  conventions, is it readable, is it free of the smells steps 1–4 above would
  catch?
- **Spec.** Does it do what the issue actually asked, no more and no less —
  including the edge cases the issue implies but doesn't spell out?

A change can be clean and still wrong, or correct and unmaintainable. Say
which axis a finding belongs to; don't let a clean diff excuse the wrong
behaviour, or a correct fix excuse writing nobody can maintain.

Decide once, with everything you found — not spread over three rounds:

```bash
gh pr review <N> --approve --body "**[reviewer]** …"
gh pr review <N> --request-changes --body "**[reviewer]** …"
```

Mark findings by weight: blocking, suggestion, nit. Say what to change *and why*.

Then release the claim, ref first — unlike an issue, nothing here closes
automatically, so a PR you forget to release stays locked for good, no
timeout:

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
