# Subagents

These are **not** roles. A role is a session with a worktree and permissions; a
subagent is expertise you can call for the length of one task.

All five are verbatim copies from
[agency-agents](https://github.com/msitarzewski/agency-agents) (MIT), chosen
because they cover ground the common tooling does not: staged update rollouts,
quasi-identifiers, ICU/CLDR, cross-crate refactors, diff discipline. See `NOTICE`.

## Known limitation

The file format is Claude Code's. Other agents use other formats, and
`agency-agents` maintains converters for sixteen of them. Porting those is a
separate piece of work.

**So: the core of mandate is vendor-neutral, these five files are not.**
If your tool is not Claude Code, everything works except this layer — your
`AGENTS.md` simply lists no subagents.

## Frozen on purpose

Each file names its upstream commit, so seeing what changed there is one diff:

    git clone --depth 50 https://github.com/msitarzewski/agency-agents /tmp/agency
    diff <(tail -n +7 agents/engineering-privacy-engineer.md) \
         /tmp/agency/engineering/engineering-privacy-engineer.md

Availability is not a recommendation. Which of these a session should call is
decided per project, in that project's `AGENTS.md`.
