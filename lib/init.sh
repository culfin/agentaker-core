#!/usr/bin/env bash
# The `atk init` subcommand and its helpers.
#
# Sourced by bin/atk on demand rather than always: init runs once per project
# and never during normal work, so the three everyday subcommands do not pay to
# parse it.
#
# Needs from bin/atk:  die(), usage(), cmd_start(), PROJECTS_DIR
# Provides to it:      DRY_RUN, set for the subshell that creates the worktrees
#                      so cmd_start() prepares them without launching anything
#
# ROLES_DIR is deliberately absent: cmd_start() reads it, and cmd_start() stays
# in bin/atk where it is already in scope.
#
# lib/init_flags.sh, sourced by bin/atk immediately before this file, holds
# argument parsing, --help text and the exit-code contract (issue #3) — see
# its own header. This file stays about what the four steps actually do;
# that one is about how a caller (interactive or a flag-driven GUI) reaches
# them.

# `atk init` shows every step instead of hiding it: each action is proposed and
# confirmed separately, so someone who watched it run can redo it by hand.

ask() {
  # Prompt unless ATK_YES is set; echo the (possibly default) answer.
  local prompt=$1 default=${2:-y} reply
  if [ -n "${ATK_YES:-}" ]; then printf '%s' "$default"; return 0; fi
  printf '  %s [%s] ' "$prompt" "$default" >&2
  read -r reply || reply=""
  printf '%s' "${reply:-$default}"
}

detect_stack() {
  local dir=$1 found=""
  [ -f "$dir/Cargo.toml" ]        && found="$found Rust"
  [ -f "$dir/package.json" ]      && found="$found Node"
  [ -f "$dir/pyproject.toml" ]    && found="$found Python"
  [ -f "$dir/go.mod" ]            && found="$found Go"
  [ -d "$dir/src-tauri" ]         && found="$found Tauri"
  [ -f "$dir/svelte.config.js" ]  && found="$found Svelte"
  if [ -f "$dir/next.config.ts" ] || [ -f "$dir/next.config.js" ]; then
    found="$found Next.js"
  fi
  [ -f "$dir/astro.config.mjs" ]  && found="$found Astro"
  printf '%s' "${found# }"
}

suggest_tests() {
  case "$1" in
    *Rust*Tauri*|*Tauri*)  printf 'cargo test --workspace\npnpm exec svelte-check' ;;
    *Rust*)                printf 'cargo test --workspace' ;;
    *Next.js*|*Node*)      printf 'pnpm lint\npnpm test\npnpm build' ;;
    *Python*)              printf 'pytest -q\nruff check .' ;;
    *Go*)                  printf 'go test ./...' ;;
    *)                     printf '# no test command detected — fill this in' ;;
  esac
}

# The AGENTS.md text `init` proposes, for trunk $1 and detected stack $2, with
# the INIT_* flag values applied. The one rendering: cmd_init() writes it and
# `init --propose --json` (lib/init_propose.sh) shows it, so a caller never
# sees a preview that differs from what init would write. The file on disk is
# exactly this output plus one trailing newline ($(...) strips it, and both
# callers add it back).
init_render_agents_md() {
  local trunk=$1 stack=$2
  local reviewer_line="reviewer:            # GitHub login of the account that reviews here — see docs/setup.md"
  [ -n "$INIT_REVIEWER" ] && reviewer_line="reviewer: $INIT_REVIEWER"

  local tests_body; tests_body=$(suggest_tests "$stack")
  [ "${#INIT_TESTS[@]}" -gt 0 ] && tests_body=$(printf '%s\n' "${INIT_TESTS[@]}")

  local boundary_block
  if [ "$INIT_BOUNDARY_GIVEN" -eq 1 ] && [ -n "$INIT_BOUNDARY" ]; then
    boundary_block=$(cat <<BOUND
    $INIT_BOUNDARY

This line is a boundary agents are asked to respect, not one they are forced
to observe — only a protected environment (offered next, or see
docs/setup.md) actually makes a release wait for you.
BOUND
)
  elif [ "$INIT_BOUNDARY_GIVEN" -eq 1 ]; then
    boundary_block='(intentionally left blank — no production boundary was declared for this project)'
  else
    boundary_block=$(cat <<BOUND
The one line an agent must never cross on its own. Examples:

    git push origin main:production
    npm publish

Replace this with yours. This line is a boundary agents are asked to respect,
not one they are forced to observe — only a protected environment (offered
next, or see docs/setup.md) actually makes a release wait for you.
BOUND
)
  fi

  cat <<EOF
# Agents in this project

trunk: $trunk
$reviewer_line
claim-timeout-days: 2  # days before an unreleased claim counts as orphaned and may be taken over — see docs/limits.md
<!-- max-open-prs: 3  cap on open agent PRs — see docs/limits.md -->

## Test commands

$tests_body

## Review tools

    # optional — file globs mapped to review skills or linters, one per line, e.g.:
    # .rs   rust-best-practices

## Subagents

    # optional — specialists under agents/ that apply here, one per line, e.g.:
    # engineering-privacy-engineer

    # optional — a CONTEXT.md domain glossary, with a "flagged ambiguities"
    # section for words that meant two things and how that got resolved.
    # See docs/adding-a-project.md, "Optional: a domain glossary". Not
    # required — atk-lint never asks for one.

## Roles

developer reviewer maintainer

## Production boundary

$boundary_block
EOF
}

# The trunk init uses for $1: --trunk if given, else the branch HEAD is on,
# else main. One place, so `--propose` reports the value init would write.
init_trunk() {
  if [ -n "$INIT_TRUNK" ]; then printf '%s' "$INIT_TRUNK"; return 0; fi
  git -C "$1" symbolic-ref --short HEAD 2>/dev/null || printf 'main'
}

# True if AGENTS.md in $1 is part of the commit HEAD points at. An
# AGENTS.md that is on disk but not in HEAD was never committed — `--commit`
# commits it; one that is in HEAD but edited holds the user's edits and is
# left alone. Case-insensitive: on a case-insensitive file system (macOS,
# Windows) a committed `agents.md` *is* the AGENTS.md on disk, and committing
# the other spelling next to it would put two files into the history.
init_agents_md_in_head() {
  git -C "$1" ls-tree --name-only HEAD 2>/dev/null | grep -qixF 'AGENTS.md'
}

# Why AGENTS.md's index entry in $1 is one --commit must not touch, or
# nothing (rc 1) when it is ordinary: no entry, or one plain stage-0 entry.
# Unmerged (stage 1-3, several lines) and intent-to-add (`git add -N`) are
# states our add-then-restore cannot put back exactly, so they are refused
# before the index is touched. Intent-to-add is read from `status
# --porcelain=v2`, where such an entry is ".A" — the documented format, not
# the internal flag bit `ls-files --debug` prints.
init_agents_md_index_unusual() {
  local dir=$1 entries status
  entries=$(git -C "$dir" ls-files -s -- AGENTS.md 2>/dev/null)
  if [ "$(printf '%s\n' "$entries" | grep -c .)" -gt 1 ] \
     || printf '%s\n' "$entries" | grep -q "$(printf ' [1-3]\t')"; then
    printf 'unmerged — a conflict on AGENTS.md is unresolved'; return 0
  fi
  status=$(git -C "$dir" status --porcelain=v2 --untracked-files=no -- AGENTS.md 2>/dev/null)
  case "$status" in
    "1 .A "*) printf 'intent-to-add (git add -N)'; return 0 ;;
  esac
  return 1
}

# `--commit`: commit exactly AGENTS.md in $1, on whatever branch HEAD is on,
# so the worktrees created next already contain it. The pathspec after `--`
# makes it a `git commit --only`: whatever else the user has staged stays
# staged and out of this commit. Never pushes, never switches branches.
# Returns 0 when it committed, 1 when AGENTS.md is ignored by git here (left
# alone, not a refusal — the project chose not to track it).
# A refused commit (no identity, a pre-commit hook, ...) refuses step 1 —
# AGENTS.md stays written, and its index entry goes back to exactly what it
# was before our `git add`: the same staged blob, or no entry at all. Not
# `git reset`, which would restore HEAD's entry and so undo a deletion the
# user had staged.
init_commit_agents_md() {
  local dir=$1 err entry mode sha unusual
  if git -C "$dir" check-ignore -q -- AGENTS.md 2>/dev/null; then
    printf '  AGENTS.md is ignored by git here — not committed\n'
    return 1
  fi
  if unusual=$(init_agents_md_index_unusual "$dir"); then
    refuse_step 1 "AGENTS.md's index entry is $unusual — resolve it and run again; nothing was staged or committed"
  fi
  entry=$(git -C "$dir" ls-files -s -- AGENTS.md 2>/dev/null)
  if err=$(git -C "$dir" add -- AGENTS.md 2>&1) \
     && err=$(git -C "$dir" commit -q -m "Add AGENTS.md (atk init)" -- AGENTS.md 2>&1); then
    printf '  committed: AGENTS.md on %s\n' \
      "$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || printf 'a detached HEAD')"
    return 0
  fi
  if [ -n "$entry" ]; then
    # `ls-files -s` prints "<mode> <sha> <stage>\t<path>".
    mode=${entry%% *}; sha=${entry#* }; sha=${sha%% *}
    git -C "$dir" update-index --cacheinfo "$mode" "$sha" AGENTS.md >/dev/null 2>&1
  else
    git -C "$dir" rm -q --cached --ignore-unmatch -- AGENTS.md >/dev/null 2>&1
  fi
  refuse_step 1 "could not commit AGENTS.md (it is written, not committed): $(printf '%s' "$err" | grep -v '^[[:space:]]*$' | head -1)"
}

cmd_init() {
  init_parse_args "$@"
  local repo=$INIT_REPO
  [ -n "$repo" ] || { usage; exit 2; }
  local dir="$PROJECTS_DIR/$repo"
  [ -e "$dir/.git" ] || die "$dir is not a git repository"

  # --propose --json describes all four steps and changes nothing
  # (lib/init_propose.sh); it returns before any of them runs.
  if [ "$INIT_PROPOSE" -eq 1 ]; then init_propose "$repo" "$dir"; exit 0; fi

  # --yes is the flag-driven equivalent of ATK_YES: it answers the four
  # confirmations the same way, but — unlike the env var, which the
  # interactive path (and today's tests) already rely on — it also turns on
  # the boundary guard below. A `local` here is enough: ask() sees it through
  # bash's dynamic scoping without leaking back into the caller's shell.
  local ATK_YES=${ATK_YES:-}
  [ "$INIT_YES" -eq 1 ] && ATK_YES=1

  local did_something=0 committed=0 role

  # Whether any role worktree predates this run: those were made from an
  # older commit, so even a --commit leaves them needing a pull.
  local worktrees_before=0
  for role in developer reviewer maintainer; do
    [ -d "$dir/.worktrees/$repo-$role" ] && worktrees_before=1
  done

  local ver
  printf 'Checking what we need:\n'
  for bin in git gh tmux; do
    if command -v "$bin" >/dev/null 2>&1; then
      case "$bin" in
        tmux) ver=$(tmux -V 2>&1) ;;
        *)    ver=$("$bin" --version 2>&1 | head -1) ;;
      esac
      printf '  ok   %s (%s)\n' "$bin" "$ver"
    else
      printf '  MISSING %s — install it first\n' "$bin"
    fi
  done

  local trunk; trunk=$(init_trunk "$dir")
  local stack; stack=$(detect_stack "$dir")
  printf '\nProject: %s\n  trunk:  %s\n  stack:  %s\n' "$dir" "$trunk" "${stack:-unknown}"

  # --- AGENTS.md ------------------------------------------------------------
  if [ "$INIT_SKIP_AGENTS" -eq 1 ]; then
    printf '\n  skipped: AGENTS.md (--no-agents-md)\n'
  elif [ -f "$dir/AGENTS.md" ]; then
    printf '\n  %s already has an AGENTS.md — leaving it alone.\n' "$repo"
    printf '  Make sure it names: trunk, reviewer, test commands, production boundary.\n'
    # Never committed (a refused --commit earlier, or written by hand): the
    # same commit a freshly written one gets, so a retry finishes the job.
    if [ "$INIT_COMMIT" -eq 1 ] && ! init_agents_md_in_head "$dir"; then
      if init_commit_agents_md "$dir"; then committed=1; did_something=1; fi
    fi
  else
    # The one flag this whole feature exists to be careful with (issue #3,
    # "Careful with"): --boundary '' (deliberately none) and --boundary never
    # appearing at all are different things, and only init_parse_args() can
    # still tell them apart at this point — INIT_BOUNDARY alone can't, since
    # both leave it empty. Under --yes there is no human left to notice a
    # placeholder standing in for a boundary nobody chose, so a caller that
    # forgot the flag is refused here rather than getting a silent default.
    if [ "$INIT_YES" -eq 1 ] && [ "$INIT_BOUNDARY_GIVEN" -eq 0 ]; then
      refuse_step 1 "no --boundary given — pass one ('git push origin main:production', say) or --boundary '' for deliberately none"
    fi

    printf '\nProposed AGENTS.md:\n\n'
    local draft; draft=$(init_render_agents_md "$trunk" "$stack")
    printf '%s\n\n' "$draft"
    if [ "$(ask 'Write this file? (y/n)' y)" = "y" ]; then
      printf '%s\n' "$draft" > "$dir/AGENTS.md"
      printf '  written: %s/AGENTS.md — edit the production boundary before you rely on it.\n' "$dir"
      did_something=1
      if [ "$INIT_COMMIT" -eq 1 ] && init_commit_agents_md "$dir"; then committed=1; fi
    fi
  fi

  # --- labels ---------------------------------------------------------------
  if [ "$INIT_SKIP_LABELS" -eq 1 ]; then
    printf '\n  skipped: labels (--no-labels)\n'
  elif [ -z "${ATK_NO_NETWORK:-}" ] && [ "$(ask 'Create the three labels on the remote? (y/n)' y)" = "y" ]; then
    local label_out
    label_out=$(
      cd "$dir" || exit 1
      if gh label create ready --description "Ready for an agent to pick up" --color 0E8A16 2>/dev/null; then
        printf '  label created: ready\n'
      else
        printf '  label ready: already there, or no access\n'
      fi
      if gh label create needs-decision --description "Waiting on a human decision" --color D93F0B 2>/dev/null; then
        printf '  label created: needs-decision\n'
      else
        printf '  label needs-decision: already there, or no access\n'
      fi
      # Single-account mode has no reachable native approval -- a shared account
      # cannot `gh pr review --approve` its own PR -- so this label carries the
      # verdict instead. Measured: without it, `gh pr edit --add-label approved`
      # fails with "'approved' not found", which would break the default mode
      # silently on a fresh setup. Two-account mode never uses it; an unused
      # label costs nothing, a missing one costs the whole flow.
      if gh label create approved --description "Reviewed and approved (single-account mode)" --color 0052CC 2>/dev/null; then
        printf '  label created: approved\n'
      else
        printf '  label approved: already there, or no access\n'
      fi
    )
    printf '%s\n' "$label_out"
    case "$label_out" in *"label created:"*) did_something=1 ;; esac
  fi

  # --- production boundary -------------------------------------------------
  # Every other boundary here is a sentence in a Markdown file; this one is a
  # lock, since a release reaches real users and cannot be undone like a merge.
  if [ "$INIT_SKIP_ENVIRONMENT" -eq 1 ]; then
    printf '\n  skipped: production environment (--no-environment)\n'
  elif [ -z "${ATK_NO_NETWORK:-}" ]; then
    printf '\nThe production boundary needs a lock: a protected environment makes the\n'
    printf 'job wait for you in the browser, whoever triggered it.\n'
    if [ "$(ask 'Create or update a protected "production" environment? (y/n)' y)" = "y" ]; then
      local env_out
      env_out=$(
        cd "$dir" || exit 1
        uid=$(gh api user --jq .id 2>/dev/null) || exit 1
        slug=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || exit 1
        # gh api -X PUT on this endpoint creates OR updates — there is no
        # separate create call. Check first so the report below says which
        # one actually happened, instead of always claiming "created".
        existed=0
        gh api "repos/$slug/environments/production" >/dev/null 2>&1 && existed=1
        if printf '{"reviewers":[{"type":"User","id":%s}]}' "$uid" \
             | gh api -X PUT "repos/$slug/environments/production" --input - >/dev/null 2>&1; then
          if [ "$existed" -eq 1 ]; then
            printf '  environment updated: production already existed — you are now the required reviewer. GitHub does not document whether this preserves any other rules already on it; if it had any, verify with the command in docs/setup.md.\n'
          else
            printf '  environment created: production (you are the required reviewer)\n'
          fi
        else
          printf '  could not create or update the environment — create it by hand, see docs/setup.md\n'
        fi
      )
      printf '%s\n' "$env_out"
      case "$env_out" in *"environment created:"*|*"environment updated:"*) did_something=1 ;; esac
      printf '\n  One line is still yours to add, on the job that crosses the boundary:\n'
      printf '      jobs:\n        release:\n          environment: production\n'
      printf '  Without it the environment exists and protects nothing.\n'
    fi
  fi

  # --- worktrees ------------------------------------------------------------
  if [ "$INIT_SKIP_WORKTREES" -eq 1 ]; then
    printf '\n  skipped: worktrees (--no-worktrees)\n'
  elif [ "$(ask 'Create worktrees for the three roles? (y/n)' y)" = "y" ]; then
    for role in developer reviewer maintainer; do
      local wt_existed=0
      [ -d "$dir/.worktrees/$repo-$role" ] && wt_existed=1
      if ( export DRY_RUN=1; cmd_start "$repo" "$role" ) >/dev/null 2>&1; then
        printf '  worktree: %s-%s\n' "$repo" "$role"
        [ "$wt_existed" -eq 0 ] && did_something=1
      else
        printf '  could not create the %s worktree — run `atk %s %s` to see why\n' "$role" "$repo" "$role"
      fi
    done
  fi

  local first_step
  if [ -f "$dir/AGENTS.md" ]; then
    first_step="Edit $dir/AGENTS.md — above all the production boundary."
  else
    first_step="Create $dir/AGENTS.md — run this again, or copy one from examples/."
  fi

  # With --commit the commit-and-pull step already happened — but only if
  # every worktree was made after the commit; one from an earlier run still
  # needs the pull. Numbering follows.
  # What the worktrees pull: without --commit, the trunk the user is told
  # to commit on; with it, the branch the commit actually went onto — HEAD's,
  # which need not be the trunk — or, on a detached HEAD, the commit itself.
  local commit_step="" pulls src=$trunk
  if [ "$committed" -eq 1 ]; then
    src=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null) || src=$(git -C "$dir" rev-parse HEAD)
  fi
  pulls=$(cat <<EOF
       git -C $dir/.worktrees/$repo-developer  pull $dir $src
       git -C $dir/.worktrees/$repo-reviewer   pull $dir $src
       git -C $dir/.worktrees/$repo-maintainer pull $dir $src
EOF
)
  if [ "$committed" -eq 0 ]; then
    commit_step="Commit AGENTS.md, then update the worktrees just created — they were
     made from the commit before this one, so none of them can see it yet:
       git -C $dir add AGENTS.md && git -C $dir commit -m \"add AGENTS.md\"
$pulls"
  elif [ "$worktrees_before" -eq 1 ]; then
    commit_step="Update the worktrees that existed before this run — they were made
     from an older commit and cannot see the AGENTS.md just committed:
$pulls"
  fi

  printf '\nDone. Next:\n'
  local n=0 step
  for step in \
    "$first_step" \
    "$commit_step" \
    "Put the reviewer account's login in AGENTS.md — without it the reviewer
     cannot be asked for a review. See docs/setup.md." \
    "Give the reviewer its own account: docs/setup.md" \
    "Put 'ready' on an issue:   gh issue edit <N> --add-label ready" \
    "Start your coding agent once in $dir and confirm it may trust the folder —
     the role worktrees inherit that; an unanswered prompt stalls a session
     silently. See docs/limits.md." \
    "Start working:             atk $repo developer"
  do
    [ -n "$step" ] || continue
    n=$((n + 1))
    printf '  %d. %s\n' "$n" "$step"
  done

  [ "$did_something" -eq 1 ] && exit 0
  exit 3
}
