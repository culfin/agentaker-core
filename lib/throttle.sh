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
# not, and neither is a value of ten digits or more — past that, bash
# arithmetic overflows long before any queue gets there. Prints the raw
# value; rc 0 valid, 1 absent, 2 present but invalid.
throttle_cap() {
  local line value
  line=$(grep -m1 '^max-open-prs:' "$1/AGENTS.md" 2>/dev/null) || return 1
  value=${line#max-open-prs:}
  value=${value%%#*}
  value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  printf '%s' "$value"
  # 0-leading is refused too: bash arithmetic would read 08 as a bad octal.
  case $value in ''|0*|*[!0-9]*|??????????*) return 2 ;; esac
  return 0
}

# owner/name of checkout $1's `origin`, if it is a GitHub remote — https
# (with or without a user), ssh:// or scp-style. rc 1 for no origin, or an
# origin somewhere else: such a project has no GitHub queue to count.
throttle_github_slug() {
  local url slug
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  url=${url%/}
  url=${url%.git}
  slug=$(printf '%s\n' "$url" \
    | sed -nE 's#^(https?://([^@/]+@)?github\.com/|ssh://git@github\.com/|git@github\.com:)([^/]+/[^/]+)$#\3#p')
  [ -n "$slug" ] || return 1
  printf '%s' "$slug"
}

# Counts repo $2's open agent PRs on GitHub repository $3 (owner/name),
# asking `gh` from inside its checkout $1. Sets THROTTLE_COUNT,
# THROTTLE_OLDEST (createdAt of the oldest, ISO-8601 UTC) and
# THROTTLE_TRUNCATED (1 when gh returned its whole --limit: the listing then
# holds only the newest 200 open PRs, agent or not, and the count is a lower
# bound — callers must not treat it as the answer). rc 1 means "could not
# ask" — gh missing, offline, unauthenticated — with the reason in
# THROTTLE_ERROR; that must never read as zero, the same three-way
# discipline as status_query() in bin/tender.
#
# The branch filter runs here rather than in --jq so the rule is plain shell:
# exact name or name plus "-suffix". A prefix match alone would count
# `acme-developerx`, and a branch of a repo named `acme-web` never matches
# `acme-developer…` at all. stderr goes to its own file: a gh warning mixed
# into stdout would be counted as a line of the listing.
THROTTLE_LIMIT=200
throttle_count() {
  local repo_dir=$1 repo=$2 slug=$3 out rc branch created raw=0 errfile
  THROTTLE_COUNT=0 THROTTLE_OLDEST="" THROTTLE_ERROR="" THROTTLE_TRUNCATED=0
  if ! command -v gh >/dev/null 2>&1; then
    THROTTLE_ERROR="gh is not installed"
    return 1
  fi
  errfile=$(mktemp) || { THROTTLE_ERROR="cannot create a temporary file"; return 1; }
  out=$(cd "$repo_dir" && gh pr list -R "$slug" --state open --json headRefName,createdAt \
        --limit "$THROTTLE_LIMIT" --jq '.[] | "\(.headRefName) \(.createdAt)"' 2>"$errfile")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    THROTTLE_ERROR=$(head -1 "$errfile")
    THROTTLE_ERROR=${THROTTLE_ERROR:-gh exited $rc}
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"
  while read -r branch created; do
    [ -n "$branch" ] || continue
    raw=$((raw + 1))
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
  [ "$raw" -ge "$THROTTLE_LIMIT" ] && THROTTLE_TRUNCATED=1
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
# started (worktree path $2) has a pane open right now — found by the pane's
# start path, not its window name. A window name is only role_tag() plus the
# suffix, and role_tag() abbreviates an unknown role like `devops` to DEV
# too: `tender acme devops x` runs in a window named DEV·x, exactly like
# `tender acme developer x` would. The path cannot be confused that way.
#
# #{pane_start_path}, not #{pane_current_path}: the start path is the `-c`
# cmd_start() (and restart's respawn-pane) passes, kept verbatim for the
# pane's life — measured on tmux 3.6a, it stays the worktree after the
# process cd's into a subdirectory, and it is not symlink-resolved (the
# current path came back as /private/var/… for a /var/… worktree on
# macOS). Both sides are built as "$PROJECTS_DIR/<repo>/.worktrees/<name>",
# so a plain string comparison is exact. A tmux too old to know the format
# prints an empty path, which matches nothing: the start proceeds.
#
# `=` makes tmux match the session name exactly — without it, `tender-de`
# also finds `tender-demo`.
throttle_other_developer_running() {
  local repo=$1 own=$2 paths wt
  command -v tmux >/dev/null 2>&1 || return 1
  # Each line carries a leading "x", so a pane whose path tmux cannot tell
  # (tmux < 3.3 has no pane_start_path) shows up as a bare "x" instead of
  # vanishing into an empty string that looks like "no panes at all".
  paths=$(tmux list-panes -s -t "=$(session_name "$repo")" -F 'x#{pane_start_path}' 2>/dev/null) || return 1
  if [ -n "$paths" ] && ! printf '%s\n' "$paths" | grep -q '^x.'; then
    printf 'tender: this tmux cannot tell which session runs in which worktree (pane_start_path needs tmux 3.3) — max-open-prs not checked for this start\n' >&2
    return 1
  fi
  paths=$(printf '%s\n' "$paths" | sed 's/^x//')
  for wt in "$PROJECTS_DIR/$repo/.worktrees/$repo-developer" \
            "$PROJECTS_DIR/$repo/.worktrees/$repo-developer-"*; do
    [ -d "$wt" ] || continue
    [ "$wt" = "$own" ] && continue
    printf '%s\n' "$paths" | grep -qxF "$wt" && return 0
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
  local repo=$1 suffix=$2 repo_dir="$PROJECTS_DIR/$1" cap slug
  cap=$(throttle_cap "$repo_dir") || return 0
  throttle_other_developer_running "$repo" \
    "$repo_dir/.worktrees/$repo-developer${suffix:+-$suffix}" || return 0
  if ! slug=$(throttle_github_slug "$repo_dir"); then
    THROTTLE_ERROR="origin is not a GitHub remote"
  elif throttle_count "$repo_dir" "$repo" "$slug"; then
    # A truncated listing gives a lower bound. Below the cap it proves
    # nothing (more may be past the cut); at or above it, the queue is full
    # whatever the rest says — refused like a complete count.
    [ "$THROTTLE_TRUNCATED" -eq 1 ] && [ "$THROTTLE_COUNT" -lt "$cap" ] \
      && THROTTLE_ERROR="the listing stopped at $THROTTLE_LIMIT open PRs, so the count is incomplete"
  fi
  if [ -n "$THROTTLE_ERROR" ]; then
    printf 'tender: could not count open agent PRs (%s) — starting anyway, max-open-prs: %s unchecked\n' \
      "$THROTTLE_ERROR" "$cap" >&2
    return 0
  fi
  [ "$THROTTLE_COUNT" -lt "$cap" ] && return 0
  printf 'tender: %s has %s agent PRs open, at its cap (max-open-prs: %s in AGENTS.md), and a developer session is already running — not starting another. Review the open PRs first; see docs/limits.md\n' \
    "$repo" "$THROTTLE_COUNT" "$cap" >&2
  return 1
}

# One line per set-up project (a git checkout with AGENTS.md) of owner $1 —
# the owner cmd_status() already resolved, from its argument or
# TENDER_OWNER — that has agent PRs open, could not be asked, or carries an
# invalid cap. "Of owner $1" is read off `origin`: a project with no GitHub
# origin has no queue to count and is skipped silently, as is one whose
# origin belongs to someone else — the rest of the board is scoped to that
# owner too. A could-not-ask sets STATUS_FAILED, like every other section of
# the board. No project asked means no section; "(none)" is kept for
# "asked, and there are none".
throttle_status_section() {
  local owner=$1 repo_dir repo slug cap cap_rc note any=0 asked=0
  owner=$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')
  for repo_dir in "$PROJECTS_DIR"/*/; do
    repo_dir=${repo_dir%/}
    [ -e "$repo_dir/.git" ] && [ -f "$repo_dir/AGENTS.md" ] || continue
    slug=$(throttle_github_slug "$repo_dir") || continue
    # GitHub owner names are case-insensitive.
    [ "$(printf '%s' "${slug%%/*}" | tr '[:upper:]' '[:lower:]')" = "$owner" ] || continue
    [ "$asked" -eq 1 ] || printf 'agent PRs open:\n'
    asked=1
    repo=${repo_dir##*/}
    cap=$(throttle_cap "$repo_dir")
    cap_rc=$?
    note=""
    [ "$cap_rc" -eq 2 ] && note=" (max-open-prs '$cap' in AGENTS.md is not a positive integer — no cap applied)"

    if ! throttle_count "$repo_dir" "$repo" "$slug"; then
      printf '  %s: could not ask: %s%s\n' "$repo" "$THROTTLE_ERROR" "$note"
      # shellcheck disable=SC2034  # global, read by bin/tender's cmd_status()
      STATUS_FAILED=1
      any=1
      continue
    fi
    if [ "$THROTTLE_TRUNCATED" -eq 1 ]; then
      # A lower bound, said as one: no oldest (the oldest are exactly what
      # the limit cut off) and no cap verdict built on it.
      printf '  %s: ≥%s agent PRs open (list truncated at %s)%s\n' \
        "$repo" "$THROTTLE_COUNT" "$THROTTLE_LIMIT" "$note"
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
