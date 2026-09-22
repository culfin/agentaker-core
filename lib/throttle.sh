#!/usr/bin/env bash
# Agent pull requests, counted and — where a project asks for it — capped
# (issue #1). Renovate's `prConcurrentLimit` is the precedent: unbounded
# automation does not overwhelm the machine, it overwhelms the human who has
# to read what it produced.
#
# An agent PR of repo <repo> is an open pull request whose head branch is the
# branch `cmd_start()` gives a developer worktree: `<repo>-developer`, or
# `<repo>-developer-<suffix>`. Drafts count — in single-account mode a draft
# is exactly what is waiting for the human.
#
# `max-open-prs: N` in the project's AGENTS.md sets the cap. Absent means no
# cap and nothing changes anywhere; present but not a positive integer is
# reported (`tender status`) and treated as no cap — never as 0, which would
# stop every developer on a typo.
#
# Sourced by bin/tender unconditionally: `cmd_start()` asks it on every
# developer start, `cmd_status()` on every board. Both ask `gh` only when the
# answer can change something.
#
# Needs from bin/tender: PROJECTS_DIR, STATUS_FAILED, role_tag() (lib/tabs.sh),
#   session_name()
# Provides to it:     throttle_start_check(), throttle_status_section()

# max-open-prs from $1/AGENTS.md, first matching line — the same file and
# the same "first line wins" reading as claim-timeout-days (lib/claims.sh),
# but strict: a comment after the value is allowed, anything else in it is
# not. Prints the raw value; rc 0 valid, 1 absent, 2 present but invalid.
throttle_cap() {
  local line value
  line=$(grep -m1 '^max-open-prs:' "$1/AGENTS.md" 2>/dev/null) || return 1
  value=${line#max-open-prs:}
  value=${value%%#*}
  value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  printf '%s' "$value"
  # 0-leading is refused too: bash arithmetic would read 08 as a bad octal.
  case $value in ''|0*|*[!0-9]*) return 2 ;; esac
  return 0
}

# Counts repo $2's open agent PRs by asking `gh` from inside its checkout $1.
# Sets THROTTLE_COUNT and THROTTLE_OLDEST (createdAt of the oldest, ISO-8601
# UTC). rc 1 means "could not ask" — gh missing, offline, no remote — with the
# reason in THROTTLE_ERROR; that must never read as zero, the same three-way
# discipline as status_query() in bin/tender.
#
# The branch filter runs here rather than in --jq so the rule is plain shell:
# exact name or name plus "-suffix". A prefix match alone would count
# `acme-developerx`, and a branch of a repo named `acme-web` never matches
# `acme-developer…` at all.
throttle_count() {
  local repo_dir=$1 repo=$2 out rc branch created
  THROTTLE_COUNT=0 THROTTLE_OLDEST="" THROTTLE_ERROR=""
  if ! command -v gh >/dev/null 2>&1; then
    THROTTLE_ERROR="gh is not installed"
    return 1
  fi
  out=$(cd "$repo_dir" && gh pr list --state open --json headRefName,createdAt --limit 200 \
        --jq '.[] | "\(.headRefName) \(.createdAt)"' 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    THROTTLE_ERROR=$(printf '%s' "$out" | head -1)
    THROTTLE_ERROR=${THROTTLE_ERROR:-gh exited $rc}
    return 1
  fi
  while read -r branch created; do
    case $branch in
      "$repo-developer"|"$repo-developer-"?*) ;;
      *) continue ;;
    esac
    THROTTLE_COUNT=$((THROTTLE_COUNT + 1))
    if [ -z "$THROTTLE_OLDEST" ] || [ "$created" \< "$THROTTLE_OLDEST" ]; then
      THROTTLE_OLDEST=$created
    fi
  done <<THROTTLEOUT
$out
THROTTLEOUT
  return 0
}

# How long ago ISO-8601 UTC timestamp $1 was, as 12m / 5h / 2d — or "?" if
# neither GNU nor BSD date can read it.
throttle_age() {
  local epoch diff
  epoch=$(date -u -d "$1" +%s 2>/dev/null \
          || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null) || { printf '?'; return; }
  diff=$(( $(date -u +%s) - epoch ))
  if [ "$diff" -lt 3600 ]; then printf '%dm' "$((diff / 60))"
  elif [ "$diff" -lt 86400 ]; then printf '%dh' "$((diff / 3600))"
  else printf '%dd' "$((diff / 86400))"
  fi
}

# True (rc 0) if a developer session of repo $1 other than the one being
# started (suffix $2) has a window open right now. Walks the developer
# worktrees (the names cmd_start() gives them) rather than matching every
# "DEV…" window: role_tag() abbreviates an unknown role like `devops` to DEV
# too. `=` makes tmux match the session
# name exactly — without it, `tender-acme` also finds `tender-acme-web`.
throttle_other_developer_running() {
  local repo=$1 suffix=$2 windows tag own wt s label
  command -v tmux >/dev/null 2>&1 || return 1
  windows=$(tmux list-windows -t "=$(session_name "$repo")" -F '#{window_name}' 2>/dev/null) || return 1
  tag=$(role_tag developer)
  own=$tag
  [ -n "$suffix" ] && own="${tag}·${suffix}"
  for wt in "$PROJECTS_DIR/$repo/.worktrees/$repo-developer" \
            "$PROJECTS_DIR/$repo/.worktrees/$repo-developer-"*; do
    [ -d "$wt" ] || continue
    s=${wt##*/}
    s=${s#"$repo-developer"}
    s=${s#-}
    label=$tag
    # Braced — see the matching comment in bin/tender's cmd_start().
    [ -n "$s" ] && label="${tag}·${s}"
    [ "$label" = "$own" ] && continue
    printf '%s\n' "$windows" | grep -qxF "$label" && return 0
  done
  return 1
}

# The start refusal. rc 1 — with the reason already printed — only when all
# three hold: a valid cap is set, another developer session of this repo is
# running, and the open agent PRs are at or above the cap. The first developer
# session is always allowed: it is the one that works off review feedback, and
# refusing it would leave a full queue with nobody to empty it. Could not
# count → start anyway, and say so.
throttle_start_check() {
  local repo=$1 suffix=$2 repo_dir="$PROJECTS_DIR/$1" cap
  cap=$(throttle_cap "$repo_dir") || return 0
  throttle_other_developer_running "$repo" "$suffix" || return 0
  if ! throttle_count "$repo_dir" "$repo"; then
    printf 'tender: could not count open agent PRs (%s) — starting anyway, max-open-prs: %s unchecked\n' \
      "$THROTTLE_ERROR" "$cap" >&2
    return 0
  fi
  [ "$THROTTLE_COUNT" -lt "$cap" ] && return 0
  printf 'tender: %s has %s agent PRs open, at its cap (max-open-prs: %s in AGENTS.md), and a developer session is already running — not starting another. Review the open PRs first; see docs/limits.md\n' \
    "$repo" "$THROTTLE_COUNT" "$cap" >&2
  return 1
}

# One line per set-up project (a git checkout with AGENTS.md) that has agent
# PRs open, could not be asked, or carries an invalid cap. A could-not-ask
# sets STATUS_FAILED, like every other section of the board. No set-up
# project under PROJECTS_DIR means no question was asked, so no section —
# "(none)" is kept for "asked, and there are none".
throttle_status_section() {
  local repo_dir repo cap cap_rc note any=0 asked=0
  for repo_dir in "$PROJECTS_DIR"/*/; do
    repo_dir=${repo_dir%/}
    [ -e "$repo_dir/.git" ] && [ -f "$repo_dir/AGENTS.md" ] || continue
    [ "$asked" -eq 1 ] || printf 'agent PRs open:\n'
    asked=1
    repo=${repo_dir##*/}
    cap=$(throttle_cap "$repo_dir")
    cap_rc=$?
    note=""
    [ "$cap_rc" -eq 2 ] && note=" (max-open-prs '$cap' in AGENTS.md is not a positive integer — no cap applied)"

    if ! throttle_count "$repo_dir" "$repo"; then
      printf '  %s: could not ask: %s%s\n' "$repo" "$THROTTLE_ERROR" "$note"
      # shellcheck disable=SC2034  # global, read by bin/tender's cmd_status()
      STATUS_FAILED=1
      any=1
      continue
    fi
    if [ "$THROTTLE_COUNT" -eq 0 ]; then
      [ -n "$note" ] || continue
      printf '  %s: no agent PRs open%s\n' "$repo" "$note"
      any=1
      continue
    fi
    if [ "$cap_rc" -eq 0 ]; then
      if [ "$THROTTLE_COUNT" -ge "$cap" ]; then note=" (cap $cap — full)"; else note=" (cap $cap)"; fi
    fi
    if [ "$THROTTLE_COUNT" -eq 1 ]; then
      printf '  %s: 1 agent PR open, waiting %s%s\n' "$repo" "$(throttle_age "$THROTTLE_OLDEST")" "$note"
    else
      printf '  %s: %s agent PRs open, oldest waiting %s%s\n' \
        "$repo" "$THROTTLE_COUNT" "$(throttle_age "$THROTTLE_OLDEST")" "$note"
    fi
    any=1
  done
  [ "$asked" -eq 0 ] || [ "$any" -eq 1 ] || printf '  (none)\n'
}
