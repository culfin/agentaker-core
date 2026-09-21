# Tools

`mandate` is vendor-neutral by design. Everything except `launch_command()`
(`lib/tools.sh`) works the same regardless of which coding agent you run: the
worktrees, the role files, `AGENTS.md`, the GitHub flow, `mdt status`,
`mdt attach`.

## The contract

A coding agent needs exactly two things to work with `mandate`:

1. be startable from a tmux window
2. accept a system prompt from a file

That's it. And the second point is soft: for a tool that meets only the
first, `mdt` prints the path to `.agents/context.md` for you to paste as your
first message, which works with any agent that will ever exist. This is
deliberately not a plugin system and not an abstraction layer over agent
behaviour — see `docs/concept.md`. It's one launch line, nothing more, which
is exactly what makes it checkable against a tool this project has never
heard of.

## Adding your tool: a config file, no code change

Add a line to your tools file — no PR, no release, no waiting on this
project:

    ${XDG_CONFIG_HOME:-$HOME/.config}/mandate/tools

`$MDT_TOOLS_FILE` overrides the location.

Format: one tool per line, fields separated by whitespace, `#` starts a
comment (the whole line, not a trailing remark). Deliberately not YAML, JSON
or TOML — this repository has no parser for any of those and isn't getting
one for a three-column table.

    # name      launch command (use {context} for the role file)         status
    claude      claude --append-system-prompt-file {context}              verified:2026-09-20
    codex       codex --prompt-file {context}                             unverified
    mytool      mytool --system {context}                                 unverified

- **name** — what you'd pass as `MDT_TOOL` (or the bare word, since it's the
  default lookup key: `MDT_TOOL=mytool mdt myproject developer`).
- **launch command** — the argv that starts the tool, one line. `{context}`
  is replaced with the path to the assembled role file; it must appear
  somewhere in the command, or the tool would start and never receive its
  role — `mdt` refuses to launch a line like that rather than doing it
  silently (see "What the format cannot do", below).
- **status** — `verified:<date>` if you (or whoever wrote the line) actually
  ran it and confirmed the role arrived, `unverified` otherwise. Anything
  else is treated as `unverified` — the honest default when a line doesn't
  say clearly. `mdt doctor <tool>` is how you get to `verified:` truthfully;
  see below.

A line for `claude` or `codex` **overrides** the built-in row of the same
name; a line for any other name adds one. Two lines for the same name: the
first one found wins, and later ones are simply never reached — not treated
as an error, so a stray duplicate doesn't wedge you if you're not looking at
it right now.

**Without a tools file, nothing changes.** No file, or no line in it for the
tool you asked for, means `mdt` behaves exactly as it did before this table
existed — the built-in `claude`/`codex` branches in `launch_command()`, byte
for byte. That's the property that matters most here: this is additive, not
a rewrite of the zero-config path.

### What the format cannot do

There is no quoting. A field is whatever whitespace-splitting gives you, so
an argument that itself needs to contain a space — `--flag "two words"` —
cannot be expressed as a single argv element in this file. If your tool
genuinely needs that, this format is the wrong tool for it; open an issue
rather than working around it with a wrapper script that reintroduces the
complexity this format exists to avoid. In practice every tool this project
has seen so far takes its flags as single unquoted tokens, `{context}`
included.

### A broken line doesn't take down the rest of the file

A line with too few fields is reported (file and line number) to stderr and
skipped — the tool named on it, if any, simply isn't found there, the same
as if the line weren't in the file at all. A line that's shaped right but
never mentions `{context}` is different: that one names a real tool by a
real name, and would launch it with no role, silently — `mdt` refuses that
specific line outright (naming the file and line number) rather than
starting a session that looks fine and isn't. See `lib/tools.sh` for exactly
where that line is drawn.

## `mdt doctor` — checking a tool actually works

    mdt doctor            # every tool mdt currently knows how to start
    mdt doctor claude      # just this one

This is the hand check that verified Claude Code on 2026-09-20 (see below),
as a command anyone can run against their own tool: it starts the tool with
a throwaway context asking it to print a fixed marker line, waits up to
`MDT_DOCTOR_TIMEOUT` seconds (default 15) and reports whether the marker
arrived.

It never touches a real project — its own `mktemp -d` directory, its own
context file, both removed before the command returns — and it never blocks
past the timeout: a tool that doesn't answer is killed, not waited for
indefinitely. This matters more here than almost anywhere else in `mandate`:
`doctor` is the one command whose entire job is starting an arbitrary
external program.

**What it can't fully verify.** The contract above only promises a tool
accepts a system prompt from a file — not that it acts on an instruction in
that file *before* anything else. A tool that only speaks after a first
interactive message will report "no response" under `doctor` even though it
works fine by hand in a real tmux window, because `doctor` has no way to
send that first message without becoming tool-specific. Read a "no response"
result as "couldn't confirm automatically," not as "doesn't work" — the same
honesty this table already asks for, just from the tool's side this time.

## Status, honestly

**Verified** means what it says: run and checked, on the date given, either
by hand or via `mdt doctor`. For example:

    $ claude --append-system-prompt-file /tmp/rolle.txt -p "Welche Rolle hast du?"
    REVIEWER

**Unverified** means the opposite, plainly. Treating an unverified claim as
if it were verified is worse than not making the claim at all: it costs you
the afternoon you spent trusting it. `mdt` says this out loud, too — starting
a session on an unverified path (built-in or from the tools file) prints a
line to stderr naming the tool and pointing here. A table nobody has open at
that moment is not a warning.

## Built-in table

| Tool | `MDT_TOOL` | How the role is passed | Status |
|---|---|---|---|
| Claude Code | `claude` | `--append-system-prompt-file` | **verified** 2026-09-20 |
| Codex CLI | `codex` | `--prompt-file` | **unverified** — please report |
| anything else, without a tools-file line | any | `mdt` prints the path to `.agents/context.md`; paste it as your first message | works, manually |

`codex` was not installed on the machine this project was built on; the
branch in `launch_command()` that handles it is a best guess from the CLI's
documented flags, not something that has actually launched a session. The
comment above it in `lib/tools.sh` says so:

```bash
codex)
  # UNVERIFIED — codex was not installed when this was written.
  # If this is wrong, fix it here and say so in docs/tools.md.
  TOOL_STATUS=unverified
  LAUNCH_CMD=(codex --prompt-file "$ctx")
  ;;
```

If you use Codex CLI, either add a `verified:` line for it to your own tools
file once `mdt doctor codex` confirms it, or open a pull request that fixes
the built-in branch and updates this table's status — say which version you
tested against.

## Adding your tool to this table (optional)

Your tools-file line is all `mandate` itself needs — nothing here requires
editing this repository. This section is for tools worth listing so the next
person doesn't have to rediscover them: open a PR with a new row below,
naming the version you tested and the date, and keep the same honesty rule —
don't mark a row **verified** you haven't actually run.

## What every tool gets

- Roles, worktrees, the GitHub flow, `mdt status`, `mdt attach` — all of it.
- The project's `AGENTS.md`, because that is an
  [open standard](https://agents.md) read by more than twenty tools.

## What only Claude Code gets

- The subagents in `agents/` (ten, a curated selection — see `agents/README.md`
  for what upstream actually holds) — their file format is Claude Code's.
- The optional SessionStart hook in `hooks/`, packaged as a Claude Code plugin
  via `.claude-plugin/`. It reads `.agents/ROLE` and emits the same text
  `mdt` would have assembled, for a session started by hand
  (`cd <worktree> && claude`) rather than through `mdt <repo> <role>`.

Neither is required. Without them the core is unchanged: a non-Claude session
still gets its worktree, its `AGENTS.md`, and — via `mdt <repo> <role>` — its
role text, just handed to the process differently or, for an unsupported
tool, printed for you to paste in yourself.
