# mandate

Give each AI coding session a fixed role and its own git worktree.

## Setup

Paste this into your coding agent:

```
Read https://raw.githubusercontent.com/culfin/mandate/main/INSTALL.md
and walk me through setting this up for my project.
```

It reads your repository, proposes the values it cannot guess — above all the
production boundary — and stops wherever a decision is yours.

Prefer to do it by hand? [docs/setup.md](docs/setup.md) has the same steps
without an agent.

## The problem

Several AI sessions work on one project. Each one gets briefed from scratch —
how this project tests, who reviews, where the line is it must not cross —
and something in that briefing gets forgotten every time. Meanwhile sessions
collide over files because they share one checkout.

## The picture

```
myproject/
├── .worktrees/
│   ├── myproject-developer/    branch: myproject-developer   role: developer
│   ├── myproject-reviewer/     branch: review/<N>            role: reviewer
│   └── myproject-maintainer/   branch: myproject-maintainer  role: maintainer
└── AGENTS.md                   committed — trunk, tests, reviewer, production boundary

developer  --draft PR, ready, request review-->  reviewer
                ^                                    |
                |                          --approve / --request-changes
                +---------- re-request <-------------+ (changes requested)
                                                       |
                                                  (approved)
                                                       v
                                                  maintainer  --> merge, tag, ship
```

Three worktrees, three branches, three roles, one repository. See
`docs/flow.md` for the exact commands at each step.

## Quickstart

```bash
git clone https://github.com/culfin/mandate ~/.mandate
ln -s ~/.mandate/bin/mdt ~/bin/mdt   # not on your PATH? see docs/setup.md

mdt init myproject          # myproject means ~/Projekte/myproject — see below
mdt myproject developer     # opens a session that knows it's a developer
mdt list                    # see every worktree, across every project
mdt drop myproject DEV      # remove one — refuses unless it's safe to
mdt restart myproject DEV   # hand over, replace the process, resume
```

`mdt init myproject` and everything after it look for `myproject` under
`MDT_PROJECTS_DIR` — default `~/Projekte` (German for "projects", not a typo).
If your repositories live somewhere else, say `~/code`, set that first:

```bash
export MDT_PROJECTS_DIR=~/code
```

Otherwise the very first command fails with `myproject is not a git
repository`, which reads like `mdt` is broken rather than pointed at the
wrong directory.

`mdt init` proposes an `AGENTS.md`, creates the `ready` / `needs-decision`
labels, and creates the three role worktrees — confirming each step, not
hiding it. Requires `git`, `gh` and `tmux`; no runtime, no package manager.
Full walkthrough, including the equivalent by-hand steps and troubleshooting,
in [docs/adding-a-project.md](docs/adding-a-project.md).

## The one idea

> The role says how you work. The project says what with.

A "Rust developer" and a "Next.js developer" aren't two roles — they're the
same role doing the same process in two projects:

| | Rust/Tauri project | Next.js project |
|---|---|---|
| Role file (`roles/developer.md`) | identical | identical |
| Test command (`AGENTS.md`) | `cargo test --workspace` | `pnpm test` |
| Review tools (`AGENTS.md`) | `rust-best-practices`, `tauri-v2` | `next-best-practices` |

Roles carry process and permissions; projects carry what the process is
applied to. See [docs/concept.md](docs/concept.md).

## Works with any coding agent

Only one function in `bin/mdt` — `launch_command()` — knows about a specific
coding agent. Everything else (worktrees, roles, the GitHub flow, `AGENTS.md`)
is vendor-neutral. Claude Code is verified; other tools range from unverified
to "paste this file in yourself." See [docs/tools.md](docs/tools.md) for
exactly which is which — it does not imply parity where none has been
checked.

## What this deliberately is not

- No message bus. GitHub carries the state.
- No board, no queue, no database. An issue and a PR *are* the state.
- No polling. Nothing happens while you're not looking; `mdt status` answers
  on demand, it doesn't watch.

## Limits, in three lines

One `maintainer` per repository by convention, not by git — nothing stops a
second one, but two would fight over merge order, so don't. Disk is cheap per
byte but adds up (a Rust/Tauri worktree runs about 9 GB, mostly build output)
— `mdt list` shows what exists, `mdt drop` removes one and refuses if that
isn't safe. Memory is the real ceiling, and two concurrent `cargo` builds
already strain a 32 GB machine. Role boundaries are self-imposed — the token
can do more than the role allows; what stops it is the role file, not the
forge. Full numbers and what they were measured on:
[docs/limits.md](docs/limits.md).

## Documentation

- [docs/concept.md](docs/concept.md) — the problem, the one idea, the three layers
- [docs/setup.md](docs/setup.md) — install, reviewer account, first project
- [docs/adding-a-project.md](docs/adding-a-project.md) — the same setup twice, with `mdt init` and by hand, plus troubleshooting
- [docs/roles.md](docs/roles.md) — permissions, what each role never does, and why they're not enforced
- [docs/flow.md](docs/flow.md) — the GitHub states, the labels, the review round trip
- [docs/tools.md](docs/tools.md) — which coding agent integration is verified
- [docs/limits.md](docs/limits.md) — measured numbers, not estimates

## Licence and attribution

MIT — see `LICENSE`. The subagents under `agents/` (a curated selection, not a
mirror — see `agents/README.md`) and part of `roles/_base.md` are adapted from
[agency-agents](https://github.com/msitarzewski/agency-agents) (MIT); see
`NOTICE`.
