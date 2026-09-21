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
mdt --help
command -v "${MDT_TOOL:-claude}"
```

If any of the first three is missing, say which and how to install it on their
platform, then stop until it is there. Do not install those yourself.

The last line checks the coding agent itself, not just `mdt` — `MDT_TOOL`
(default `claude`) names the binary `mdt` actually launches a session with.
Skip this check and everything else in this file can go fine, right up to
the first `mdt <repo> <role>`, which then opens an empty tmux window with
nothing running in it — that reads as a bug in `mdt`, not a missing tool. If
it's absent, say which command `MDT_TOOL` names and point at `docs/tools.md`
for what's supported, then stop the same way as above.

If `mdt` itself is not found, that's expected — the rest of this file assumes
it exists, but nothing installs it first. Propose the README's quickstart:

```bash
git clone https://github.com/culfin/mandate ~/.mandate
ln -s ~/.mandate/bin/mdt ~/bin/mdt
```

Check first whether `~/bin` is actually on their `PATH` before proposing that
exact target — it commonly isn't (`~/.local/bin` is the more usual default on
a fresh install), and a symlink created outside `PATH` still leaves `mdt`
reported as "command not found", which reads as a broken install rather than
a wrong directory:

```bash
echo $PATH | tr ':' '\n' | grep -E '/bin$|/\.local/bin$'
```

Link into whichever of those exists; ask before running either command.

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

`mdt init <repo>` in Phase 4 resolves `<repo>` under `MDT_PROJECTS_DIR`
(default `~/Projekte`) — it takes a name, not the path you just confirmed
above. Check the repository actually lives there; if it doesn't, tell them to
`export MDT_PROJECTS_DIR=<parent directory>` before Phase 4, or `mdt init`
fails with "not a git repository" against a path that was never theirs.

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

`mdt init <repo>` only offers a yes/no on its own auto-generated draft — it has
no way to take the values you established in Phase 3. So write `AGENTS.md`
yourself instead: show the human the finished file using your Phase 3 findings
(trunk, test commands, production boundary), then write it. Afterwards, run
`mdt init <repo>` anyway — it detects the file already exists, leaves it alone,
and still does the rest (labels, worktrees) that Phase 5 needs in place.

The `reviewer:` field stays empty. Empty means **single-account mode** — the
default this tool now sets up. Everything through Phase 6 runs on it, with no
second account, no browser step, and no token to create; `roles/reviewer.md`
and `docs/flow.md` cover how review works without one. Leave the field
blank here — the optional upgrade after Phase 6 covers filling it in, for
anyone who wants the separation a forge can enforce instead of one the role
files merely ask for.

### Phase 5 — Labels

Two labels, in their repository:

```bash
gh label create ready --description "Ready for an agent to pick up" --color 0E8A16
gh label create needs-decision --description "Waiting on a human decision" --color D93F0B
```

`mdt init` already created the three worktrees back in Phase 4 — do not start
anything here. Explain what they are: directories, not processes. They
persist, they cost only disk, and a session is whoever is sitting in one at
the time. Nothing is running in them yet.

### Phase 6 — Prove it works

Have them put `ready` on one real issue, then start a single developer session:

```bash
gh issue edit <N> --add-label ready
mdt <repo> developer
```

That opens a tmux window and launches their coding agent in it. In that
session, ask it: *"What is your role, and name one thing you may not do."* It
must answer `developer` and name merging. If it does not, the role did not
reach the model — check `.agents/ROLE` exists and `MDT_TOOL` names a tool that
`launch_command()` in `bin/mdt` knows.

To leave the session without stopping it, detach from tmux (`Ctrl-b d` by
default). To come back later: `mdt attach <repo>`.

**Start only this one.** The `reviewer` and `maintainer` worktrees stay idle
until there is work for them — starting all three now means three agents with
nothing to do.

### If you want the separation enforced: a second account

Everything above runs in single-account mode, where the separation between
developer and reviewer is agreed in the role files, not enforced by GitHub —
see `docs/limits.md` for exactly what that does and doesn't buy you. This step
is what upgrades it to enforced: a second account the forge itself refuses to
let approve its own pull request.

Offer it, don't push it — this is not something to talk them into before
they've seen the tool run once:

> A forge won't let an author approve their own pull request. Right now every
> session runs under your token, so review is one account judging its own
> work, backed only by the role files. A second account for the reviewer
> makes GitHub itself refuse a self-approval — you don't have to want that,
> but if you do, here's the step.

If they want it, point them at `docs/setup.md`, "If you want the separation
enforced: a second account", and **stop**. They must
do this in a browser: create the account, give it write access, create a
fine-grained token, store it in the OS keychain. You do not do any of it.

When they tell you it is done, ask for the account's login and put it in
`AGENTS.md`:

```
reviewer: their-reviewer-login
```

That switches every role file from single-account mode to two-account mode —
`roles/reviewer.md` has the detection.

### Phase 7 — Hand over

Summarise in five lines: what was written, what they still owe (the second
account, if the previous section was declined or left for later), and the
three commands they will use daily — `mdt <repo> <role>`, `mdt attach
<repo>`, `mdt status <owner>`.

Point at `docs/limits.md` and name the two limits that bite first: one
maintainer per repository, and memory rather than disk as the real ceiling on
concurrent sessions.
