# Changelog

## Unreleased

The tool table is now a config file (issue #2): a line in
`~/.config/mandate/tools` (or `$MDT_TOOLS_FILE`) adds or overrides a coding
agent without editing `bin/mdt` or waiting for a release — see
`docs/tools.md`. Without a tools file, `mdt` behaves exactly as before.
Adds `mdt doctor [tool]`, which starts a tool with a throwaway context and
checks whether its role arrived.

## 0.1.0 — 2026-09-20

First version. Three roles (`developer`, `reviewer`, `maintainer`), the `mdt`
command (`init`, start, `attach`, `status`, `list`, `drop`, `restart`),
vendor-neutral by design with one verified tool integration (Claude Code) and
one unverified (Codex), five subagents from agency-agents, four project
examples.
