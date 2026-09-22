# Changelog

## Unreleased

The reviewer token no longer passes through `tmux`'s argv (issue #10). It used
to be handed over as `tmux … -e "GH_TOKEN=<token>"`, readable by `ps` while
that `tmux` client ran; it now takes the route named credentials do — `tender`
only checks that the keychain entry exists, and `lib/credential.sh
--reviewer-token`, inside the new window, reads it and exports `GH_TOKEN`.
Still soft: a missing token warns and starts anyway, now also on `tender
restart` and inside the window. With `TENDER_CREDENTIAL` also set, a named
credential whose account is `GH_TOKEN` wins. When the entry exists but the
window cannot read it, the reviewer now starts with `GH_TOKEN` and
`GITHUB_TOKEN` cleared rather than with whatever the tmux server inherited.
See `docs/setup.md`, sections 7 and 8.

The old `-e` also set `GH_TOKEN` in the tmux *session's* environment, so every
later window in a session a reviewer created — a developer's included —
inherited the reviewer's token. Sessions started by an older `tender` still
carry it: kill them once, or run `tmux set-environment -t tender-<repo> -u
GH_TOKEN`.

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
status <owner>` gains one line per set-up local project whose GitHub
`origin` belongs to that owner and has agent PRs open — open PRs on
`<repo>-developer[-<suffix>]` branches, drafts included — with the age of
the oldest; a count that could not be asked says so and fails the board,
never reads as zero, and a listing cut off at 200 open PRs says `≥N`.
`max-open-prs: N` in `AGENTS.md` (optional; the template ships it commented
out) sets a cap: the developer role checks it before `gh pr create` and, at
the cap, keeps its branch pushed and works on review feedback instead of
opening or claiming more; `tender <repo> developer` refuses an additional
developer session when the cap is reached and one is already running (found
by its pane's worktree path) — never the first. Without the field nothing
changes; an invalid value is reported and treated as no cap, never as 0. See
`docs/limits.md`.

## 0.1.0 — 2026-09-20

First version. Three roles (`developer`, `reviewer`, `maintainer`), the `tender`
command (`init`, start, `attach`, `status`, `list`, `drop`, `restart`),
vendor-neutral by design with one verified tool integration (Claude Code) and
one unverified (Codex), five subagents from agency-agents, four project
examples.
