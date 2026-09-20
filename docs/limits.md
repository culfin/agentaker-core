# Limits

These are the limits that actually bind, not a hypothetical worst case. Where
a number is given, it's measured, and the paragraph says on what.

## One maintainer per repository — a convention, not a git-enforced fact

`maintainer`, like every other role, gets its own branch (`$repo-maintainer`)
when `mdt` creates its worktree — the same `git worktree add ... -b` any other
role gets. It does **not** sit on the trunk branch: the top-level clone
already has trunk checked out, so no worktree ever could, and a maintainer
merges through the forge (`gh pr merge`), never with a local `git merge` on a
checked-out trunk — it never needed the branch. Nothing stops a second
`maintainer` worktree from being created; `mdt mandate maintainer second`
succeeds exactly like any other suffixed role would.

Stick to one anyway. Two maintainers would contend over merge order and
release rhythm — which PR lands first, whether a release goes out while
another merge is mid-flight — and that's a coordination problem, not a
mechanical one. Nothing enforces this; two maintainers would simply fight
over merge order. The same reasoning is why there is no separate `deployer`
role — see `docs/concept.md` — but that decision doesn't rest on this one:
merging and releasing share a production boundary and happen one after the
other regardless of how many worktrees exist.

## Several developers, no such ceiling

`developer` and `reviewer` don't sit on a shared branch, so nothing stops more
than one of either running at once. The name suffix is what tells them apart:

    mdt dateye developer
    mdt dateye developer a11y

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

## `list --size` costs real time, which is why it isn't the default

`du -sh` on one real Rust/Tauri worktree (DATEYE, 9.1 GB): **~0.99s cold,
~0.54s warm.** Measured with `time du -sh`, on the same machine and worktree
the 9.1 GB figure above comes from — not estimated. `mdt list` runs this once
per worktree, so a board of a dozen such worktrees costs several seconds with
a cold cache, on a command whose whole point is to answer quickly. That is
the number `--size` sits behind a flag for: `list` without it shows worktree,
branch and state instantly; `list --size` trades that for a real `du` size,
and says so rather than showing a stale or fabricated one.

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

Nothing runs while you're not looking. `mdt status` answers "where is work
waiting" on demand — it costs one `gh search` call per owner, not a
background loop — but it doesn't notify you on its own, and no session
advances work it wasn't asked to advance. If you want to know whether
something moved, you ask; the tool never wakes anyone up by itself. This is a
deliberate omission (see `docs/concept.md`), not a missing feature — it keeps
the tool to git, `gh` and `tmux`, with nothing idling and no token spent while
no one is working.

## Tab colour is iTerm2-only, and silently absent elsewhere

The title (`dateye · DEV`) works anywhere tmux does — it's tmux's own
`set-titles-string`, which every terminal that shows a tmux title already
understands. The colour is different: it's iTerm2's own proprietary escape
code, wrapped for tmux's passthrough. Outside iTerm2, `mdt` detects that and
emits nothing — deliberately. A stray escape sequence in a terminal that
doesn't understand it prints garbage in the pane, which is worse than no
colour; silence was the safer failure here, not an error message. If your tab
never turns colour and you're not on iTerm2, that's expected, not broken.
`MDT_TAB_COLOUR=0` turns it off regardless of terminal, if you'd rather it
never tried.

## `drop` refuses rather than asks

`mdt drop` removes a worktree that can run to several gigabytes and may hold
the only copy of something. A yes/no prompt gets answered on reflex, the same
way every other prompt that session has seen was — so instead of asking,
`drop` checks three things (uncommitted changes, commits not on any remote, an
open tmux window) and refuses by default, naming exactly what it found. Only
`--force` proceeds anyway. This costs an extra step when you did mean it, on
purpose: the cost of a false refusal is a few seconds re-running the command
with `--force`; the cost of a false confirmation is the worktree.

## A handover is only as good as the session that writes it

`mdt restart` never reads the handoff file it waits for — it sends keystrokes
and waits for a file to appear, and hands that file to the successor
unexamined. What ends up in it is entirely up to the session: a role that
follows `roles/_base.md`'s "Handing over" section closely leaves its
successor a usable state; one that summarises the conversation instead, or
skips `Not checked`, leaves a successor that inherits confidence nobody
actually earned. `mdt` has no way to tell the difference, and doesn't try to.

A wedged session cannot be handed over at all — by definition, it isn't
answering. `mdt restart` waits `MDT_HANDOFF_TIMEOUT` seconds (default 60),
then aborts rather than guessing: no restart happens, and the session is told
so, because a lost handover is exactly what this command exists to prevent.
`--fresh` is the honest way past that: it replaces the process without
asking, and it loses whatever state existed. That trade is the whole point of
naming it explicitly rather than falling back to it automatically — a session
that silently lost its place is worse than one that stops and says so.
