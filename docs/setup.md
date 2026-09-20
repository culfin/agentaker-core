# Setup

## 1. Get the tool

    git clone https://github.com/culfin/mandate ~/.mandate
    ln -s ~/.mandate/bin/mdt ~/bin/mdt   # or wherever is actually on your PATH — see below

Requires `git`, `gh` and `tmux`. No runtime, no package manager.

`~/bin` is a guess, and on some machines it's the wrong one: it can exist
without being on `PATH` (`~/.local/bin` is the more common default on a fresh
install), in which case the symlink is created, `mdt` still says "command not
found", and that looks like a broken install rather than a wrong target
directory. Check first:

    echo $PATH | tr ':' '\n' | grep -E '/bin$|/\.local/bin$'

and link into one of those instead if `~/bin` isn't among them.

`mdt` resolves its own symlink to find `roles/` next to the real install, so
it works wherever you link it from — move `~/.mandate` later and the
link still finds it, as long as the link itself isn't moved somewhere that no
longer points at it.

## 2. Give the reviewer its own account

This is what makes reviews work. A forge refuses to let an author approve their
own pull request:

    $ gh pr review 163 --approve
    failed to create review: Can not approve your own pull request

The break happens earlier than that message suggests, and quietly: `gh pr
edit <N> --add-reviewer <your own login>` — the command `roles/developer.md`
uses to ask for review — exits 0 and prints the PR URL as if it worked, but
does not add you as a requested reviewer (confirmed against the API:
`requested_reviewers` stays empty). Only `--approve` and `--request-changes`
fail loudly; the request itself just silently does nothing. So without a
second account, the reviewer's queue (`is:open draft:false
review-requested:@me`) never has anything in it to begin with — the loud
failure above is what you'd hit if you tried to review anyway, by PR number,
skipping the queue.

Since your sessions share your token, the reviewer needs a second account. One
is enough — `developer` and `maintainer` do nothing that gets blocked.

1. Create an account for it. A `+` alias works: `you+reviewer@example.com`.
2. Give it write access to the repositories it reviews.
3. Create a fine-grained token: **Pull requests** read and write, **Contents**
   read, **Issues** read and write.
4. Store it in the OS keychain — never in a settings file:

       # macOS
       security add-generic-password -s mandate-reviewer -a "$USER" -w '<token>'
       # Linux (libsecret)
       secret-tool store --label="mandate reviewer" service mandate-reviewer

   `mdt` reads it back with `security find-generic-password -s
   mandate-reviewer -w` (or the `secret-tool lookup` equivalent) — the
   exact commands are in `read_reviewer_token()` in `bin/mdt`, if you want to
   check by hand.

5. Put that account's login in each project's `AGENTS.md`:

       reviewer: your-reviewer-login

   Without it the developer has no one to ask for a review.

`mdt <repo> reviewer` reads the token and sets `GH_TOKEN` for that session
only. If it is missing, `mdt` says so and starts anyway — you find out at the
first approval, not at session start:

    mdt: no reviewer token found — approvals will fail. See docs/setup.md

## 3. Lock the production boundary

`mdt init` offers to do this; here it is by hand.

One API call creates an environment that requires your approval:

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
`mdt init` treats that failure as "create it by hand" and points back here;
doing it by hand hits the same `422` for the same reason, so if you see it,
the fix is the plan or the repo's visibility, not the recipe.

## 4. Set up a project

    mdt init <repo>

See [adding-a-project.md](adding-a-project.md) for what it does and how to do
it by hand.

## 5. Choose your coding agent

    export MDT_TOOL=claude      # default

See [tools.md](tools.md) for what is supported and what is untested.

## 6. Tell your tabs apart

Several sessions across several projects means several terminal tabs, and by
default they all say the same thing. `mdt` sets the tab title itself, scoped
to that project's tmux session only — it never touches the global title, so
your other tmux sessions keep whatever they already show.

The title is short on purpose: project, then who, nothing else — the session
name already carries "mdt", repeating it would just cost characters:

    dateye · DEV
    dateye · DEV·eyeoffice        # a suffixed developer session

The tag is `DEV` / `REV` / `MNT` for the three roles, `---` for `none`, and
the first three letters uppercased for anything else.

On iTerm2, the tab itself is coloured by role — developer blue, reviewer
yellow, maintainer green, anything else uncoloured — using iTerm2's own
proprietary escape codes, wrapped for tmux passthrough. This is iTerm2-only;
see [limits.md](limits.md) for what happens in every other terminal. Turn it
off, still keeping the title:

    export MDT_TAB_COLOUR=0

## 7. Replacing a session without losing its place

A session sometimes has to go — a tool update, a role file that changed, one
that's wedged. Killing it loses where it had got to; reloading the whole
conversation is expensive, tool-specific, and after an update carries
artefacts of the version you just replaced.

    mdt restart myproject DEV

asks the session to write `.agents/handoff.md` (see "Handing over" in
`roles/_base.md` for what belongs in it), waits for the file, replaces the
process, and hands the file to its successor as part of its context. If the
session doesn't answer within `MDT_HANDOFF_TIMEOUT` seconds (default 60),
`mdt` aborts rather than restarting — see [limits.md](limits.md) for why, and
for what `--fresh` costs you when you use it instead:

    mdt restart myproject DEV --fresh   # replace without asking — loses state
    mdt restart --all                   # every running session, across every project
