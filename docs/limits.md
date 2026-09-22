# Limits

These are the limits that actually bind, not a hypothetical worst case. Where
a number is given, it's measured, and the paragraph says on what.

## One maintainer per repository — a convention, not a git-enforced fact

`maintainer`, like every other role, gets its own branch (`$repo-maintainer`)
when `tender` creates its worktree — the same `git worktree add ... -b` any other
role gets. It does **not** sit on the trunk branch: the top-level clone
already has trunk checked out, so no worktree ever could, and a maintainer
merges through the forge (`gh pr merge`), never with a local `git merge` on a
checked-out trunk — it never needed the branch. Nothing stops a second
`maintainer` worktree from being created; `tender treetender maintainer second`
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

    tender dateye developer
    tender dateye developer a11y

gives two worktrees, `dateye-developer` and `dateye-developer-a11y`, each with
its own branch, each addressable independently. Use this for parallel,
unrelated work — not for two sessions on the same issue.

**Nothing caps how many sessions** — but a project can cap how many agent
PRs it lets pile up, which is the thing that actually overwhelms someone.
See the next section.

## `max-open-prs` caps agent PRs — per project, and only where it asks

Renovate solved the equivalent problem in 2019 with `prConcurrentLimit`:
unbounded automation does not overwhelm the machine, it overwhelms the human
who has to read the results. `tender status` measures it: for every project
under `TENDER_PROJECTS_DIR` that has an `AGENTS.md`, one line when agent PRs
are open —

    agent PRs open:
      acme: 3 agent PRs open, oldest waiting 2d (cap 3 — full)

An **agent PR** is an open pull request whose branch is `<repo>-developer` or
`<repo>-developer-<suffix>` — the branches `tender <repo> developer [suffix]`
creates. Drafts count: in single-account mode a draft is exactly what is
waiting for you. It is one `gh pr list` call per project, run on demand like
the rest of the board (see "No polling"); when it cannot be asked — `gh`
missing, offline, no remote — the line says `could not ask`, the board exits
1, and it never reads as zero.

A project that wants a ceiling sets one in its `AGENTS.md`:

    max-open-prs: 3

**What it does.** A developer session about to open a PR counts first
(`roles/developer.md`, "Working", step 2). At the cap it opens nothing,
keeps its branch pushed, says so, claims no new issue, and works on review
feedback instead. And `tender <repo> developer [suffix]` refuses to start
another developer session — exit 1, naming the cap and the count — when the
count is at or above the cap *and* another developer session of that repo
already has a running window.

**What it does not do.**

- **It never stops the first developer session.** That session is the one
  that works off review feedback; refusing it would leave a full queue with
  nobody to empty it.
- **It binds the project, not the tool.** There is no global limit and no
  default: without `max-open-prs`, nothing anywhere behaves differently.
  Each project decides its own number, because only the project knows how
  fast its reviews go.
- **It is not enforced against a session that ignores its role.** The start
  refusal is real; the check before `gh pr create` is an instruction, like
  every other role boundary (see "Role boundaries are not enforced").
- **A failed count does not stall work.** Could not ask means start, or open
  the PR, with a one-line warning — never a silent wait on a number nobody
  has.
- **It does not count other PRs.** A human's branch, a dependency update, a
  reviewer's or maintainer's branch are not agent PRs.
- **An invalid value is no cap, never 0.** `max-open-prs: 0`, `three` or `-1`
  is reported by `tender status` (and by `bin/tender-lint` in an example) and
  otherwise ignored — a typo must not stop every developer.
- **A waiting branch still holds its claim, and the claim still ages.** Past
  `claim-timeout-days` another session may take the issue over; step 1 of
  "Working" is what notices, when the count drops and the session comes back.
- **It counts up to 200.** That is the `--limit` of the one call; a project
  with more open agent PRs than that has a different problem.

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
the 9.1 GB figure above comes from — not estimated. `tender list` runs this once
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
exception is the reviewer's own account **in two-account mode**, which makes
GitHub itself refuse self-approval — see `docs/flow.md` for the measurement.
The other is the production boundary, if you've locked it as `docs/setup.md`
describes — see below for why it's the only other one. Don't rely on a role
boundary anywhere a real access-control guarantee is needed.

**Single-account mode — the default — has neither of those exceptions for
review.** The separation between developer and reviewer there is agreed, not
enforced: nothing on GitHub's side stops a developer session from running the
reviewer's own commands, `gh pr edit <N> --add-label approved` included, on
its own PR. With two accounts a self-approval is physically impossible, no
matter what a session decides to do; with one, it's a role file a session
could ignore, the same as every other boundary in `docs/roles.md`'s "agreed"
column. There is no green checkmark in the browser confirming a second party
looked — an `approved` label proves a review command ran, not who ran it.
That's the price of not requiring a second account before the flow can be
proven even once; see `docs/setup.md`, "If you want the separation enforced:
a second account", for the upgrade that removes it.

## The claim ref locks task selection, not the work after it

`refs/claims/issue-<N>` and `refs/claims/pr-<N>` (`docs/flow.md` has the
measurements, `roles/developer.md` and `roles/reviewer.md` the commands) stop
two sessions from *starting* the same issue or PR at the same moment. Once a
session holds the ref, nothing watches it: a session that crashes, is
killed, or simply stops responding keeps its claim exactly as pushed, and
nothing here polls to notice — the same "no polling" limit further down
applies here too.

It used to stay that way until a human ran a manual release. It no longer
does: every claim already carries the timestamp it was pushed with, and a
session that loses a claim attempt now reads it before giving up
(`docs/flow.md`, "Orphaned claims: age-based release", has the mechanism).
Older than `claim-timeout-days` in `AGENTS.md` (default **2**) and it counts
as orphaned — the next session to want that issue or PR takes it over, comments
to say so, and moves on.

**What this does not fix.** The release is still lazy, not a sweep: nothing
here runs on its own, so a claim nobody else ever asks for stays held exactly
as before, no matter how old it gets — the mechanism only fires at the
moment a second session tries to claim the same ref and loses. And the
threshold cannot distinguish "crashed" from "alive and slow" any better than
a human glancing at the issue could; it just waits longer before guessing.
Set the threshold too low and it evicts a session mid-task, handing its
issue to someone else while it is still working — the reason
`claim-timeout-days` defaults to days, not minutes, and the reason
`roles/developer.md` and `roles/reviewer.md` both check, right before the
action a takeover would otherwise duplicate, whether they still hold what
they started with. That check bounds the damage to lost in-progress work; it
does not make eviction of a live session impossible, only rare and
survivable rather than silent.

A claim can still be released by hand at any time, from any clone with push
access — faster than waiting out the threshold, and the only option before
this existed:

```bash
git push origin ":refs/claims/issue-<N>"   # or pr-<N>
```

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

Nothing runs while you're not looking. `tender status` answers "where is work
waiting" on demand — it costs four `gh search` calls per owner (ready issues,
the review queue, approved PRs, decisions waiting on you — `cmd_status()` in
`bin/tender`) plus one `gh pr list` per set-up local project (the agent PR
count, `lib/throttle.sh`), not a background loop — but it doesn't notify you on its own, and no session
advances work it wasn't asked to advance. If you want to know whether
something moved, you ask; the tool never wakes anyone up by itself. This is a
deliberate omission (see `docs/concept.md`), not a missing feature — it keeps
the tool to git, `gh` and `tmux`, with nothing idling and no token spent while
no one is working.

## Tab colour is iTerm2-only, and silently absent elsewhere

The title (`dateye · DEV`) works anywhere tmux does — it's tmux's own
`set-titles-string`, which every terminal that shows a tmux title already
understands. The colour is different: it's iTerm2's own proprietary escape
code, wrapped for tmux's passthrough. Outside iTerm2, `tender` detects that and
emits nothing — deliberately. A stray escape sequence in a terminal that
doesn't understand it prints garbage in the pane, which is worse than no
colour; silence was the safer failure here, not an error message. If your tab
never turns colour and you're not on iTerm2, that's expected, not broken.
`TENDER_TAB_COLOUR=0` turns it off regardless of terminal, if you'd rather it
never tried.

## `drop` refuses rather than asks

`tender drop` removes a worktree that can run to several gigabytes and may hold
the only copy of something. A yes/no prompt gets answered on reflex, the same
way every other prompt that session has seen was — so instead of asking,
`drop` checks three things (uncommitted changes, commits not on any remote —
on the worktree's own branch only, not every local branch in the repository —
an open tmux window) and refuses by default, naming exactly what it found.
Only `--force` proceeds anyway. This costs an extra step when you did mean
it, on purpose: the cost of a false refusal is a few seconds re-running the
command with `--force`; the cost of a false confirmation is the worktree.
`--force` only costs what the refusal named — uncommitted files. The branch
and its commits, pushed or not, survive `git worktree remove --force`; only
the worktree directory and anything not yet committed in it go.

## A handover is only as good as the session that writes it — for the half the session writes

That sentence is now only true of `.agents/handoff.md`, the free-text half.
`tender restart` never reads it before waiting for it — it sends keystrokes and
waits for a file to appear, and hands that file to the successor unexamined.
What ends up in it is entirely up to the session: a role that follows
`roles/_base.md`'s "Handing over" section closely leaves its successor a
usable state; one that summarises the conversation instead, or skips `Not
checked`, leaves a successor that inherits confidence nobody actually earned.
`tender` has no way to tell the difference in that file, and doesn't try to.

The other half, `.agents/state.md` (`lib/state.sh`), `tender` writes itself,
from git and `gh` — the session never touches it. That makes it honest, not
complete: it says what the repository and the forge hold (branch, commits,
uncommitted files, open PR, claim), never whether the work behind them is any
good. A branch with three commits "ahead" says nothing about whether those
three commits are right. Reading it first catches a free-text contradiction;
it cannot catch a free-text lie that happens to agree with the facts.

A wedged session cannot be handed over at all — by definition, it isn't
answering. `tender restart` waits `TENDER_HANDOFF_TIMEOUT` seconds (default 60),
then aborts rather than guessing: no restart happens, and the session is told
so, because a lost handover is exactly what this command exists to prevent.
`--fresh` is the honest way past that: it replaces the process without
asking, and it loses whatever state existed. That trade is the whole point of
naming it explicitly rather than falling back to it automatically — a session
that silently lost its place is worse than one that stops and says so.

## A project named `init`, `status`, `attach`, `list`, `drop`, `restart`, `doctor`, `claims` or `claim-release` is unreachable

`bin/tender`'s argument parsing matches the first word against the nine
subcommand names before it ever considers "everything else is `<repo>
<role>`". A repository whose directory is actually named `list` (say) can
never be reached as `tender list <role>` — that always runs `cmd_list "<role>"`
instead, and `tender list list` looks like a `list` filtered to a repo called
`list`, not a request to start a role there. The failure isn't loud: `tender
list developer` runs `tender list` filtered to a repository named `developer`
and answers `tender: .../developer is not a git repository` if none exists,
which reads like a typo rather than a name collision. Name a project one of
the nine subcommands and every subcommand-shaped invocation of it is gone;
rename the directory (the nine names are otherwise unremarkable) rather than
working around this.

## `none` marks a worktree nobody should work in

`roles/none.md` isn't wired up any differently from the three real roles —
`tender <repo> none [suffix]` creates (or resumes) a worktree exactly the way
`tender <repo> developer` does, just with `.agents/ROLE` set to `none` and a role
file that tells whatever reads it not to work there. Use it for a worktree
that has to exist for some other reason — an old clone, a scratch area, a
restore test — and would otherwise look like an idle `developer` worktree in
`tender list`.
