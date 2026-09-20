# Adding a project

This is the page the tool lives or dies by. If setup is a black box, the
person who needs to debug it — you, at 11pm, wondering why a session doesn't
know it's a reviewer — can't. So this walks one project from nothing to a
running session **twice**: once with `wtc init`, once entirely by hand. Both
routes end at the same three files. If you ever need to fix something `wtc
init` did, the by-hand section is what it did, spelled out.

Throughout, `myproject` stands for whatever your repository is called, cloned
under `WTC_PROJECTS_DIR` (default `~/Projekte/myproject`).

## Route A: `wtc init`

```
$ wtc init myproject
Checking what we need:
  ok   git (git version 2.54.0 (Apple Git-157))
  ok   gh (gh version 2.100.0 (2026-09-03))
  ok   tmux (tmux 3.6a)

Project: /Users/you/Projekte/myproject
  trunk:  main
  stack:  unknown

Proposed AGENTS.md:

# Agents in this project

trunk: main
reviewer:            # GitHub login of the account that reviews here — see docs/setup.md

## Test commands

# no test command detected — fill this in

## Production boundary

The one line an agent must never cross on its own. Examples:

    git push origin main:production
    npm publish

Replace this with yours. Until you do, agents will refuse to release.

## Roles

developer reviewer integrator

  Write this file? (y/n) [y]
  written: /Users/you/Projekte/myproject/AGENTS.md — edit the production boundary before you rely on it.
  Create the two labels on the remote? (y/n) [y]
  label created: ready
  label created: needs-decision
  Create worktrees for the three roles? (y/n) [y]
```

(This is the outcome with a GitHub remote that the current `gh` login can
create labels on. Against a repository with no configured remote — as in the
throwaway repository this walkthrough was actually run against — the same two
lines instead read `label ready: already there, or no access` and likewise for
`needs-decision`; `wtc init` treats "the label already exists" and "I
couldn't create it" the same way on purpose, since either way there's nothing
more for it to do, and tells you to check by hand if that surprises you.)

```
  worktree: myproject-developer
  worktree: myproject-reviewer
  worktree: myproject-integrator

Done. Next:
  1. Edit /Users/you/Projekte/myproject/AGENTS.md — above all the production boundary.
  2. Put the reviewer account's login in AGENTS.md — without it the reviewer
     cannot be asked for a review. See docs/setup.md.
  3. Give the reviewer its own account: docs/setup.md
  4. Put 'ready' on an issue:   gh issue edit <N> --add-label ready
  5. Start working:             wtc myproject developer
```

(This transcript is real, run against a throwaway repository — the wording
matches `init()` in `bin/wtc`. `stack: unknown` because the throwaway
repository had no `Cargo.toml`/`package.json`/etc. to detect; a real project
would show something like `Rust Tauri Svelte`, which also changes the
suggested test commands.)

Each step is confirmed separately and skippable: answer `n` and `init` simply
moves to the next step without doing that one — it doesn't print a "skipped"
message, so the way to tell what happened is to read which lines of output
appeared. The final summary does adapt: it tells you to *create* `AGENTS.md`
rather than *edit* it if you declined to write one. If your repository already
has an `AGENTS.md`, `init` won't touch it, and just reminds you what it must
name: trunk, reviewer, test commands, production boundary.

At this point you have `AGENTS.md`, two labels, and three worktrees
(`.worktrees/myproject-developer`, `-reviewer`, `-integrator`) each carrying
its own `.agents/ROLE`. **You still have to open `AGENTS.md` and fill in the
production boundary** — `init` writes a placeholder that refuses to release
until you replace it, deliberately.

## Route B: entirely by hand

Everything Route A did, as individual commands. Useful when `wtc init` isn't
available, when you want to see exactly what changed, or when you're
troubleshooting a project `init` already touched.

**1. Write `AGENTS.md`.** Start from the closest match in `examples/` rather
than from scratch:

```bash
cp examples/python.AGENTS.md myproject/AGENTS.md   # or nextjs, astro, rust-tauri
```

Then edit four things:

- `trunk:` — your actual default branch.
- `reviewer:` — the GitHub login of the reviewer account (`docs/setup.md`
  step 2). Leave it blank and the developer has no one to request review from.
- `## Test commands` — what the reviewer and CI actually run.
- **`## Production boundary`** — the one line an agent must never cross
  without an explicit human instruction: a deploy command, a publish command,
  a push to a protected branch. **This is the line you must not get wrong.**
  Every other mistake in `AGENTS.md` costs you a slower review; a vague or
  missing production boundary costs you a release nobody meant to ship, or —
  just as bad — the tool refusing to release something that was actually
  fine, because it correctly can't tell where the line is.

**2. Commit it.**

```bash
git add AGENTS.md
git commit -m "add AGENTS.md"
```

It belongs to the project, not to any one session, and every coding agent —
not only the ones started through `wtc` — reads it from the checkout.

**3. Create the two labels.**

```bash
gh label create ready --description "Ready for an agent to pick up" --color 0E8A16
gh label create needs-decision --description "Waiting on a human decision" --color D93F0B
```

**4. Create the three worktrees, one per role.** `wtc <repo> <role>` does
this the moment it's asked to start a role that doesn't have a worktree yet —
so this step and "start a session" are the same command; there's no separate
worktree-creation step to run by hand. What it does, if you want to replicate
it directly with git:

```bash
cd ~/Projekte/myproject
git worktree add .worktrees/myproject-developer -b myproject-developer
mkdir -p .worktrees/myproject-developer/.agents
echo developer > .worktrees/myproject-developer/.agents/ROLE
cat roles/_base.md roles/developer.md > .worktrees/myproject-developer/.agents/context.md
echo '.agents/' >> .git/info/exclude
```

Repeat for `reviewer` and `integrator`. (`wtc` does the `_base.md` + role
concatenation with a blank line between the two files, not a bare `cat`; the
difference doesn't matter for reading it, only for exact byte output.)

**5. Start a session and confirm it knows its role.**

```bash
wtc myproject developer
```

This resolves to the worktree from step 4 (creating it first if step 4 was
skipped), writes `.agents/ROLE` and `.agents/context.md` if they're missing or
stale, and launches your coding agent (`$WTC_TOOL`, default `claude`) with
that file as its system prompt — `claude --append-system-prompt-file
<worktree>/.agents/context.md` for Claude Code; see `docs/tools.md` for other
tools. Once it opens, ask it directly:

> *What is your role, and what may you not do?*

A correctly wired session answers from `roles/developer.md`: it implements,
it opens the PR as a draft, and it never merges, pushes to the trunk, labels
an issue `ready`, or approves anything. If it doesn't know, see
Troubleshooting below.

**6. Put `ready` on one issue and watch it get picked up.**

```bash
gh issue edit <N> --add-label ready
```

The next time a `developer` session looks for work (`gh issue list --label
ready`, the first thing `roles/developer.md` tells it to run), this is what it
finds.

## Troubleshooting

**Session does not know its role.**
Check, in order: does `.agents/ROLE` exist in that worktree, and does it
contain a role name? Does `cat .agents/context.md` actually show the base
rules plus the role text — not an old or empty file? Is `WTC_TOOL` set to
the tool you're actually running (`echo $WTC_TOOL`)? If all three check out
but the session still doesn't know, the coding agent may not support the flag
`launch_command()` used for it — see `docs/tools.md`.

**`wtc: no role file for '<name>'`**
The word written to `.agents/ROLE` (or passed as the role argument) has no
matching file in `roles/`. Role names are exactly the filenames in `roles/`
without `.md`: `developer`, `reviewer`, `integrator`, `none`. A typo here is
the most common cause.

**Reviewer cannot approve.**
Either it's using the wrong account (the review author's own account can
never approve its own PR — this is enforced by GitHub itself), or the
keychain entry is missing, in which case `wtc` already warned you at session
start: `wtc: no reviewer token found — approvals will fail`. See
`docs/setup.md` step 2.

**`git worktree add` refuses.**
```
fatal: '<branch>' is already used by worktree at '<path>'
```
That branch is checked out somewhere else already — git will not check out
the same branch in two worktrees. This is also, exactly, why there is one
`integrator` per repository: the integrator worktree sits on the trunk, and
nothing else can.

**The agent ignores `AGENTS.md`.**
Some coding agents only read `AGENTS.md` when no tool-specific file
(`CLAUDE.md`, `GEMINI.md`, …) already exists in the repository — that's a
property of the reading tool, not of `worktree-crew`. If your project has one
of those files, add a line to it pointing at `AGENTS.md` so the project
knowledge isn't silently shadowed.
