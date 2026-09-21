#!/usr/bin/env bash
# The `tender init` subcommand and its helpers.
#
# Sourced by bin/tender on demand rather than always: init runs once per project
# and never during normal work, so the three everyday subcommands do not pay to
# parse it.
#
# Needs from bin/tender:  die(), usage(), cmd_start(), PROJECTS_DIR
# Provides to it:      DRY_RUN, set for the subshell that creates the worktrees
#                      so cmd_start() prepares them without launching anything
#
# ROLES_DIR is deliberately absent: cmd_start() reads it, and cmd_start() stays
# in bin/tender where it is already in scope.
#
# lib/init_flags.sh, sourced by bin/tender immediately before this file, holds
# argument parsing, --help text and the exit-code contract (issue #3) — see
# its own header. This file stays about what the four steps actually do;
# that one is about how a caller (interactive or a flag-driven GUI) reaches
# them.

# `tender init` shows every step instead of hiding it: each action is proposed and
# confirmed separately, so someone who watched it run can redo it by hand.

ask() {
  # Prompt unless TENDER_YES is set; echo the (possibly default) answer.
  local prompt=$1 default=${2:-y} reply
  if [ -n "${TENDER_YES:-}" ]; then printf '%s' "$default"; return 0; fi
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

cmd_init() {
  init_parse_args "$@"
  local repo=$INIT_REPO
  [ -n "$repo" ] || { usage; exit 2; }
  local dir="$PROJECTS_DIR/$repo"
  [ -e "$dir/.git" ] || die "$dir is not a git repository"

  # --yes is the flag-driven equivalent of TENDER_YES: it answers the four
  # confirmations the same way, but — unlike the env var, which the
  # interactive path (and today's tests) already rely on — it also turns on
  # the boundary guard below. A `local` here is enough: ask() sees it through
  # bash's dynamic scoping without leaking back into the caller's shell.
  local TENDER_YES=${TENDER_YES:-}
  [ "$INIT_YES" -eq 1 ] && TENDER_YES=1

  local did_something=0

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

  local trunk; trunk=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo main)
  [ -n "$INIT_TRUNK" ] && trunk=$INIT_TRUNK
  local stack; stack=$(detect_stack "$dir")
  printf '\nProject: %s\n  trunk:  %s\n  stack:  %s\n' "$dir" "$trunk" "${stack:-unknown}"

  # --- AGENTS.md ------------------------------------------------------------
  if [ "$INIT_SKIP_AGENTS" -eq 1 ]; then
    printf '\n  skipped: AGENTS.md (--no-agents-md)\n'
  elif [ -f "$dir/AGENTS.md" ]; then
    printf '\n  %s already has an AGENTS.md — leaving it alone.\n' "$repo"
    printf '  Make sure it names: trunk, reviewer, test commands, production boundary.\n'
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

    printf '\nProposed AGENTS.md:\n\n'
    local draft; draft=$(cat <<EOF
# Agents in this project

trunk: $trunk
$reviewer_line
claim-timeout-days: 2  # days before an unreleased claim counts as orphaned and may be taken over — see docs/limits.md

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
    # required — tender-lint never asks for one.

## Roles

developer reviewer maintainer

## Production boundary

$boundary_block
EOF
)
    printf '%s\n\n' "$draft"
    if [ "$(ask 'Write this file? (y/n)' y)" = "y" ]; then
      printf '%s\n' "$draft" > "$dir/AGENTS.md"
      printf '  written: %s/AGENTS.md — edit the production boundary before you rely on it.\n' "$dir"
      did_something=1
    fi
  fi

  # --- labels ---------------------------------------------------------------
  if [ "$INIT_SKIP_LABELS" -eq 1 ]; then
    printf '\n  skipped: labels (--no-labels)\n'
  elif [ -z "${TENDER_NO_NETWORK:-}" ] && [ "$(ask 'Create the three labels on the remote? (y/n)' y)" = "y" ]; then
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
  elif [ -z "${TENDER_NO_NETWORK:-}" ]; then
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
        printf '  could not create the %s worktree — run `tender %s %s` to see why\n' "$role" "$repo" "$role"
      fi
    done
  fi

  local first_step
  if [ -f "$dir/AGENTS.md" ]; then
    first_step="Edit $dir/AGENTS.md — above all the production boundary."
  else
    first_step="Create $dir/AGENTS.md — run this again, or copy one from examples/."
  fi

  cat <<EOF

Done. Next:
  1. $first_step
  2. Commit AGENTS.md, then update the worktrees just created — they were
     made from the commit before this one, so none of them can see it yet:
       git -C $dir add AGENTS.md && git -C $dir commit -m "add AGENTS.md"
       git -C $dir/.worktrees/$repo-developer  pull $dir $trunk
       git -C $dir/.worktrees/$repo-reviewer   pull $dir $trunk
       git -C $dir/.worktrees/$repo-maintainer pull $dir $trunk
  3. Put the reviewer account's login in AGENTS.md — without it the reviewer
     cannot be asked for a review. See docs/setup.md.
  4. Give the reviewer its own account: docs/setup.md
  5. Put 'ready' on an issue:   gh issue edit <N> --add-label ready
  6. Start working:             tender $repo developer
EOF

  [ "$did_something" -eq 1 ] && exit 0
  exit 3
}
