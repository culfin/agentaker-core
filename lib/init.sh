#!/usr/bin/env bash
# The `wtc init` subcommand and its helpers.
#
# Sourced by bin/wtc on demand rather than always: init runs once per project
# and never during normal work, so the three everyday subcommands do not pay to
# parse it.
#
# Needs from bin/wtc:  die(), usage(), cmd_start(), PROJECTS_DIR
# Provides to it:      DRY_RUN, set for the subshell that creates the worktrees
#                      so cmd_start() prepares them without launching anything
#
# ROLES_DIR is deliberately absent: cmd_start() reads it, and cmd_start() stays
# in bin/wtc where it is already in scope.

# `wtc init` shows every step instead of hiding it: each action is proposed and
# confirmed separately, so someone who watched it run can redo it by hand.

ask() {
  # Prompt unless WTC_YES is set; echo the (possibly default) answer.
  local prompt=$1 default=${2:-y} reply
  if [ -n "${WTC_YES:-}" ]; then printf '%s' "$default"; return 0; fi
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
  local repo=${1:-}
  [ -n "$repo" ] || { usage; exit 2; }
  local dir="$PROJECTS_DIR/$repo"
  [ -e "$dir/.git" ] || die "$dir is not a git repository"

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
  local stack; stack=$(detect_stack "$dir")
  printf '\nProject: %s\n  trunk:  %s\n  stack:  %s\n' "$dir" "$trunk" "${stack:-unknown}"

  # --- AGENTS.md ------------------------------------------------------------
  if [ -f "$dir/AGENTS.md" ]; then
    printf '\n  %s already has an AGENTS.md — leaving it alone.\n' "$repo"
    printf '  Make sure it names: trunk, reviewer, test commands, production boundary.\n'
  else
    printf '\nProposed AGENTS.md:\n\n'
    local draft; draft=$(cat <<EOF
# Agents in this project

trunk: $trunk
reviewer:            # GitHub login of the account that reviews here — see docs/setup.md

## Test commands

$(suggest_tests "$stack")

## Production boundary

The one line an agent must never cross on its own. Examples:

    git push origin main:production
    npm publish

Replace this with yours. Until you do, agents will refuse to release.

## Roles

developer reviewer integrator
EOF
)
    printf '%s\n\n' "$draft"
    if [ "$(ask 'Write this file? (y/n)' y)" = "y" ]; then
      printf '%s\n' "$draft" > "$dir/AGENTS.md"
      printf '  written: %s/AGENTS.md — edit the production boundary before you rely on it.\n' "$dir"
    fi
  fi

  # --- labels ---------------------------------------------------------------
  if [ -z "${WTC_NO_NETWORK:-}" ] && [ "$(ask 'Create the two labels on the remote? (y/n)' y)" = "y" ]; then
    (
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
    )
  fi

  # --- production boundary -------------------------------------------------
  # Every other boundary here is a sentence in a Markdown file; this one is a
  # lock, since a release reaches real users and cannot be undone like a merge.
  if [ -z "${WTC_NO_NETWORK:-}" ]; then
    printf '\nThe production boundary needs a lock: a protected environment makes the\n'
    printf 'job wait for you in the browser, whoever triggered it.\n'
    if [ "$(ask 'Create a protected "production" environment? (y/n)' y)" = "y" ]; then
      (
        cd "$dir" || exit 1
        uid=$(gh api user --jq .id 2>/dev/null) || exit 1
        slug=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || exit 1
        if printf '{"reviewers":[{"type":"User","id":%s}]}' "$uid" \
             | gh api -X PUT "repos/$slug/environments/production" --input - >/dev/null 2>&1; then
          printf '  environment created: production (you are the required reviewer)\n'
        else
          printf '  could not create the environment — create it by hand, see docs/setup.md\n'
        fi
      )
      printf '\n  One line is still yours to add, on the job that crosses the boundary:\n'
      printf '      jobs:\n        release:\n          environment: production\n'
      printf '  Without it the environment exists and protects nothing.\n'
    fi
  fi

  # --- worktrees ------------------------------------------------------------
  if [ "$(ask 'Create worktrees for the three roles? (y/n)' y)" = "y" ]; then
    for role in developer reviewer integrator; do
      if ( export DRY_RUN=1; cmd_start "$repo" "$role" ) >/dev/null 2>&1; then
        printf '  worktree: %s-%s\n' "$repo" "$role"
      else
        printf '  could not create the %s worktree — run `wtc %s %s` to see why\n' "$role" "$repo" "$role"
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
  2. Put the reviewer account's login in AGENTS.md — without it the reviewer
     cannot be asked for a review. See docs/setup.md.
  3. Give the reviewer its own account: docs/setup.md
  4. Put 'ready' on an issue:   gh issue edit <N> --add-label ready
  5. Start working:             wtc $repo developer
EOF
}
