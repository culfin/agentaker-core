# Phase boundaries

A **phase** is one coherent stretch of work inside a session: picking up one
issue and carrying it to a draft PR, or taking one review request to a
verdict. A phase boundary is the point between two such stretches — right
after one ends, or right before the next begins — where something has to be
decided about how the next stretch continues, not whether it does.

## The options

| Option | Context | Process | Worktree / session |
|---|---|---|---|
| **Continue** | kept in full | keeps running | same |
| **Clear** | discarded | keeps running, empty | same |
| **Compact** | summarised, then kept | keeps running | same |
| **Subagent** | a fresh, bounded context for one sub-task; thrown away when it returns | a second process, briefly, alongside the first | same — the subagent has no worktree of its own |
| **Hand over in place** (`mdt restart`) | written to `.agents/handoff.md`, then read into the new context | replaced in place (`tmux respawn-pane`) | same |
| **Hand off, portable** | written to a file outside the worktree | this one ends; a new one starts elsewhere | a different worktree, possibly a different harness, directory, or person |

## When each is right

- **Continue** — the default. Do it until the phase is actually finished, or
  the context is visibly straining: repeating itself, losing decisions it
  made earlier in the same phase.
- **Clear** — the phase is done and the next one shares nothing worth
  carrying: a merged PR, a fully resolved review round. Cheaper than a
  handover, because nothing has to be written down — which is also the risk:
  only clear once the artefacts (the PR, its comments, the commits) carry the
  state that matters, not your context.
- **Compact** — the phase is not done, but the context is long and most of it
  is settled fact rather than an open question. Unlike clear, the process
  keeps running and the thread of the current phase survives.
- **Subagent** — a bounded sub-task inside the current phase that would
  otherwise bloat the main context with detail nobody upstream needs again: a
  wide search, a narrow investigation. Mandate's five subagents under
  `agents/` are this shape — see `docs/concept.md`, "Roles versus subagents."
  Not really a phase boundary for the session itself: the main phase resumes
  around it once the subagent reports back.
- **Hand over in place (`mdt restart`)** — the phase is not done, but this
  *process* needs replacing: a context that has gotten stuck, a crashed pane,
  a scheduled restart. Same worktree, same role, same identity — whoever
  picks the work up next is this session, continued. This is the one
  mechanised in `mandate`: it sends the handover prompt, waits for
  `.agents/handoff.md` to appear, then replaces the process
  (`restart_window()` in `lib/manage.sh`) — see `roles/_base.md`, "Handing
  over," for the four-line shape the file itself takes. `mdt restart <repo>
  <name> --fresh` is the same in-place replacement without asking for a
  handoff first — reach for it when the state genuinely is not worth writing
  down (a context stuck rewriting the same fix on loop), not as the default.
- **Hand off, portable** — the *destination* changes, not just the process: a
  new harness, a new directory, a colleague picking the work up by hand. None
  of mandate's machinery travels with it — no worktree, no `.agents/`
  directory — so write the note by hand, in the same shape a handover takes
  (`Working on` / `In progress` / `Next` / `Not checked`), and put it wherever
  whoever opens it next will actually look.

## Credit

The five-way framing above — continue, clear, compact, handoff, subagent — is
from mattpocock/skills' `ask-matt` skill, which calls it "the fuzziest
decision in this whole map." `mandate` borrows the question, not the
implementation: only one of the five is mechanised here (hand over in place);
the rest are either a feature of the coding agent you're running, or, for a
portable handoff, a manual step outside anything `mandate` tracks.
