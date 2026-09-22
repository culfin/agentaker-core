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

Adds `tender init <repo> --propose --json` and `tender init --commit`, for a
setup wizard (app issue #6). `--propose --json` prints what `init` would do —
including the exact `AGENTS.md` text, from the same rendering `init` writes —
as one JSON object, and changes nothing. `--commit` commits exactly
`AGENTS.md` before the worktrees are made, so all three roles see it at once
(also one on disk that was never committed, so a rerun finishes a refused
commit). `--trunk`, `--reviewer`, `--tests` and `--boundary` now refuse
control characters (exit 2) — a newline would forge lines in `AGENTS.md`.
Without either flag `init` behaves as before. `tender claims --json` now
escapes every control character instead of flattening newlines to spaces
(the escaper is shared, `lib/json.sh`).

Agent PRs are measured, and a project can cap them (issue #1). `tender
status` gains one line per set-up local project with agent PRs open — open
PRs on `<repo>-developer[-<suffix>]` branches, drafts included — with the
age of the oldest; a count that could not be asked says so and fails the
board, never reads as zero. `max-open-prs: N` in `AGENTS.md` (optional; the
template ships it commented out) sets a cap: the developer role checks it
before `gh pr create` and, at the cap, keeps its branch pushed and works on
review feedback instead of opening or claiming more; `tender <repo>
developer` refuses an additional developer session when the cap is reached
and one is already running — never the first. Without the field nothing
changes; an invalid value is reported and treated as no cap, never as 0.
See `docs/limits.md`.

## 0.1.0 — 2026-09-20

First version. Three roles (`developer`, `reviewer`, `maintainer`), the `tender`
command (`init`, start, `attach`, `status`, `list`, `drop`, `restart`),
vendor-neutral by design with one verified tool integration (Claude Code) and
one unverified (Codex), five subagents from agency-agents, four project
examples.
