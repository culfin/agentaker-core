# Roles

Three roles, plus `none` for a worktree that should not be worked in.

| Role | Worktree sits on | Does |
|---|---|---|
| `developer` | a feature branch | takes an issue, implements it, opens the PR |
| `reviewer` | `review/<N>` | checks the PR, approves or sends it back |
| `integrator` | the trunk | merges, tags, ships up to the production boundary |

## Permissions

| | developer | reviewer | integrator |
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

From `roles/integrator.md`:

- implement
- merge anything that is not approved
- cross the production boundary on its own judgement

## Why no separate `deployer`

An `integrator` and a `deployer` would both need the trunk branch checked out,
and git will not check out the same branch in two worktrees at once. They
would also share the same production boundary and run one immediately after
the other — splitting them buys nothing. See `docs/limits.md` for the same
constraint stated as a number: one integrator per repository.

## These boundaries are self-imposed

This is worth saying plainly, because it is easy to read the table above as a
guarantee it is not: **the boundaries in this document are not enforced by
anything outside the session.** The reviewer's GitHub token can merge a PR.
The developer's token can push to the trunk. What stops a role from doing more
than its table row allows is the role file it was started with — a piece of
Markdown the coding agent chooses to follow — not a permission the forge
revoked, and not a check `wtc` runs before letting an action through.

Two things narrow the gap without closing it:

- **The reviewer's account is a real barrier for one specific action**: GitHub
  itself refuses to let an account approve its own pull request. That is why
  the reviewer runs under a second account at all (`docs/setup.md`) — it is
  the one place in this design where a boundary is enforced by the forge
  rather than by the role file.
- **Separate worktrees keep sessions out of each other's files** as a side
  effect of how they're set up, not as an access control.

Everything else — not merging without approval, not crossing the production
boundary, not inventing work, escalating instead of deciding — holds because
the role file says to and the agent follows it. A reader who plans around
these as hard guarantees is planning around something that doesn't exist; plan
around them as a strong, unenforced convention instead, and keep human review
on anything where the difference matters.
