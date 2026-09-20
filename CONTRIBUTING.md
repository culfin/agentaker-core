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

### An assertion must have been seen to fail

Write the assertion, run it against code that does not yet satisfy it, and watch
it fail. If you are adding an assertion to code that already works — in a fix
round, say — break that code in a scratch copy and check the assertion notices.

This is not ceremony. Three assertions in this repository's history passed while
proving nothing: one matched a substring of an unrelated error message, one
matched a phrase the command prints regardless, one was satisfied by a different
check returning the same exit code. Every one was caught by someone deliberately
breaking the code, never by running the suite.

Prefer a phrase that only the behaviour under test can produce, and prefer
asserting the mechanism over the outcome — `exit 1` is produced by many things,
`is not a role name` by one.

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

## `bin/wtc` and `lib/init.sh` stay under 450 lines each

`bin/wtc` holds the three everyday subcommands; `lib/init.sh` holds `init`,
which runs once per project. Both stay under 450 lines. The ceiling guards
readability, not a budget: when a file approaches it, ask which block has
become its own concern rather than raising the number.

## Subagents under `agents/` are frozen copies

Each file in `agents/` carries its upstream path and commit SHA in a header
comment, copied verbatim from
[agency-agents](https://github.com/msitarzewski/agency-agents). Don't edit
them directly. To pick up an upstream fix: fix it there, then re-copy the file
here with the new commit SHA in the header. See `agents/README.md` for the
diff command that shows what changed.
