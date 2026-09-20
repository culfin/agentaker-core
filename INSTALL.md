# Setting up mandate

**This file is written for a coding agent, not for you.** Paste the block from
the README into your agent and it will read this and walk you through.

You can also do everything here by hand — `docs/setup.md` and
`docs/adding-a-project.md` describe the same steps for a human.

---

## Instructions for the coding agent

You are setting up `mandate` for a human's project. You are a guide, not
an installer. Work through the phases below in order.

### How you must behave

- **Propose, never assume.** Show what you found, say what you conclude, wait for
  a yes before you act.
- **One phase at a time.** Do not run ahead. Do not batch confirmations.
- **Never invent a value.** If you cannot find something in the repository, say
  so and ask. A wrong production boundary is worse than an empty one.
- **Never create credentials.** You do not create GitHub accounts and you do not
  create or read tokens. Where one is needed, explain and stop.
- **Never commit without asking**, and never push.
- Explain each step in one or two sentences as you go. The human should be able
  to redo this by hand afterwards — that is the measure of whether you did it
  well.

### Phase 1 — Check what is needed

Run these and report what you find:

```bash
git --version
gh --version && gh auth status
tmux -V
```

If any is missing, say which and how to install it on their platform, then stop
until it is there. Do not install anything yourself.

### Phase 2 — Find the project

Ask which repository to set up. Confirm it is a git repository and report its
trunk branch:

```bash
git -C <repo> symbolic-ref --short HEAD
git -C <repo> remote -v
```

If the trunk is not what they expect — a stale `main` next to an active
`development`, say — point that out. Working against the wrong branch is a
failure mode that stays invisible for days.

### Phase 3 — Read the project, then propose

This is the part a script cannot do. **Read, do not guess.**

For the **test commands**, look at: `package.json` scripts, `Makefile`,
`Cargo.toml`, `pyproject.toml`, `.github/workflows/*.yml`, and any CONTRIBUTING
file. Prefer what CI actually runs over what a README claims. If CI runs a
command with a flag that looks load-bearing, keep the flag and say why.

For the **production boundary**, look at: `.github/workflows/` for deploy and
release workflows and how they are triggered, `docker-compose*.yml`, publish
scripts, and any branch that looks like a deployment target. Then present your
reading like this:

> I found `.github/workflows/deploy.yml`, triggered by `workflow_dispatch` with a
> `channel` input defaulting to `staging`. That suggests your production
> boundary is running it with `channel=production`. Is that right?

If you find nothing convincing, say exactly that and ask. An honest "I could not
determine this" is a good answer; a plausible guess is not.

For **review tools**, check whether the project already uses linters,
formatters or review skills, and list what you found.

### Phase 4 — Write `AGENTS.md`

Run `mdt init <repo>` and let it do the mechanical work. When it proposes its
draft, fill in the real values you established in Phase 3 rather than accepting
its guesses. Show the human the finished file before writing it.

The `reviewer:` field stays empty for now — Phase 5 explains why.

### Phase 5 — The reviewer account

Explain this plainly, because it is the step people skip:

> A forge will not let an author approve their own pull request. Every session
> runs under your token, so the reviewer needs a second account. Without it the
> reviewer role cannot approve anything, and the loop stops after the first PR.

Then point them at `docs/setup.md` step 2 and **stop**. They must do this in a
browser: create the account, give it write access, create a fine-grained token,
store it in the OS keychain. You do not do any of it.

When they tell you it is done, ask for the account's login and put it in
`AGENTS.md`:

```
reviewer: their-reviewer-login
```

### Phase 6 — Labels and worktrees

Two labels, in their repository:

```bash
gh label create ready --description "Ready for an agent to pick up" --color 0E8A16
gh label create needs-decision --description "Waiting on a human decision" --color D93F0B
```

Then the three worktrees:

```bash
mdt <repo> developer
mdt <repo> reviewer
mdt <repo> maintainer
```

Explain that these are directories, not processes: they persist, cost only disk,
and the session is whoever happens to be sitting in one.

### Phase 7 — Prove it works

Have them put `ready` on one real issue, then start a developer session:

```bash
gh issue edit <N> --add-label ready
mdt <repo> developer
```

In that session, ask it: *"What is your role, and name one thing you may not
do."* It must answer `developer` and name merging. If it does not, the role did
not reach the model — check `.agents/ROLE` exists and `MDT_TOOL` names a tool
that `launch_command()` in `bin/mdt` knows.

### Phase 8 — Hand over

Summarise in five lines: what was written, what they still owe (the reviewer
account, if Phase 5 is unfinished), and the three commands they will use daily —
`mdt <repo> <role>`, `mdt attach <repo>`, `mdt status <owner>`.

Point at `docs/limits.md` and name the two limits that bite first: one
maintainer per repository, and memory rather than disk as the real ceiling on
concurrent sessions.
