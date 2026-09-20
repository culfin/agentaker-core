#!/usr/bin/env bash
# `wtc list`, `wtc drop` and `wtc restart` — seeing what worktrees exist,
# cleaning up after them, and replacing the process behind one without
# losing where it had got to.
#
# Sourced by bin/wtc on demand, for the same reason as lib/init.sh: the
# everyday `wtc <repo> <role>` path doesn't pay to parse any of this.
#
# Needs from bin/wtc: die(), usage(), role_tag(), session_name(),
#   build_context(), launch_command(), wrap_launch_command(),
#   read_reviewer_token(), PROJECTS_DIR, ROLES_DIR, TOOL
# Provides to it:     nothing — cmd_list()/cmd_drop()/cmd_restart() are the
#   whole surface.

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

# --- restart --------------------------------------------------------------
# wtc never learns anything about the coding agent it restarts: it sends
# keystrokes and waits for a file. What belongs in that file is stated in
# roles/_base.md, which every tool reads — see "## Handing over" there.
HANDOVER_PROMPT='Please hand over now: write .agents/handoff.md as described in your instructions, then exit.'

# Sends the handover request into pane $1 ("session:window"), clearing any
# input already sitting in the buffer first. Measured: without the C-u, a
# half-typed line waiting in the pane gets the handover phrase appended onto
# it instead of arriving as its own line — a substring match can survive
# that by luck, but a real coding agent reading the line as a whole command
# should not have to depend on luck.
request_handover() {
  tmux send-keys -t "$1" C-u
  tmux send-keys -t "$1" "$HANDOVER_PROMPT" Enter
}

# Polls for file $1 to exist and be non-empty, up to $2 seconds. rc 0 if it
# showed up in time. Whole-second polling: the timeout is a safety margin
# measured in tens of seconds (default 60), not a latency budget.
wait_for_handoff() {
  local file=$1 timeout=$2 waited=0
  while [ "$waited" -lt "$timeout" ]; do
    [ -s "$file" ] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  [ -s "$file" ]
}

# Replaces the running process behind $repo's $label window (worktree $wt,
# role $role) with a fresh one. Unless $fresh is 1, asks first and carries
# the answer forward to the successor. Prints its own report lines as each
# step happens; returns 1 on anything that stops it short of a restart
# (missing window, a timeout, a role file that no longer assembles) and
# leaves the running session exactly as found — restart never half-applies.
restart_window() {
  local repo=$1 wt=$2 role=$3 label=$4 fresh=$5
  local target; target="$(session_name "$repo"):$label"

  worktree_running "$repo" "$label" || {
    printf 'wtc: no running session for %s in %s — see `wtc list %s`\n' "$label" "$repo" "$repo" >&2
    return 1
  }

  local handoff="$wt/.agents/handoff.md"

  if [ "$fresh" -eq 1 ]; then
    printf 'restarting %s in %s without a handover (--fresh)\n' "$label" "$repo"
  else
    rm -f "$handoff"
    # Window-scoped, and turned off again below on every exit path: without
    # it, a session whose only window is this one is destroyed by tmux the
    # instant the coding agent exits after writing the handoff — before this
    # command ever gets to respawn-pane. Measured against a stand-in: the
    # window (not just the handoff) was lost outright, in exactly the
    # single-window case a restart is most likely to be used on.
    tmux set-window-option -t "$target" remain-on-exit on 2>/dev/null
    printf 'asking %s in %s to hand over\n' "$label" "$repo"
    request_handover "$target"
    if ! wait_for_handoff "$handoff" "${WTC_HANDOFF_TIMEOUT:-60}"; then
      tmux set-window-option -t "$target" remain-on-exit off 2>/dev/null
      printf 'wtc: %s in %s did not hand over within %ss — its state would be lost, so nothing was restarted.\n' \
        "$label" "$repo" "${WTC_HANDOFF_TIMEOUT:-60}" >&2
      printf 'wtc: to replace it anyway, losing its state: wtc restart %s %s --fresh\n' "$repo" "$label" >&2
      return 1
    fi
    printf 'received a handover from %s in %s\n' "$label" "$repo"
  fi

  build_context "$wt" "$role" || {
    tmux set-window-option -t "$target" remain-on-exit off 2>/dev/null
    printf 'wtc: could not assemble the role context from %s\n' "$ROLES_DIR" >&2
    return 1
  }
  if [ "$fresh" -ne 1 ] && [ -s "$handoff" ]; then
    {
      printf '\n\n## Handover from your predecessor\n\n'
      cat "$handoff"
    } >> "$wt/.agents/context.md"
  fi

  LAUNCH_CMD=()
  if ! launch_command "$wt/.agents/context.md"; then
    tmux set-window-option -t "$target" remain-on-exit off 2>/dev/null
    printf 'wtc: no launch command known for tool %s\n' "${TOOL:-claude}" >&2
    return 1
  fi

  local token=""
  [ "$role" = "reviewer" ] && { token=$(read_reviewer_token) || token=""; }

  wrap_launch_command "$role" "${LAUNCH_CMD[@]}"
  local respawn_rc
  if [ -n "$token" ]; then
    tmux respawn-pane -k -t "$target" -c "$wt" -e "GH_TOKEN=$token" "${LAUNCH_CMD[@]}"
    respawn_rc=$?
  else
    tmux respawn-pane -k -t "$target" -c "$wt" "${LAUNCH_CMD[@]}"
    respawn_rc=$?
  fi
  tmux set-window-option -t "$target" remain-on-exit off 2>/dev/null

  if [ "$respawn_rc" -ne 0 ]; then
    printf 'wtc: tmux would not respawn %s in %s — see \`tmux respawn-pane -t %s\` for why\n' \
      "$label" "$repo" "$target" >&2
    return 1
  fi
  printf 'restarted %s in %s\n' "$label" "$repo"
}

# `wtc restart --all`: every currently running window, across every project
# under PROJECTS_DIR. A dirty worktree is skipped, never forced through —
# same discipline as cmd_drop(): uncommitted changes are a signal this isn't
# a good moment, and --all has no human in the loop to ask.
restart_all() {
  local restarted=0 skipped=0 repo_dir repo wt dirty

  for repo_dir in "$PROJECTS_DIR"/*/; do
    [ -e "$repo_dir" ] || continue
    repo_dir=${repo_dir%/}
    repo=$(basename "$repo_dir")
    [ -d "$repo_dir/.worktrees" ] || continue

    for wt in "$repo_dir"/.worktrees/*/; do
      [ -e "$wt" ] || continue
      wt=${wt%/}
      describe_worktree "$repo" "$(basename "$wt")"
      worktree_running "$repo" "$WT_LABEL" || continue

      dirty=$(git -C "$wt" status --porcelain 2>/dev/null)
      if [ -n "$dirty" ]; then
        printf 'skipping %s in %s — uncommitted changes, commit or discard them first\n' "$WT_LABEL" "$repo"
        skipped=$((skipped + 1))
        continue
      fi

      if restart_window "$repo" "$wt" "$WT_ROLE" "$WT_LABEL" 0; then
        restarted=$((restarted + 1))
      else
        skipped=$((skipped + 1))
      fi
    done
  done

  printf '\nrestarted %d, skipped %d\n' "$restarted" "$skipped"
  [ "$skipped" -eq 0 ]
}

cmd_restart() {
  if [ "${1:-}" = "--all" ]; then
    restart_all
    return $?
  fi

  local fresh=0 args=() a
  for a in "$@"; do
    if [ "$a" = "--fresh" ]; then fresh=1; else args+=("$a"); fi
  done
  local repo=${args[0]:-} label=${args[1]:-}
  [ -n "$repo" ] && [ -n "$label" ] || { usage; exit 2; }

  local repo_dir="$PROJECTS_DIR/$repo"
  [ -e "$repo_dir/.git" ] || die "$repo_dir is not a git repository"

  # Same resolution cmd_drop() uses, and for the same reason: the directory
  # name always wins outright if it matches (the filesystem guarantees it's
  # unique), otherwise a label match must be unique — two honest worktrees
  # can share one (role_tag() abbreviates an unrecognised role to its first
  # three letters). See cmd_drop() for the full reasoning.
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
    {
      printf 'wtc: "%s" matches more than one worktree in %s:\n\n' "$label" "$repo"
      for wt in "${candidates[@]}"; do
        describe_worktree "$repo" "$(basename "$wt")"
        printf '  %-5s %-24s %s\n' "$WT_LABEL" "$(basename "$wt")" "$WT_BRANCH"
      done
      printf '\nUse the directory name to say which one:\n  wtc restart %s %s\n' \
        "$repo" "$(basename "${candidates[0]}")"
    } >&2
    exit 1
  fi
  describe_worktree "$repo" "$(basename "$match")"

  restart_window "$repo" "$match" "$WT_ROLE" "$WT_LABEL" "$fresh"
  exit $?
}
