# Limits

These are the limits that actually bind, not a hypothetical worst case. Where
a number is given, it's measured, and the paragraph says on what.

## One integrator per repository — this is git, not a design choice

`integrator` sits on the trunk branch. Git will not check out the same branch
in two worktrees at once, so a second `integrator` worktree for the same repo
simply cannot be created — `wtc` would hit `git worktree add`'s refusal
(`'main' is already used by worktree at …`) before it got anywhere near a
role. There is no configuration that changes this; it is what one integrator
per repository is grounded in. The same reasoning is why there is no separate
`deployer` role — see `docs/roles.md`.

## Several developers, no such ceiling

`developer` and `reviewer` don't sit on a shared branch, so nothing stops more
than one of either running at once. The name suffix is what tells them apart:

    wtc dateye developer
    wtc dateye developer a11y

gives two worktrees, `dateye-developer` and `dateye-developer-a11y`, each with
its own branch, each addressable independently. Use this for parallel,
unrelated work — not for two sessions on the same issue.

## Disk: a Rust/Tauri worktree is large, and it's `target/`

Measured on one project (DATEYE, Rust + Tauri) on the development machine: a
single worktree occupies about **9.1 GB**, almost all of it
`src-tauri/target/` — build artifacts, not source. With 258 GB free on that
machine, a couple of dozen such worktrees fit comfortably. Projects without a
Rust build (the `nextjs`, `astro`, `python` examples) don't carry anything
close to this; `node_modules/` is real but nowhere near a Cargo target
directory. A worktree that's just standing there, unused, still costs this —
disk is the cheap limit here, not the binding one.

## Memory is the real ceiling

The measured problem isn't disk, it's RAM: on a 32 GB machine, two concurrent
`cargo` builds are already tight, and under that memory pressure `rustc`
*appears* to hang — it isn't actually stuck, it's swapping, but from outside a
session that looks indistinguishable from a hung build, and diagnosing that
difference costs time you weren't planning to spend.

Practical guidance from that measurement: **two to three active Rust sessions**
on a 32 GB machine, more if the project is JavaScript/TypeScript rather than a
Rust compile. This is a statement about concurrent *active* sessions —
compiling at the same time — not about how many worktrees can exist on disk;
see the previous section for that.

If you're on a machine with more or less memory than 32 GB, scale the
guidance, don't treat the number itself as portable — the underlying limit is
"how many concurrent compiles fit in RAM," and that depends on the machine and
the project, not on this tool.

## Role boundaries are not enforced

Worth repeating here because it's a limit, not just a design note: the
permissions in `docs/roles.md` are self-imposed. A role's GitHub token is
capable of more than its role file allows; nothing outside the session stops
it from doing so except the coding agent choosing to follow the role file. One
exception is the reviewer's own account, which makes GitHub itself refuse
self-approval — see `docs/flow.md` for the measurement. The other is the
production boundary, if you've locked it as `docs/setup.md` describes — see
below for why it's the only other one. Don't rely on a role boundary anywhere
a real access-control guarantee is needed.

## Why only one thing is locked

Branch protection was considered and rejected. Agents run under your own
account, which is an admin: with `enforce_admins: false` they bypass the rule
exactly as you do, so it guards nobody; with `true` it is real, but it also
blocks every quick manual fix — a poor trade for a mistake that `git revert`
undoes.

A `pre-push` hook was considered and rejected. It protects the wrong party: an
agent that follows its role file does not need it, and one that ignores it types
`--no-verify`.

The production boundary is different in kind, not degree: it is the only
irreversible action an agent can take. That is why it is the only one with a lock.

## No polling

Nothing runs while you're not looking. `wtc status` answers "where is work
waiting" on demand — it costs one `gh search` call per owner, not a
background loop — but it doesn't notify you on its own, and no session
advances work it wasn't asked to advance. If you want to know whether
something moved, you ask; the tool never wakes anyone up by itself. This is a
deliberate omission (see `docs/concept.md`), not a missing feature — it keeps
the tool to git, `gh` and `tmux`, with nothing idling and no token spent while
no one is working.
