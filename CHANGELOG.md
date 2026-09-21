# Changelog

## Unreleased

The tool table is now a config file (issue #2): a line in
`~/.config/treetender/tools` (or `$TENDER_TOOLS_FILE`) adds or overrides a coding
agent without editing `bin/tender` or waiting for a release — see
`docs/tools.md`. Without a tools file, `tender` behaves exactly as before.
Adds `tender doctor [tool]`, which starts a tool with a throwaway context and
checks whether its role arrived.

Adds `tender claims <repo> [--json]` and `tender claim-release <repo> <N>`: the
claim mechanism `roles/developer.md` and `roles/reviewer.md` describe as
prose (a git ref as the lock, a timestamped blob, release-then-reclaim,
never `--force`), now a command — so a GUI can list and take over claims
without reimplementing it. `claim-release` refuses unless the held claim is
actually older than the project's `claim-timeout-days`.

## 0.1.0 — 2026-09-20

First version. Three roles (`developer`, `reviewer`, `maintainer`), the `tender`
command (`init`, start, `attach`, `status`, `list`, `drop`, `restart`),
vendor-neutral by design with one verified tool integration (Claude Code) and
one unverified (Codex), five subagents from agency-agents, four project
examples.
