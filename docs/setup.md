# Setup

## 1. Get the tool

    git clone https://github.com/culfin/treetender ~/.treetender
    ln -s ~/.treetender/bin/tender ~/bin/tender   # or wherever is actually on your PATH — see below

Requires `git`, `gh` and `tmux`. No runtime, no package manager.

`~/bin` is a guess, and on some machines it's the wrong one: it can exist
without being on `PATH` (`~/.local/bin` is the more common default on a fresh
install), in which case the symlink is created, `tender` still says "command not
found", and that looks like a broken install rather than a wrong target
directory. Check first:

    echo $PATH | tr ':' '\n' | grep -E '/bin$|/\.local/bin$'

and link into one of those instead if `~/bin` isn't among them.

`tender` resolves its own symlink to find `roles/` next to the real install, so
it works wherever you link it from — move `~/.treetender` later and the
link still finds it, as long as the link itself isn't moved somewhere that no
longer points at it.

This is everything you need to run in **single-account mode**, the default:
every role runs under your own token, and review works through the draft
state plus one label instead of GitHub's native approval — see
`roles/reviewer.md` and `docs/flow.md` for how. There is no second-account
step required before you can prove the flow works end to end; if you want
the separation a forge enforces rather than one the role files merely ask
for, that's the last section below, and it's optional.

## 2. Lock the production boundary

`tender init` offers to do this; here it is by hand.

One API call creates the environment — or updates it, if `production` already
exists under a different rule set. `PUT` is both; there is no separate create
call. `tender init` checks first and tells you which one happened, but GitHub
does not document whether updating preserves rules the PUT doesn't mention —
if the environment already had other rules, verify with the command below
rather than assuming either way:

    MYID=$(gh api user --jq .id)
    printf '{"reviewers":[{"type":"User","id":%s}]}' "$MYID" \
      | gh api -X PUT repos/OWNER/REPO/environments/production --input -

Then one line in the workflow that crosses the boundary, on the job that does it:

    jobs:
      release:
        environment: production

Now that job stops and waits for you in the browser, no matter which session
started it. Verify it took:

    gh api repos/OWNER/REPO/environments \
      --jq '.environments[] | {name, rules: [.protection_rules[].type]}'

You want to see `required_reviewers`. An environment without it is a label, not a lock.

Required reviewers need a public repository, or GitHub Pro/Team/Enterprise for
a private one — on a private repo without that plan, the API call above fails
with `422` (`"Please ensure the billing plan supports the required reviewers
protection rule"`) and leaves a bare environment behind with no rule attached.
`tender init` treats that failure as "create it by hand" and points back here;
doing it by hand hits the same `422` for the same reason, so if you see it,
the fix is the plan or the repo's visibility, not the recipe.

## 3. Set up a project

`<repo>` below is resolved under `TENDER_PROJECTS_DIR` (default `~/Projekte`) —
set it first if your repositories live somewhere else, or `init` fails with
"not a git repository" against a path that doesn't exist:

    export TENDER_PROJECTS_DIR=~/code   # only if your repos aren't under ~/Projekte
    tender init <repo>

See [adding-a-project.md](adding-a-project.md) for what it does and how to do
it by hand.

## 4. Choose your coding agent

    export TENDER_TOOL=claude      # default

Claude Code and Codex CLI are built in; anything else goes in a tools file
(`~/.config/treetender/tools`) instead of a code change — see
[tools.md](tools.md) for the format, what's verified versus untested, and
`tender doctor` for checking a tool actually works before you rely on it
unattended.

## 5. Tell your tabs apart

Several sessions across several projects means several terminal tabs, and by
default they all say the same thing. `tender` sets the tab title itself, scoped
to that project's tmux session only — it never touches the global title, so
your other tmux sessions keep whatever they already show.

The title is short on purpose: project, then who, nothing else — the session
name already carries "tender", repeating it would just cost characters:

    dateye · DEV
    dateye · DEV·eyeoffice        # a suffixed developer session

The tag is `DEV` / `REV` / `MNT` for the three roles, `---` for `none`, and
the first three letters uppercased for anything else.

On iTerm2, the tab itself is coloured by role — developer blue, reviewer
yellow, maintainer green, anything else uncoloured — using iTerm2's own
proprietary escape codes, wrapped for tmux passthrough. This is iTerm2-only;
see [limits.md](limits.md) for what happens in every other terminal. Turn it
off, still keeping the title:

    export TENDER_TAB_COLOUR=0

## 6. Replacing a session without losing its place

A session sometimes has to go — a tool update, a role file that changed, one
that's wedged. Killing it loses where it had got to; reloading the whole
conversation is expensive, tool-specific, and after an update carries
artefacts of the version you just replaced.

    tender restart myproject DEV

asks the session to write `.agents/handoff.md` (see "Handing over" in
`roles/_base.md` for what belongs in it), waits for the file, replaces the
process, and hands the file to its successor as part of its context. If the
session doesn't answer within `TENDER_HANDOFF_TIMEOUT` seconds (default 60),
`tender` aborts rather than restarting — see [limits.md](limits.md) for why, and
for what `--fresh` costs you when you use it instead:

    tender restart myproject DEV --fresh   # replace without asking — loses state
    tender restart --all                   # every running session, across every project

`--all` restarts one session at a time, not in parallel, so it prints the
worst case up front before starting anything: N running sessions is up to
N × `TENDER_HANDOFF_TIMEOUT` if every one of them is wedged and times out
waiting for a handover — six sessions at the 60s default is up to six
minutes, and that line is what tells you before it starts, not partway
through.

## 7. If you want the separation enforced: a second account

Everything above runs in **single-account mode**: `roles/reviewer.md` and
`docs/flow.md` cover how review works there, through the draft state and one
label rather than GitHub's native approval. This section is optional — the
upgrade to **two-account mode**, for anyone who wants a forge to enforce the
separation between developer and reviewer instead of relying on the role
files asking for it. Nothing before this point requires it.

A forge refuses to let an author approve their own pull request, under a
single account or several:

    $ gh pr review 42 --approve
    failed to create review: Can not approve your own pull request

Under a single shared account that refusal has no way around it, which is why
single-account mode uses the `approved` label and the draft state in its
place — see `roles/reviewer.md`. A second account is what removes the wall
instead of working around it: give the reviewer a login of its own, and
`--approve` succeeds on a PR that account did not author.

The break happens earlier than that message suggests, and quietly, regardless
of how many accounts are involved: `gh pr edit <N> --add-reviewer <your own
login>` — the command `roles/developer.md` uses to ask for review once you're
on two-account mode — exits 0 and prints the PR URL as if it worked, but does
not add you as a requested reviewer (confirmed against the API:
`requested_reviewers` stays empty). Only `--approve` and `--request-changes`
fail loudly; the request itself just silently does nothing. So without a
second account, the reviewer's queue (`is:open draft:false
review-requested:@me`) never has anything in it to begin with — the loud
failure above is what you'd hit if you tried to review anyway, by PR number,
skipping the queue. This is exactly why single-account mode does not use
`--add-reviewer` or that queue at all.

If you want GitHub's native review states back, the reviewer needs a second
account. One is enough — `developer` and `maintainer` do nothing that gets
blocked even on a shared one.

1. Create an account for it. A `+` alias works: `you+reviewer@example.com`.
2. Give it write access to the repositories it reviews.
3. Create a fine-grained token: **Pull requests** read and write, **Contents**
   read, **Issues** read and write.
4. Store it in the OS keychain — never in a settings file:

       # macOS
       security add-generic-password -s treetender-reviewer -a "$USER" -w '<token>'
       # Linux (libsecret)
       secret-tool store --label="treetender reviewer" service treetender-reviewer

   `tender` reads it back with `security find-generic-password -s
   treetender-reviewer -w` (or the `secret-tool lookup` equivalent) — the
   exact commands are in `read_reviewer_token()` in `bin/tender`, if you want to
   check by hand.

5. Put that account's login in each project's `AGENTS.md`:

       reviewer: your-reviewer-login

   This is also the mode switch: `roles/reviewer.md` treats a login here
   that differs from a session's own as two-account mode, and single-account
   mode otherwise — leave it blank, or matching your own login, to stay on
   single-account mode.

`tender <repo> reviewer` reads the token and sets `GH_TOKEN` for that session
only. If it is missing, `tender` says so and starts anyway — you find out at the
first approval, not at session start:

    tender: no reviewer token found — approvals will fail. See docs/setup.md

## 8. Named credentials for an agent

A separate mechanism from the reviewer token above, and stricter: `tender` never
starts an agent without a credential it was told to use. Where an app (not
this project) has stored an API key under a label in the OS keychain,

    TENDER_CREDENTIAL=work tender myproject developer

picks that entry, puts it into the started agent's *environment*, and never
lets it touch a process's argv — not `tender`'s own, not `tmux`'s, not the
agent's. `tmux new-window`/`new-session` inherit the environment of the tmux
*server*, not of the caller, which is why the reviewer token above is passed
via `-e "GH_TOKEN=$token"` instead — but `-e "KEY=value"` puts the secret
into `tmux`'s own argv, visible to `ps` for as long as that process runs.
`TENDER_CREDENTIAL` avoids that: only the label travels through `tender`'s own argv
and `tmux`'s; the value is fetched from inside the new pane's own process,
right before the agent starts, by `lib/credential.sh` run directly rather
than sourced (see its own header). `tests/test_credential.sh` proves this
with `ps -o args` against the actual processes involved, not just by reading
the code.

Storage contract — the app writes what `tender` reads, so agree it here:

    # macOS — -w last, with no value after it: security then prompts for it
    security add-generic-password -s treetender-cred-work -a ANTHROPIC_API_KEY -w
    # Linux (libsecret) — prompts for the value as well
    secret-tool store --label="treetender-cred-work" service treetender-cred-work account ANTHROPIC_API_KEY

Never type the value into the command line itself (`-w 'sk-…'`): it would
land in the argv of `security` and in your shell history — exactly the
exposure this mechanism exists to avoid.

On macOS, a keychain entry is readable without a prompt only by the
program that created it. An entry created with `security` as above is read
back by `security`, so `tender` gets it silently. An entry an app wrote
through its own keychain calls makes macOS ask once whether `security` may
read it — answer "Always Allow", or the start waits on that dialog.

- **service**: `treetender-cred-<label>` — `<label>` is what `TENDER_CREDENTIAL`
  names, a plain identifier (letters, digits, `-` and `_`); it ends up in
  both a keychain service name and a shell command line, so anything else is
  rejected before use.
- **account**: the environment variable name the started agent should see —
  `tender` never knows this in advance. It exports whatever account name the
  entry carries; which variable a given tool reads is the app's business,
  not this project's.
- **password**: the value.

Unlike the reviewer token, a missing or unreadable credential is not a soft
warning: `tender` refuses to start the session at all.

    tender: no readable credential named 'work' in the keychain — refusing to start without it. See docs/setup.md

An agent that started anyway, without its key, might quietly authenticate
under some other, already-logged-in account instead — silently, and against
whoever's login happened to be lying around. A failed start is cheaper than
that. `TENDER_CREDENTIAL` unset behaves exactly as it did before this mechanism
existed — nothing changes for a session that doesn't ask for a credential.

`tender restart` keeps the credential. A start records the label — never
the value — once tmux has actually opened the window (a dry run records
nothing), under `${XDG_STATE_HOME:-~/.local/state}/treetender/credentials/`,
outside the worktree, so an agent cleaning up its worktree cannot delete it.
A restart says which label it restores and puts the same key back — or, if
that entry has become unreadable, refuses before it touches the running
session, which then keeps running as it was. Starting a second window in the
same worktree replaces the record with that start's label.

The key is looked up twice: once by `tender` before anything starts, and
once more inside the new window, right before the agent — the second
lookup runs in the tmux server's environment, which can differ from
yours. If that one fails, the window stays open showing why, until you
press Enter; nothing is started without the key. On a restart the old
agent has already been replaced at that point.

Account names that would change how the agent itself starts are refused
even though they are valid identifiers: `PATH`, `HOME`, `IFS`, `BASH_*`,
`LD_*`, `DYLD_*`, `TMUX*`, `TENDER_*` and a few other shell variables.
Store values as printable ASCII — API keys are — because macOS's `security`
prints anything else in hex, and the agent would receive the hex.
