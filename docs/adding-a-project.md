# Adding a project

This is the page the tool lives or dies by. If setup is a black box, the
person who needs to debug it — you, at 11pm, wondering why a session doesn't
know it's a reviewer — can't. So this walks one project from nothing to a
running session **twice**: once with `mdt init`, once entirely by hand. Both
routes end at the same three files. If you ever need to fix something `mdt
init` did, the by-hand section is what it did, spelled out.

Throughout, `myproject` stands for whatever your repository is called, cloned
under `MDT_PROJECTS_DIR` (default `~/Projekte/myproject`).

## Route A: `mdt init`

```
$ mdt init myproject
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

## Review tools

    # optional — file globs mapped to review skills or linters, one per line, e.g.:
    # .rs   rust-best-practices

## Subagents

    # optional — specialists under agents/ that apply here, one per line, e.g.:
    # engineering-privacy-engineer

    # optional — a CONTEXT.md domain glossary, with a "flagged ambiguities"
    # section for words that meant two things and how that got resolved.
    # See docs/adding-a-project.md, "Optional: a domain glossary". Not
    # required — mdt-lint never asks for one.

## Roles

developer reviewer maintainer

## Production boundary

The one line an agent must never cross on its own. Examples:

    git push origin main:production
    npm publish

Replace this with yours. This line is a boundary agents are asked to respect,
not one they are forced to observe — only a protected environment (offered
next, or see docs/setup.md) actually makes a release wait for you.

  Write this file? (y/n) [y]
  written: /Users/you/Projekte/myproject/AGENTS.md — edit the production boundary before you rely on it.
  Create the two labels on the remote? (y/n) [y]
  label created: ready
  label created: needs-decision

The production boundary needs a lock: a protected environment makes the
job wait for you in the browser, whoever triggered it.
  Create or update a protected "production" environment? (y/n) [y]
  environment created: production (you are the required reviewer)

  One line is still yours to add, on the job that crosses the boundary:
      jobs:
        release:
          environment: production
  Without it the environment exists and protects nothing.
  Create worktrees for the three roles? (y/n) [y]
```

(The production-environment step above needs a plan that supports required
reviewers — a public repository, or GitHub Pro/Team/Enterprise for a private
one. Without that, the API call fails with `422` and `init` prints `could not
create or update the environment — create it by hand, see docs/setup.md`
instead of `environment created: ...`, then carries on to the worktree step
regardless — see `docs/setup.md` step 3 for the exact error and what it
means. Measured directly: a private repository on a free plan hits this every
time.

`init` checks first whether `production` already exists, so a *second* run
against the same repository prints `environment updated: production already
existed — …` instead of `environment created: …` — see `docs/setup.md` step 3
for what that distinction does and doesn't tell you about rules already on
the environment.)

(This is the outcome with a GitHub remote that the current `gh` login can
create labels on. Against a repository with no configured remote — as in the
throwaway repository this walkthrough was actually run against — the same two
lines instead read `label ready: already there, or no access` and likewise for
`needs-decision`; `mdt init` treats "the label already exists" and "I
couldn't create it" the same way on purpose, since either way there's nothing
more for it to do, and tells you to check by hand if that surprises you.)

```
  worktree: myproject-developer
  worktree: myproject-reviewer
  worktree: myproject-maintainer

Done. Next:
  1. Edit /Users/you/Projekte/myproject/AGENTS.md — above all the production boundary.
  2. Commit AGENTS.md, then update the worktrees just created — they were
     made from the commit before this one, so none of them can see it yet:
       git -C /Users/you/Projekte/myproject add AGENTS.md && git -C /Users/you/Projekte/myproject commit -m "add AGENTS.md"
       git -C /Users/you/Projekte/myproject/.worktrees/myproject-developer  pull /Users/you/Projekte/myproject main
       git -C /Users/you/Projekte/myproject/.worktrees/myproject-reviewer   pull /Users/you/Projekte/myproject main
       git -C /Users/you/Projekte/myproject/.worktrees/myproject-maintainer pull /Users/you/Projekte/myproject main
  3. Put the reviewer account's login in AGENTS.md — without it the reviewer
     cannot be asked for a review. See docs/setup.md.
  4. Give the reviewer its own account: docs/setup.md
  5. Put 'ready' on an issue:   gh issue edit <N> --add-label ready
  6. Start working:             mdt myproject developer
```

(Step 2 is easy to skip because nothing before it fails loudly if you do: `mdt
init` writes `AGENTS.md` to the top-level checkout but never commits it, and
the three worktrees are created from the commit *before* that write — so a
session started right after `init`, without this step, sits in a worktree
where `AGENTS.md` simply doesn't exist yet. Route B avoids this by ordering
commit before worktree creation; Route A's confirm-each-step design doesn't,
so the step has to be named explicitly instead.)

(This transcript is real, run against a throwaway repository — the wording
matches `cmd_init()` in `lib/init.sh`. `stack: unknown` because the throwaway
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
(`.worktrees/myproject-developer`, `-reviewer`, `-maintainer`) each carrying
its own `.agents/ROLE`. **You still have to open `AGENTS.md` and fill in the
production boundary** — `init` writes a placeholder there, but nothing about
it refuses anything by itself: it is a sentence an agent is asked to respect.
Only a protected environment (offered earlier in this walkthrough, or see
`docs/setup.md`) actually makes a release wait for you — see `docs/roles.md`
for which boundaries in this tool are agreed and which are enforced.

## Route B: entirely by hand

Everything Route A did, as individual commands. Useful when `mdt init` isn't
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
not only the ones started through `mdt` — reads it from the checkout.

**3. Create the two labels.**

```bash
gh label create ready --description "Ready for an agent to pick up" --color 0E8A16
gh label create needs-decision --description "Waiting on a human decision" --color D93F0B
```

**4. Create the three worktrees, one per role.** `mdt <repo> <role>` does
this the moment it's asked to start a role that doesn't have a worktree yet —
so this step and "start a session" are the same command; there's no separate
worktree-creation step to run by hand. What it does, if you want to replicate
it directly with git:

```bash
cd ~/Projekte/myproject
git worktree add .worktrees/myproject-developer -b myproject-developer
mkdir -p .worktrees/myproject-developer/.agents
echo developer > .worktrees/myproject-developer/.agents/ROLE
cat ~/.mandate/roles/_base.md ~/.mandate/roles/developer.md > .worktrees/myproject-developer/.agents/context.md
echo '.agents/' >> .git/info/exclude
```

`roles/` lives in the `mandate` installation (`~/.mandate`, per `docs/setup.md`
step 1), not in the project checkout — adjust the path if you linked `mdt`
somewhere else. `.git/info/exclude` is this checkout's own, run from its
top level: git does not support a per-worktree exclude file, so this is also
where the worktree's own `.agents/` gets excluded — see `docs/concept.md`.

Repeat for `reviewer` and `maintainer`. (`mdt` does the `_base.md` + role
concatenation with a blank line between the two files, not a bare `cat`; the
difference doesn't matter for reading it, only for exact byte output.)

**5. Start a session and confirm it knows its role.**

```bash
mdt myproject developer
```

This resolves to the worktree from step 4 (creating it first if step 4 was
skipped), writes `.agents/ROLE` and `.agents/context.md` if they're missing or
stale, and launches your coding agent (`$MDT_TOOL`, default `claude`) with
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

## Optional: a domain glossary (`CONTEXT.md`)

Neither route above writes this file, and nothing in `mdt-lint` asks for it —
it is a recommendation, not a requirement. Add one if this project's
vocabulary is easy to misread: a domain term that means something narrower or
different here than its plain-English reading suggests, an abbreviation two
readers would expand two different ways.

The shape worth copying (credit: mattpocock/skills, whose repositories carry
one) is a short glossary plus a **"flagged ambiguities"** section: not just
definitions, but a record of which word meant two things at some point and how
that got resolved — so the next session that hits the same ambiguity finds the
answer instead of re-litigating it.

`lib/init.sh` leaves a commented pointer to this section under `##
Subagents` in the `AGENTS.md` it proposes, so the option is visible without
being pushed on a project that doesn't want it. A project with no `CONTEXT.md`
is not missing anything `mandate` checks for — a glossary nobody maintains is
worse than none, and CI never nags a project that decided against one.

## Troubleshooting

**Session does not know its role.**
Check, in order: does `.agents/ROLE` exist in that worktree, and does it
contain a role name? Does `cat .agents/context.md` actually show the base
rules plus the role text — not an old or empty file? Is `MDT_TOOL` set to
the tool you're actually running (`echo $MDT_TOOL`)? If all three check out
but the session still doesn't know, the coding agent may not support the flag
`launch_command()` used for it — see `docs/tools.md`.

**`mdt: no role file for '<name>'`**
The word written to `.agents/ROLE` (or passed as the role argument) has no
matching file in `roles/`. Role names are exactly the filenames in `roles/`
without `.md`: `developer`, `reviewer`, `maintainer`, `none`. A typo here is
the most common cause.

**Reviewer cannot approve.**
Either it's using the wrong account (the review author's own account can
never approve its own PR — this is enforced by GitHub itself), or the
keychain entry is missing, in which case `mdt` already warned you at session
start: `mdt: no reviewer token found — approvals will fail`. See
`docs/setup.md` step 2.

**`git worktree add` refuses.**
```
fatal: '<branch>' is already used by worktree at '<path>'
```
That branch is checked out somewhere else already — git will not check out
the same branch in two worktrees. This is not why there is one `maintainer`
per repository, though — `maintainer` gets its own branch (`$repo-maintainer`)
like every other role, not the trunk, so a second one would not hit this
refusal. "One maintainer" is a convention worth keeping (two would contend
over merge order), not something git enforces — see `docs/limits.md`.

**The agent ignores `AGENTS.md`.**
Some coding agents only read `AGENTS.md` when no tool-specific file
(`CLAUDE.md`, `GEMINI.md`, …) already exists in the repository — that's a
property of the reading tool, not of `mandate`. If your project has one
of those files, add a line to it pointing at `AGENTS.md` so the project
knowledge isn't silently shadowed.

**`mdt list developer` (or `attach`/`drop`/`init`/`restart`/`status`) says
`.../developer is not a git repository`.**
A project literally named one of `mdt`'s six subcommands can't be reached
through the shape that names it — `bin/mdt` matches the first word against
those six before it ever falls back to `<repo> <role>`, so `mdt list
developer` runs `list` filtered to a repo called `developer`, not "start
`developer` in the repo called `list`". See `docs/limits.md` for the full
explanation; the fix is renaming the project, not the command.
