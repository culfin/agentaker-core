#!/usr/bin/env bash
# The facts tender can vouch for itself before a restart — git and GitHub state,
# never the session's own report of what it did. The session still writes
# .agents/handoff.md by hand (roles/_base.md's "Handing over" section); this
# file is the other half, and the two are appended to the successor's context
# in that order (see restart_window() in lib/manage.sh) — facts first, so a
# contradiction in the free text is visible on the first read, not the second.
#
# Sourced by bin/tender on demand, alongside lib/manage.sh, only for `restart` —
# `list` and `drop` never call collect_state(), so they don't pay to parse it.
#
# Needs from bin/tender: nothing — every function here is self-contained.
# Provides to it:     collect_state()
#
# Three-way discipline per line, the same one status_query() in bin/tender uses:
# a real answer, an explicit "none" when the source genuinely has nothing to
# say, or "could not ask" when the source itself could not be reached (no
# network, gh not logged in, no such PR). Never a blank line, never a guess —
# and never anything that stops the restart this precedes: every source below
# degrades instead of failing outward.

state_line() { printf '%-14s %s\n' "$1:" "$2"; }

# The issue number a PR body claims to close, or empty. "Closes #<N>" is the
# phrasing roles/developer.md's PR template uses; matched case-insensitively
# because GitHub itself treats "closes"/"Closes"/"CLOSES" as the same keyword.
closes_issue() {
  printf '%s\n' "$1" | grep -oiE 'closes #[0-9]+' | head -1 | grep -oE '[0-9]+'
}

# Writes $1/.agents/state.md. $2 is the role already known to the caller
# (restart_window() has it as $role) — read from disk again here, it would
# just be $(cat "$1/.agents/ROLE"), so passing it saves nothing but a file
# read avoided is one less way to be wrong.
collect_state() {
  local wt=$1 role=$2
  local out="$wt/.agents/state.md"
  local worktree_name; worktree_name=$(basename "$wt")

  local branch
  branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null) \
    || branch=$(git -C "$wt" rev-parse --short HEAD 2>/dev/null) \
    || branch="could not ask"

  # HEAD --not --remotes, not --branches: the same scoping cmd_drop() uses in
  # lib/manage.sh, and for the same reason — this worktree's branch only, not
  # every local branch sharing the repository's ref store.
  local ahead_log ahead
  if ahead_log=$(git -C "$wt" log HEAD --not --remotes --oneline 2>&1); then
    ahead=$([ -z "$ahead_log" ] && printf 0 || printf '%s\n' "$ahead_log" | grep -c .)
  else
    ahead="could not ask"
  fi
  local last; last=$(git -C "$wt" log -1 --format=%s 2>/dev/null)
  [ -n "$last" ] || last="could not ask"

  local dirty uncommitted
  if dirty=$(git -C "$wt" status --porcelain 2>&1); then
    if [ -z "$dirty" ]; then uncommitted="none"
    else uncommitted="$(printf '%s\n' "$dirty" | grep -c .) file(s)"
    fi
  else
    uncommitted="could not ask"
  fi

  # One gh call, not three: number, draft state and body (newlines flattened
  # to spaces, so the line below stays one line) tab-separated on a single
  # line — parsed with parameter expansion rather than `read`, to match how
  # the rest of this repository already slices strings (see describe_worktree()
  # in lib/manage.sh), not because `read` would be wrong here.
  local raw rc pr_line="none" claim_line="none"
  raw=$(cd "$wt" && gh pr list --head "$branch" --state open \
    --json number,isDraft,body \
    --jq '.[0] | if . == null then "" else "\(.number)\t\(.isDraft)\t\((.body // "") | gsub("\n";" "))" end' \
    2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    pr_line="could not ask: $(printf '%s' "$raw" | head -1)"
    claim_line="could not ask"
  elif [ -n "$raw" ]; then
    local number rest draft body issue
    number=${raw%%$'\t'*}
    rest=${raw#*$'\t'}
    draft=${rest%%$'\t'*}
    body=${rest#*$'\t'}
    local draft_word="ready"
    [ "$draft" = "true" ] && draft_word="draft"
    pr_line="#$number ($draft_word)"
    issue=$(closes_issue "$body")
    if [ -n "$issue" ]; then
      pr_line="$pr_line — closes #$issue"
      local claim_ref; claim_ref="refs/claims/issue-$issue"
      local ls; if ls=$(git -C "$wt" ls-remote origin "$claim_ref" 2>&1); then
        claim_line=$([ -n "$ls" ] && printf '%s' "$claim_ref" || printf 'none')
      else
        claim_line="could not ask"
      fi
    fi
  fi

  {
    printf '## State (collected by tender, not reported by the session)\n\n'
    state_line "role" "$role"
    state_line "worktree" "$worktree_name"
    state_line "branch" "$branch"
    state_line "commits ahead" "$ahead  last: \"$last\""
    state_line "uncommitted" "$uncommitted"
    state_line "open PR" "$pr_line"
    state_line "claim held" "$claim_line"
  } > "$out"
}
