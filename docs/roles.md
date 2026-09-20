# Roles

Three roles, plus `none` for a worktree that should not be worked in.

| Role | Worktree sits on | Does |
|---|---|---|
| `developer` | a feature branch | takes an issue, implements it, opens the PR |
| `reviewer` | `review/<N>` | checks the PR, approves or sends it back |
| `maintainer` | its own branch (`$repo-maintainer`) | merges, tags, ships up to the production boundary |

## Permissions

| | developer | reviewer | maintainer |
|---|:--:|:--:|:--:|
| Open a PR (`--draft`), `gh pr ready` | yes | — | — |
| Comment | yes | yes | yes |
| `--approve` / `--request-changes` | no | yes | — |
| Merge, or close a PR without merging | no | no | yes |
| Tag, build, ship up to the production boundary | no | no | yes |
| Create an issue | only after asking | only after asking | only after asking |

## What each role never does

From `roles/developer.md`:

- merge, or close a PR
- push to the trunk
- put the `ready` label on an issue
- approve anything

From `roles/reviewer.md`:

- implement the fix itself
- merge
- approve something it has not run

From `roles/maintainer.md`:

- implement
- merge anything that is not approved
- cross the production boundary on its own judgement

## Why no separate `deployer`

A `maintainer` and a `deployer` would share the same production boundary and
run one immediately after the other — merging and releasing are the same
gate, just at different moments — so splitting them into two roles buys
nothing but a worktree and a handover. This doesn't depend on the trunk
branch: a maintainer merges through the forge (`gh pr merge`), not with a
local `git merge`, so it was never the branch that made a second role
pointless. See `docs/limits.md` for why "one maintainer" is still worth
sticking to, even though nothing enforces it.

## What is agreed, and what is enforced

Almost every boundary here is **agreed**, not enforced. Your token can do more
than your role allows; what stops it is the role file it was given. That is
sufficient for reversible things — an unwanted merge is one `git revert` away.

Two boundaries are **enforced**, and it is worth knowing which:

- **A reviewer cannot approve their own pull request.** The forge refuses it.
  That is why the reviewer runs under a second account (`docs/setup.md`).
- **The production boundary**, if you set up a protected environment
  (`mdt init` offers this). The job halts and waits for a named human,
  whoever triggered it — including you. For an action that reaches real users
  and cannot be recalled, that is the point.

Everything else is a sentence in a Markdown file, and you should read it that way.
