# Concept

## The problem

Several AI coding sessions work on the same project. Each one is spun up fresh:
told what to build, told how this project expects work to be done, told who
reviews it, told where the line is that it must not cross on its own. That
briefing gets retyped every time, and something in it gets forgotten every
time — usually the production boundary, because it only matters once, right
before someone would have needed it.

Meanwhile the sessions collide over files: two agents editing the same
checkout step on each other, or one agent half-reading a file another just
rewrote.

## The one idea

> **The role says how you work. The project says what with.**

A "Rust developer" and a "Next.js developer" are not two roles — they are the
same role, `developer`, doing the same thing (find a `ready` issue, implement
test-first, open a draft PR, ask for review) in two different projects. What
differs is the test command and the review tools, and those belong to the
project, not the role. If roles were tied to a technology, every new language
would need a new role, and the actual process — how a developer behaves —
would be duplicated once per stack.

Splitting the two also fixes *file* collisions for free: `mdt` gives each role
its own git worktree, so a developer, a reviewer and a maintainer have three
separate working directories on three separate branches, at the same time,
without touching each other's files. It does nothing for two sessions in the
*same* role — two developers still read the same issue list and can reach for
the same issue, because a worktree separates roles from each other, not a
role from itself. That collision is a work-assignment problem, not a
filesystem one; see `docs/flow.md` for what closes it.

## The three layers

```
① TOOL       mandate itself             universal, knows no project
             roles/   _base · developer · reviewer · maintainer · none
             bin/mdt  init · start · attach · status · list · drop · restart
             agents/  five subagents (Claude Code only, see docs/tools.md)

② PROJECT    <repo>/AGENTS.md                  committed, ~20 lines, standard format
             trunk, reviewer login, test commands, review tools, production boundary

③ WORKTREE   <worktree>/.agents/ROLE           not committed, one word
             developer
```

`mdt` reads layer ③, adds layer ① (`roles/_base.md` plus the role file named in
`ROLE`), and starts the coding agent with the result as its system prompt. It
never reads layer ②: the agent reads `AGENTS.md` itself, because that file
being readable without help is the entire point of the standard. Duplicating
its contents into the session's system prompt would just be a second copy that
can drift from the first.

The assembled text lands in `<worktree>/.agents/context.md`. It is never
committed — `mdt` adds `.agents/` to `git info/exclude` the first time it runs
in a worktree, so it produces no `git status` noise and nothing gets
committed by accident. Measured: that file is the *repository's* shared
`info/exclude` (`<repo>/.git/info/exclude`), not a per-worktree one — git
does not support the latter, so the entry covers `.agents/` in every worktree
of the repository at once, not only the one that triggered the write. The
first `mdt <repo> <role>` (or `mdt init`) in a fresh checkout is therefore
also the first time `mdt` writes into that checkout's `.git/` — worth knowing
before you point it at a repository you don't otherwise expect it to touch.

## Why roles are technology-free

`roles/developer.md` says nothing about Rust, npm, or any test framework. It
says: find a `ready` issue, open the PR as a draft immediately so the work is
visible, implement test-first, run *the test commands this project's
`AGENTS.md` names*, ask for review, and never touch the trunk directly. Every
one of those steps holds regardless of what the project builds. The stack
enters only where the role file explicitly hands off to `AGENTS.md` — for test
commands, review tools, and the production boundary.

This is why adding a new project costs a file with about twenty lines
(`AGENTS.md`) rather than a new role: the process doesn't change, only what
the process is applied to.

## Why roles are vendor-neutral, and where the one `case` statement lives

The role files are Markdown. `.agents/ROLE` is one word in a text file. The
flow runs entirely over `git` and `gh`. None of that names a coding agent.

The one place a coding agent's name appears in the whole tool is
`launch_command()` in `bin/mdt` — a single `case` statement that knows how to
hand the assembled role text to whichever tool `MDT_TOOL` names:

```bash
case "$tool" in
  claude) LAUNCH_CMD=(claude --append-system-prompt-file "$ctx") ;;
  codex)  LAUNCH_CMD=(codex --prompt-file "$ctx") ;;
  *)      LAUNCH_CMD=(); return 1 ;;
esac
```

Adding a tool means adding one branch here and one row in `docs/tools.md`.
Nothing else in the repository changes — not a role file, not `AGENTS.md`, not
the flow. See `docs/tools.md` for which of these branches is actually verified.

## Roles versus subagents

A **role** is a session: it has a worktree, a branch, and permissions that last
for as long as that session runs. There are three of them (`developer`,
`reviewer`, `maintainer`), plus `none` for a worktree that should not be worked
in at all.

A **subagent** is expertise called for the length of one task, inside a
session. It has no worktree, no branch, and no permissions of its own — it
answers a question or does a piece of work and hands control back. The five
subagents under `agents/` (desktop-app engineering, privacy, i18n, Rust
refactoring, minimal-change discipline) are this kind of thing, curated from
`agency-agents` (see `agents/README.md` and `NOTICE`).

A project's `AGENTS.md` lists which subagents apply there, under `##
Subagents`; `roles/reviewer.md` tells the reviewer to call the ones relevant to
a given change. Roles supply process and rights; subagents supply knowledge.
Neither substitutes for the other.
