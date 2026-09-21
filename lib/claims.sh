#!/usr/bin/env bash
# `tender claims` / `tender claim-release` — the claim mechanism `roles/developer.md`
# (and, for PRs, `roles/reviewer.md`) writes out as prose, as a command. A GUI
# that wants to show or take over a claim would otherwise have to reimplement:
# which refs exist, how to read the timestamp out of the blob, what this
# project's threshold is, and the exact release-then-reclaim dance. That is a
# second implementation of a security-relevant mechanism, drifting from the
# first — this file is the one place both the CLI and any future UI go through
# instead.
#
# `roles/developer.md`'s "Claiming" section is the source of truth for the
# mechanism itself; nothing here invents a step it doesn't already describe:
# `git ls-remote` for the hash, `git fetch` before `git cat-file` can read it
# (`ls-remote` alone leaves the object unfetched — fails with "could not get
# object info" otherwise, measured there), release-then-reclaim rather than
# `--force`, and the braced `"${sha}:${refname}"` refspec (an unbraced one
# loses its `:r` under zsh — bash never shows this, so it is easy to carry
# over unnoticed).
#
# Sourced by bin/tender on demand, the same as lib/manage.sh and lib/doctor.sh:
# `claims`/`claim-release` are not on the everyday `tender <repo> <role>` path.
#
# Needs from bin/tender: die(), PROJECTS_DIR, json_escape() (lib/json.sh)
# Provides to it:     cmd_claims(), cmd_claim_release()

# claim-timeout-days from $1/AGENTS.md, or 2 if the file is silent about it —
# same field, same default, `roles/developer.md`'s claim step reads out of
# the worktree's own copy. This runs against the repo's main checkout
# (PROJECTS_DIR/<repo>), not a worktree — `claims`/`claim-release` don't
# operate inside one.
claims_threshold() {
  local file="$1/AGENTS.md" threshold
  threshold=$(grep -m1 '^claim-timeout-days:' "$file" 2>/dev/null | grep -oE '[0-9]+')
  printf '%s' "${threshold:-2}"
}

claims_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# now minus $1 days, ISO-8601 UTC — the exact cutoff computation
# roles/developer.md's claim step runs (GNU date, then BSD/macOS date).
claims_cutoff() {
  local threshold=$1
  date -u -d "-${threshold} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${threshold}"d +%Y-%m-%dT%H:%M:%SZ
}

# Epoch seconds for ISO-8601 UTC timestamp $1 (GNU date, then BSD/macOS
# date), or empty + rc 1 if neither can parse it — a malformed blob should
# show up as "unknown", never crash the listing.
claims_epoch() {
  local ts=$1
  date -u -d "$ts" +%s 2>/dev/null \
    || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null
}

# Rough "how long ago", from a seconds count. Only for the human-readable
# table; --json carries age_seconds instead, so a UI never has to parse this.
claims_age() {
  local diff=$1
  if [ "$diff" -lt 60 ]; then printf '%ds ago' "$diff"
  elif [ "$diff" -lt 3600 ]; then printf '%dm ago' "$((diff / 60))"
  elif [ "$diff" -lt 86400 ]; then printf '%dh ago' "$((diff / 3600))"
  else printf '%dd ago' "$((diff / 86400))"
  fi
}

# True (rc 0) if $1 (an ISO-8601 UTC timestamp) is older than a claim-
# timeout-days-$2 threshold — the same string comparison
# roles/developer.md's claim step runs against its cutoff, not a numeric
# one: both sides are the same fixed-width ISO-8601 shape, so lexicographic
# order is chronological order.
claims_is_orphaned() {
  local claimed_at=$1 threshold=$2 cutoff
  cutoff=$(claims_cutoff "$threshold")
  [ -n "$claimed_at" ] && [ "$claimed_at" \< "$cutoff" ]
}

# `tender claims <repo> [--json]` — list every refs/claims/* ref on the repo's
# remote: name, when it was claimed, how long ago, and whether it's past the
# project's threshold. Never fails the whole listing over one bad ref (a
# fetch or cat-file that can't be reached becomes "could not ask" on that
# row, not a missing row) — the same three-way discipline status_query() in
# bin/tender and collect_state() in lib/state.sh already use: a real answer, an
# explicit "none", or "could not ask", never a blank line and never a guess.
cmd_claims() {
  local repo="" json=0 arg
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      *) repo=$arg ;;
    esac
  done
  [ -n "$repo" ] || die "give a repo: tender claims <repo> [--json]"

  local repo_dir="$PROJECTS_DIR/$repo"
  [ -e "$repo_dir/.git" ] || die "$repo_dir is not a git repository"

  local threshold; threshold=$(claims_threshold "$repo_dir")

  local ls_out rc
  ls_out=$(git -C "$repo_dir" ls-remote origin 'refs/claims/*' 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$json" -eq 1 ]; then
      printf '{"error":"could not ask: %s"}\n' "$(json_escape "$(printf '%s' "$ls_out" | head -1)")"
    else
      printf 'could not ask: %s\n' "$(printf '%s' "$ls_out" | head -1)"
    fi
    return 1
  fi

  if [ -z "$ls_out" ]; then
    if [ "$json" -eq 1 ]; then printf '[]\n'; else printf '(none)\n'; fi
    return 0
  fi

  local had_failure=0 first=1
  [ "$json" -eq 1 ] && printf '['
  local line hash refname name
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    hash=${line%%$'\t'*}
    refname=${line#*$'\t'}
    name=${refname#refs/claims/}

    if [ "$json" -eq 1 ]; then
      [ "$first" -eq 1 ] || printf ','
      first=0
    fi

    local err
    err=$(git -C "$repo_dir" fetch -q origin "$refname" 2>&1)
    if [ $? -ne 0 ]; then
      had_failure=1
      if [ "$json" -eq 1 ]; then
        printf '{"name":"%s","ref":"%s","error":"could not ask: %s"}' \
          "$(json_escape "$name")" "$(json_escape "$refname")" \
          "$(json_escape "$(printf '%s' "$err" | head -1)")"
      else
        printf '%-10s could not ask: %s\n' "$name" "$(printf '%s' "$err" | head -1)"
      fi
      continue
    fi

    # The fetch succeeded, so the object is here. If it is not a blob, the
    # question was answered — the answer is just not a claim. Reporting that
    # as "could not ask" would read as a network failure, and setting
    # had_failure would fail the whole listing over one unusable ref. Claims
    # written before blobs replaced `git commit-tree` are commits, and they
    # still exist on remotes.
    local objtype
    objtype=$(git -C "$repo_dir" cat-file -t "$hash" 2>/dev/null)
    if [ -n "$objtype" ] && [ "$objtype" != "blob" ]; then
      if [ "$json" -eq 1 ]; then
        printf '{"name":"%s","ref":"%s","error":"not a claim blob: a %s"}' \
          "$(json_escape "$name")" "$(json_escape "$refname")" \
          "$(json_escape "$objtype")"
      else
        printf '%-10s not a claim blob: a %s (an older treetender wrote these as commits)\n' "$name" "$objtype"
      fi
      continue
    fi

    local blob claimed_at
    blob=$(git -C "$repo_dir" cat-file blob "$hash" 2>&1)
    if [ $? -ne 0 ]; then
      had_failure=1
      if [ "$json" -eq 1 ]; then
        printf '{"name":"%s","ref":"%s","error":"could not ask: %s"}' \
          "$(json_escape "$name")" "$(json_escape "$refname")" \
          "$(json_escape "$(printf '%s' "$blob" | head -1)")"
      else
        printf '%-10s could not ask: %s\n' "$name" "$(printf '%s' "$blob" | head -1)"
      fi
      continue
    fi
    claimed_at=$(printf '%s' "$blob" | cut -d' ' -f2)

    local orphaned=0
    claims_is_orphaned "$claimed_at" "$threshold" && orphaned=1

    local epoch age_seconds age_str
    epoch=$(claims_epoch "$claimed_at")
    if [ -n "$epoch" ]; then
      age_seconds=$(( $(date -u +%s) - epoch ))
      age_str=$(claims_age "$age_seconds")
    else
      age_seconds=""
      age_str="unknown"
    fi

    if [ "$json" -eq 1 ]; then
      printf '{"name":"%s","ref":"%s","claimed_at":"%s","age_seconds":%s,"orphaned":%s,"threshold_days":%s}' \
        "$(json_escape "$name")" "$(json_escape "$refname")" \
        "$(json_escape "$claimed_at")" "${age_seconds:-null}" \
        "$([ "$orphaned" -eq 1 ] && printf true || printf false)" "$threshold"
    else
      if [ "$orphaned" -eq 1 ]; then
        printf '%-10s claimed %s   %s   orphaned (threshold: %s days)\n' \
          "$name" "$claimed_at" "$age_str" "$threshold"
      else
        printf '%-10s claimed %s   %s\n' "$name" "$claimed_at" "$age_str"
      fi
    fi
  done <<CLAIMSOUT
$ls_out
CLAIMSOUT
  [ "$json" -eq 1 ] && printf ']\n'

  return "$had_failure"
}

# `tender claim-release <repo> <N|issue-N|pr-N>` — release an orphaned claim and
# immediately reclaim it, exactly the takeover `roles/developer.md` (issues)
# and `roles/reviewer.md` (PRs) perform when a claim attempt loses to one
# that's older than the threshold: two ordinary pushes, never `--force`, plus
# the same issue/PR comment so the handover stays visible to a human. Refuses
# outright if the held claim is not actually past the threshold — a command
# that releases whatever it's pointed at is a command that will one day
# release a live claim out from under a session still working.
cmd_claim_release() {
  local repo=${1:-} claim=${2:-}
  [ -n "$repo" ] && [ -n "$claim" ] \
    || die "usage: tender claim-release <repo> <N|issue-N|pr-N>"

  local repo_dir="$PROJECTS_DIR/$repo"
  [ -e "$repo_dir/.git" ] || die "$repo_dir is not a git repository"

  local name
  case "$claim" in
    issue-*|pr-*) name=$claim ;;
    *[!0-9]*) die "'$claim' is not a claim name — use a bare issue number, or 'issue-N' / 'pr-N'" ;;
    *) name="issue-$claim" ;;
  esac

  local kind num
  case "$name" in
    issue-*) kind="issue"; num=${name#issue-} ;;
    pr-*)    kind="pr";    num=${name#pr-} ;;
  esac
  case "$num" in *[!0-9]*|'') die "'$claim' is not a claim name — use a bare issue number, or 'issue-N' / 'pr-N'" ;; esac

  local refname="refs/claims/$name"
  local threshold; threshold=$(claims_threshold "$repo_dir")

  local held rc
  held=$(git -C "$repo_dir" ls-remote origin "$refname" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || die "could not ask: $(printf '%s' "$held" | head -1)"
  [ -n "$held" ] || die "no claim held on $refname — nothing to release"

  local hash=${held%%$'\t'*}

  local fetch_err
  fetch_err=$(git -C "$repo_dir" fetch -q origin "$refname" 2>&1) \
    || die "could not fetch $refname to read it: $(printf '%s' "$fetch_err" | head -1)"

  local blob claimed_at
  blob=$(git -C "$repo_dir" cat-file blob "$hash" 2>&1) \
    || die "could not read the claim blob on $refname: $(printf '%s' "$blob" | head -1)"
  claimed_at=$(printf '%s' "$blob" | cut -d' ' -f2)
  [ -n "$claimed_at" ] \
    || die "$refname does not look like a claim blob (no timestamp) — refusing to touch it"

  # Refusing is the point: a command that will release any claim on request
  # will one day release one still in use.
  claims_is_orphaned "$claimed_at" "$threshold" \
    || die "$name was claimed $claimed_at — younger than the ${threshold}-day threshold ($(claims_cutoff "$threshold") is the cutoff), refusing to release a live claim"

  # Release-then-reclaim, never --force: the same two ordinary pushes as a
  # voluntary release followed by a normal claim — see roles/developer.md.
  local release_err
  release_err=$(git -C "$repo_dir" push origin ":${refname}" 2>&1) \
    || die "could not release $refname: $(printf '%s' "$release_err" | head -1)"

  local sha
  sha=$(printf 'claim %s' "$(claims_now_iso)" | git -C "$repo_dir" hash-object -w --stdin) \
    || die "could not build the reclaim object"

  local reclaim_err
  if ! reclaim_err=$(git -C "$repo_dir" push origin "${sha}:${refname}" 2>&1); then
    printf 'tender: released %s but could not reclaim it (%s) — someone else may hold it now; see `tender claims %s`\n' \
      "$name" "$(printf '%s' "$reclaim_err" | head -1)" "$repo" >&2
    return 1
  fi

  local comment="**[tender claim-release]** Took over a claim from $claimed_at (older than ${threshold}d)."
  local comment_err
  if [ "$kind" = issue ]; then
    comment_err=$(cd "$repo_dir" && gh issue comment "$num" --body "$comment" 2>&1)
  else
    comment_err=$(cd "$repo_dir" && gh pr comment "$num" --body "$comment" 2>&1)
  fi
  if [ $? -ne 0 ]; then
    printf 'tender: reclaimed %s, but could not post the takeover comment: %s\n' \
      "$name" "$(printf '%s' "$comment_err" | head -1)" >&2
  fi

  printf 'released and reclaimed %s (was claimed %s, older than the %sd threshold)\n' \
    "$name" "$claimed_at" "$threshold"
}
