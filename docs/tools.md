# Tools

`worktree-crew` is vendor-neutral by design. Everything except one function in
`bin/wtc` — `launch_command()` — works the same regardless of which coding
agent you run: the worktrees, the role files, `AGENTS.md`, the GitHub flow,
`wtc status`, `wtc attach`.

| Tool | `WTC_TOOL` | How the role is passed | Status |
|---|---|---|---|
| Claude Code | `claude` | `--append-system-prompt-file` | **verified** 2026-09-20 |
| Codex CLI | `codex` | `--prompt-file` | **unverified** — please report |
| anything else | any | `wtc` prints the path to `.agents/context.md`; paste it as your first message | works, manually |

**Verified** means what it says: run and checked on the development machine on
the date given, for example:

    $ claude --append-system-prompt-file /tmp/rolle.txt -p "Welche Rolle hast du?"
    REVIEWER

**Unverified** means the opposite, plainly: `codex` was not installed on the
machine this project was built on, and the branch in `launch_command()` that
handles it is a best guess from the CLI's documented flags, not something that
has actually launched a session. The comment above it in `bin/wtc` says so:

```bash
codex)
  # UNVERIFIED — codex was not installed when this was written.
  # If this is wrong, fix it here and say so in docs/tools.md.
  LAUNCH_CMD=(codex --prompt-file "$ctx")
  ;;
```

If you use Codex CLI with this tool, please open a pull request that either
confirms this line or fixes it — and updates this table's status to
**verified** with the date and version you tested.

Treating an unverified claim as if it were verified is worse than not making
the claim at all: it costs you the afternoon you spent trusting it. This table
exists so you don't have to find that out by trying.

## Adding your tool

One branch in `launch_command()` in `bin/wtc`, one row in this table. Nothing
else in the repository changes. Pull requests welcome — please say which
version you tested against.

## What every tool gets

- Roles, worktrees, the GitHub flow, `wtc status`, `wtc attach` — all of it.
- The project's `AGENTS.md`, because that is an
  [open standard](https://agents.md) read by more than twenty tools.

## What only Claude Code gets

- The five subagents in `agents/` — their file format is Claude Code's. See
  `agents/README.md`.
- The optional SessionStart hook in `hooks/`, packaged as a Claude Code plugin
  via `.claude-plugin/`. It reads `.agents/ROLE` and emits the same text
  `wtc` would have assembled, for a session started by hand
  (`cd <worktree> && claude`) rather than through `wtc <repo> <role>`.

Neither is required. Without them the core is unchanged: a non-Claude session
still gets its worktree, its `AGENTS.md`, and — via `wtc <repo> <role>` — its
role text, just handed to the process differently or, for an unsupported tool,
printed for you to paste in yourself.
