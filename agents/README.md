# Subagents

These are **not** roles. A role is a session with a worktree and permissions; a
subagent is expertise you can call for the length of one task.

## This is a selection, not a mirror

Upstream [agency-agents](https://github.com/msitarzewski/agency-agents) (MIT)
carries 260+ agents across 19 divisions (267 agents, checked 2026-09-21):
Engineering, Design, Marketing, Paid Media, Sales, Product, Project
Management, Testing, Security, Support, Spatial Computing, Specialized,
Finance, Game Development, Academic, GIS, Healthcare, Research, Strategy.
This directory carries ten, verbatim, chosen because they cover ground the
common tooling does not:

- **Engineering** (five, the original set): staged update rollouts,
  quasi-identifiers, ICU/CLDR, cross-crate refactors, diff discipline.
- **Marketing**: SEO strategy (`marketing-seo-specialist`), multi-platform
  content and editorial planning (`marketing-content-creator`), cross-platform
  social campaigns (`marketing-social-media-strategist`).
- **Design**: visual/component systems (`design-ui-designer`), user research
  and usability testing (`design-ux-researcher`).

We deliberately did **not** add a legal/compliance subagent, even though
upstream has ones that come close. A generic subagent cannot know your
licensing class or your data-processing agreements, and false confidence
there is worse than none — that judgment call belongs in your own project's
`AGENTS.md`, with your own rules (e.g. MDR/GDPR), not in a frozen file here.

We don't mirror upstream in full: a frozen copy goes stale, and staying
current is upstream's job, not ours. See `NOTICE`.

## Known limitation

The file format is Claude Code's. Other agents use other formats, and
`agency-agents` maintains converters for sixteen of them. Porting those is a
separate piece of work.

**So: the core of treetender is vendor-neutral, these ten files are not.**
If your tool is not Claude Code, everything works except this layer — your
`AGENTS.md` simply lists no subagents.

## Frozen on purpose

Each file names its upstream commit, so seeing what changed there is one diff:

    git clone --depth 50 https://github.com/msitarzewski/agency-agents /tmp/agency
    diff <(tail -n +7 agents/engineering-privacy-engineer.md) \
         /tmp/agency/engineering/engineering-privacy-engineer.md

Availability is not a recommendation. Which of these a session should call is
decided per project, in that project's `AGENTS.md`.

## Getting another one

Not here yet? Pull it yourself — this directory is flat, and every file
follows the same shape:

1. Pick the file from upstream, e.g. `marketing/marketing-growth-hacker.md`.
2. Read it. Don't copy on the name alone — a division holds dozens of files,
   several near-duplicates of each other.
3. Save it as `agents/<division>-<agent-name>.md` (flat, no subdirectory),
   with a six-line provenance header in the exact shape the existing files
   use — division/filename as `Source:`, the upstream commit you cloned,
   today's date, and the "Frozen on purpose" line.
4. Verify byte-equality: `diff <(tail -n +7 agents/<file>) /tmp/agency/<division>/<file>`
   must print nothing.
5. Add it to a project's `AGENTS.md` under `## Subagents` — `bin/tender-lint`
   fails any example or project file that names a subagent not present as a
   file here, so the file must exist before you reference it.
