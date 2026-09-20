# Contributing

## Running the checks

```bash
bash tests/run.sh      # 97 assertions across five test files, no framework
bin/wtc-lint .          # checks the repository stays internally consistent
```

Both must be clean before a PR. `bin/wtc-lint` isn't a check of your working
copy — it checks that examples don't name a role or subagent this repository
doesn't ship, that every `examples/*.AGENTS.md` has the sections the flow
depends on (`trunk:`, `reviewer:`, `## Test commands`, `## Production
boundary`), and that nothing under `roles/` names a specific vendor.

## Vendor neutrality is enforced, not just asked for

`roles/` must never mention a specific coding agent — no `claude`, `codex`,
`gemini`, `cursor`, `copilot`, `anthropic`, or `openai`. `bin/wtc-lint` greps
for this and fails the build if it finds one. `agents/` is exempt: it's
explicitly documented as Claude Code's file format (`agents/README.md`).

## Adding a coding agent

One branch in `launch_command()` in `bin/wtc`, one row in `docs/tools.md`.
Nothing else in the repository changes — that's the design, see
`docs/concept.md`. In your PR, say which version of the tool you tested
against and mark the row **verified**; don't leave a claim in `docs/tools.md`
that you didn't check.

## Adding an example

A new `examples/*.AGENTS.md` must come from a project that actually runs —
not a hypothetical stack. It needs `trunk:`, `reviewer:`, `## Test commands`,
and `## Production boundary` at minimum (`bin/wtc-lint` checks this), and any
role or subagent it names under `## Roles` / `## Subagents` must exist in this
repository.

## `bin/wtc` stays one file, under 450 lines

It's four subcommands over `git`, `gh` and `tmux`, deliberately kept together
so there's one file to read, not a chain of includes. `bin/wtc-lint` enforces
the 450-line ceiling as a guard against creep, not a budget to fill — if you
find yourself pushing toward it, that's the moment to ask whether a
subcommand (most likely `init`) should move to its own file, not to shave
lines to fit.

## Subagents under `agents/` are frozen copies

Each file in `agents/` carries its upstream path and commit SHA in a header
comment, copied verbatim from
[agency-agents](https://github.com/msitarzewski/agency-agents). Don't edit
them directly. To pick up an upstream fix: fix it there, then re-copy the file
here with the new commit SHA in the header. See `agents/README.md` for the
diff command that shows what changed.
