# Changelog

## Unreleased

`tender status <owner> --json [--since <time>]` prints the board as one JSON
object (app issue #10, "what happened since you were away"): `waiting_on_you`,
`approved`, `waiting_for_review`, `ready`, and with `--since` also `merged`.
Each section is `{"ok": true, "truncated": …, "items": [...]}` or `{"ok": false, "error": …}`
— "could not ask" is never an empty list — and the exit status is 1 if any
section could not be asked. `--since` takes ISO-8601 UTC only and hands gh its
own date filters (`--updated`, `--merged-at`); "updated since" approximates
"changed since", and `tender status --help` says so. The JSON board asks the
text board's own searches, through the same engine. `--since` also takes fractional seconds and `+00:00`, and hands gh
(and echoes) the plain `YYYY-MM-DDTHH:MM:SSZ`; `--since` without `--json` and
an unknown option are refused with exit status 2.

The text board changes with it, so the two boards say the same thing:
"waiting on you" also lists PRs with `needs-decision`; "approved, waiting for
merge" also lists PRs cleared by the `approved` label (single-account mode),
each PR once; and "waiting for review" no longer lists a label-cleared PR,
which the `--review none` approximation used to count as unreviewed. Every
search asks for up to 100 results instead of gh's default 30, and a section
that came back with exactly 100 says `(showing the first 100 — there may be
more)` (JSON: `"truncated": true`) — or, when none of those 100 is left after
the local filters, `(none among the first 100 — there may be more)`. A gh answer
that is not in the expected shape — empty output included, or a count the
records do not match — is now "could not ask: unexpected gh output: …", never a
row or an empty section. Separator control characters in a title are dropped. The
board's questions and the engine that asks them moved from `bin/tender` to
`lib/status.sh`.

Agents on several machines are documented (issue #7): they already coordinate
through the claim refs on the forge, with no central process. `docs/flow.md`,
"Across machines", names what each machine needs, which commands see every
machine and which only this one, and the one trap — give each machine's
sessions a suffix, or two `tender acme developer` push to the same branch.

Issues can ask for a report instead of a change (issue #6). A human labels them
`scout` next to `ready`; the developer claims them as usual and answers with a
comment on the issue when the answer serves only that issue, or with a PR
adding `docs/reports/<topic>.md` when someone will look for it again — reviewed
on its sources, since it has no tests. Shipping stays the default: an agent
that hits a question which could change what gets built asks it with
`needs-decision` instead of turning the issue into a report itself. See
`roles/developer.md`, "A report instead of a change".

A coding agent's first-start question no longer hides (issue #8). Measured:
Claude Code asks once per repository whether it may trust the folder, with
"No, exit" preselected, and waits — which an unattended window turns into a
session that silently does nothing. Trust is keyed on the repository root, so
one confirmation covers every worktree. `tender init` now lists that
confirmation as a step, and `docs/limits.md` explains it; `tender` does not
write another tool's trust settings itself.

`tender doctor` says who can close each gap, and how (issue #9). Every problem
is now a `human:` (or, once there is a `--fix`, `fixable:`) line followed by an
`action:` line with the exact next step, naming the tool. A tool that gives no
answer in time reads as "could not confirm automatically", not as a failure.
See `docs/tools.md`, "How it reports a gap".

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
