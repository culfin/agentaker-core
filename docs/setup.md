# Setup

## 1. Get the tool

    git clone https://github.com/culfin/worktree-crew ~/.worktree-crew
    export PATH="$HOME/.worktree-crew/bin:$PATH"   # add this line to your shell profile

Requires `git`, `gh` and `tmux`. No runtime, no package manager.

Put the `bin/` directory on `PATH` rather than symlinking `wtc` itself into an
existing `~/bin`: `bin/wtc` finds its own install directory (and with it
`roles/`) from `${BASH_SOURCE[0]}`, which under a symlink resolves to the
*link's* location, not the real one — so a lone `ln -s
~/.worktree-crew/bin/wtc ~/bin/wtc` produces a `wtc` that runs but cannot find
any role file. Confirmed by running it: `wtc: no role file for 'developer' —
see ~/roles` instead of `~/.worktree-crew/roles`.

## 2. Give the reviewer its own account

This is what makes reviews work. A forge refuses to let an author approve their
own pull request:

    $ gh pr review 163 --approve
    failed to create review: Can not approve your own pull request

Since your sessions share your token, the reviewer needs a second account. One
is enough — `developer` and `integrator` do nothing that gets blocked.

1. Create an account for it. A `+` alias works: `you+reviewer@example.com`.
2. Give it write access to the repositories it reviews.
3. Create a fine-grained token: **Pull requests** read and write, **Contents**
   read, **Issues** read and write.
4. Store it in the OS keychain — never in a settings file:

       # macOS
       security add-generic-password -s worktree-crew-reviewer -a "$USER" -w '<token>'
       # Linux (libsecret)
       secret-tool store --label="worktree-crew reviewer" service worktree-crew-reviewer

   `wtc` reads it back with `security find-generic-password -s
   worktree-crew-reviewer -w` (or the `secret-tool lookup` equivalent) — the
   exact commands are in `read_reviewer_token()` in `bin/wtc`, if you want to
   check by hand.

5. Put that account's login in each project's `AGENTS.md`:

       reviewer: your-reviewer-login

   Without it the developer has no one to ask for a review.

`wtc <repo> reviewer` reads the token and sets `GH_TOKEN` for that session
only. If it is missing, `wtc` says so and starts anyway — you find out at the
first approval, not at session start:

    wtc: no reviewer token found — approvals will fail. See docs/setup.md

## 3. Set up a project

    wtc init <repo>

See [adding-a-project.md](adding-a-project.md) for what it does and how to do
it by hand.

## 4. Choose your coding agent

    export WTC_TOOL=claude      # default

See [tools.md](tools.md) for what is supported and what is untested.
