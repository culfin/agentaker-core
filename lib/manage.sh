#!/usr/bin/env bash
# `wtc list` and `wtc drop` — seeing what worktrees exist, and cleaning up
# after them.
#
# Sourced by bin/wtc on demand, for the same reason as lib/init.sh: cleanup
# doesn't run on the everyday `wtc <repo> <role>` path, so that path doesn't
# pay to parse it.
#
# Needs from bin/wtc: die(), usage(), role_tag(), session_name(), PROJECTS_DIR
# Provides to it:     nothing — cmd_list()/cmd_drop() are the whole surface.

# Sets WT_ROLE, WT_LABEL, WT_BRANCH for the worktree named $2 (its directory
# basename under .worktrees/) belonging to repo $1. A worktree wtc didn't
# create — no .agents/ROLE, or a name that doesn't fit the repo-role[-suffix]
# pattern cmd_start() uses — still gets a label; role_tag() falls back to
# uppercasing whatever it's given, so it never comes back empty.
describe_worktree() {
  local repo=$1 base=$2 wt="$PROJECTS_DIR/$1/.worktrees/$2"
  WT_ROLE=$(cat "$wt/.agents/ROLE" 2>/dev/null || true)
  local tag; tag=$(role_tag "${WT_ROLE:-$base}")
  local prefix="$repo-${WT_ROLE:-}" suffix=""
  if [ -n "$WT_ROLE" ] && [ "${base#"$prefix"}" != "$base" ]; then
    suffix=${base#"$prefix"}
    suffix=${suffix#-}
  fi
  WT_LABEL=$tag
  # Braced ("${tag}·${suffix}"), not "$tag·$suffix" — see the matching
  # comment in bin/wtc's cmd_start(): under a UTF-8 locale, bash can fold the
  # multibyte "·" right after an unbraced $tag into the variable name itself.
  [ -n "$suffix" ] && WT_LABEL="${tag}·${suffix}"
  WT_BRANCH=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null \
    || git -C "$wt" rev-parse --short HEAD 2>/dev/null \
    || printf '?')
}

# True (rc 0) if repo $1's tmux session has a window named $2 open right now.
worktree_running() {
  local session; session=$(session_name "$1")
  tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -qxF "$2"
}

cmd_list() {
  local want_size="" only_repo="" arg
  for arg in "$@"; do
    case "$arg" in
      --size) want_size=1 ;;
      *)      only_repo=$arg ;;
    esac
  done
  if [ -n "$only_repo" ]; then
    [ -e "$PROJECTS_DIR/$only_repo/.git" ] || die "$PROJECTS_DIR/$only_repo is not a git repository"
  fi

  local repo_dir any=""
  for repo_dir in "$PROJECTS_DIR"/*/; do
    [ -e "$repo_dir" ] || continue
    repo_dir=${repo_dir%/}
    local repo; repo=$(basename "$repo_dir")
    [ -n "$only_repo" ] && [ "$repo" != "$only_repo" ] && continue
    [ -d "$repo_dir/.worktrees" ] || continue

    local shown="" wt
    for wt in "$repo_dir"/.worktrees/*/; do
      [ -e "$wt" ] || continue
      wt=${wt%/}
      [ -z "$shown" ] && { printf '%s\n' "$repo"; shown=1; any=1; }

      describe_worktree "$repo" "$(basename "$wt")"
      local running="—"
      worktree_running "$repo" "$WT_LABEL" && running="running"
      local size="—"
      [ -n "$want_size" ] && size=$(du -sh "$wt" 2>/dev/null | awk '{print $1}')
      # The directory name, always — two worktrees can share a label
      # (role_tag() falls back to the first three letters of an unknown role,
      # so "devops" and "developer" both read DEV); a user reading this list
      # has to be able to build a `wtc drop` command that means what they
      # think, and the label alone can't promise that. See cmd_drop()'s own
      # ambiguity handling for the other half of this.
      printf '  %-16s %-24s %-22s %6s   %s\n' "$WT_LABEL" "$(basename "$wt")" "$WT_BRANCH" "$size" "$running"
    done
  done

  if [ -z "$any" ]; then
    if [ -n "$only_repo" ]; then
      printf 'no worktrees under %s/%s\n' "$PROJECTS_DIR" "$only_repo"
    else
      printf 'no worktrees under %s\n' "$PROJECTS_DIR"
    fi
  elif [ -z "$want_size" ]; then
    printf '\n(sizes omitted — du is slow on a large tree; add --size to include them)\n'
  fi
}

cmd_drop() {
  local force=0 args=() a
  for a in "$@"; do
    if [ "$a" = "--force" ]; then force=1; else args+=("$a"); fi
  done
  local repo=${args[0]:-} label=${args[1]:-}
  [ -n "$repo" ] && [ -n "$label" ] || { usage; exit 2; }

  local repo_dir="$PROJECTS_DIR/$repo"
  [ -e "$repo_dir/.git" ] || die "$repo_dir is not a git repository"

  # Resolve the target by asking git/the filesystem what actually exists —
  # never build a path from $label itself. A tool that deletes the wrong
  # directory because a name contained something unexpected is the worst bug
  # this project could ship.
  #
  # Two honest worktrees can share a label: role_tag() abbreviates an
  # unrecognised role to its first three letters, so "devops" and
  # "developer" both read DEV, and which directory a first-match loop would
  # have picked depended on glob order — which is locale-dependent (measured:
  # LC_ALL=de_DE.UTF-8 and LC_ALL=C sorted `demo-developer` and
  # `demo-devops` differently on this same machine). So: collect every
  # candidate, not just the first. The directory name is always unique
  # (the filesystem guarantees it), so it's checked first and, if it
  # matches, wins outright — no ambiguity possible from it.
  local match="" wt base
  local dirname_match="" candidates=()
  for wt in "$repo_dir"/.worktrees/*/; do
    [ -e "$wt" ] || continue
    wt=${wt%/}
    base=$(basename "$wt")
    [ "$base" = "$label" ] && dirname_match=$wt
    describe_worktree "$repo" "$base"
    [ "$WT_LABEL" = "$label" ] && candidates+=("$wt")
  done

  if [ -n "$dirname_match" ]; then
    match=$dirname_match
  elif [ "${#candidates[@]}" -eq 1 ]; then
    match=${candidates[0]}
  elif [ "${#candidates[@]}" -eq 0 ]; then
    die "no worktree named '$label' in $repo — see \`wtc list $repo\`"
  else
    # More than one candidate. This refuses unconditionally — before the
    # --force check below, and not reachable through it — because --force
    # exists to override what a worktree CONTAINS (uncommitted changes,
    # unpushed commits, an open window), never to proceed without knowing
    # WHICH worktree it's about to remove.
    {
      printf 'wtc: "%s" matches more than one worktree in %s:\n\n' "$label" "$repo"
      for wt in "${candidates[@]}"; do
        describe_worktree "$repo" "$(basename "$wt")"
        printf '  %-5s %-24s %s\n' "$WT_LABEL" "$(basename "$wt")" "$WT_BRANCH"
      done
      printf '\nUse the directory name to say which one:\n  wtc drop %s %s\n' \
        "$repo" "$(basename "${candidates[0]}")"
    } >&2
    exit 1
  fi
  describe_worktree "$repo" "$(basename "$match")"

  if [ "$force" -ne 1 ]; then
    local dirty; dirty=$(git -C "$match" status --porcelain 2>/dev/null)
    if [ -n "$dirty" ]; then
      local n; n=$(printf '%s\n' "$dirty" | grep -c .)
      die "$label has $n uncommitted file(s) — commit or discard them, or pass --force"
    fi

    local unpushed; unpushed=$(git -C "$match" log --branches --not --remotes --oneline 2>/dev/null)
    if [ -n "$unpushed" ]; then
      local n; n=$(printf '%s\n' "$unpushed" | grep -c .)
      die "$label has $n commit(s) on $WT_BRANCH not on any remote — push them, or pass --force"
    fi

    # WT_LABEL, not $label: a tmux window is named after the label
    # cmd_start() gave it, which is what the user typed only when they
    # typed the label — if they typed the directory name instead, $label
    # would never match a real window and this check would silently miss.
    if worktree_running "$repo" "$WT_LABEL"; then
      die "$label has a tmux window open in session $(session_name "$repo") — close it first, or pass --force"
    fi
  fi

  local size; size=$(du -sh "$match" 2>/dev/null | awk '{print $1}')

  # git worktree remove is what knows what git needs cleaned up (the
  # administrative files under .git/worktrees, not just $match itself) — an
  # rm -rf here would leave that behind and could take the wrong directory
  # with it if anything about $match were ever wrong.
  local git_force=""
  [ "$force" -eq 1 ] && git_force="--force"
  git -C "$repo_dir" worktree remove $git_force "$match" \
    || die "git would not remove $match — see \`git -C $repo_dir worktree list\` for why"

  if worktree_running "$repo" "$WT_LABEL"; then
    tmux kill-window -t "$(session_name "$repo"):$WT_LABEL" 2>/dev/null
  fi

  printf 'removed %s (%s) — freed %s\n' "$label" "$match" "${size:-an unknown amount}"
}
