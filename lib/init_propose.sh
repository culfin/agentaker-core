#!/usr/bin/env bash
# `atk init <repo> --propose --json` — everything init would do, as one JSON
# object, and nothing done.
#
# Why this exists (app issue #6): the desktop app's setup wizard shows the
# user what init proposes before anything happens, and lets them edit it. It
# must not re-implement stack detection, test suggestions or the AGENTS.md
# text to do that — so it asks here, re-asks with the user's edits as the same
# value flags init takes, and shows whatever comes back. Every value below
# comes from the function init itself uses (detect_stack(), suggest_tests(),
# init_trunk(), init_render_agents_md()); nothing is computed twice.
#
# No side effects of any kind: no file written, no label or environment
# created, no worktree, no commit. Read-only `git` and read-only `gh` only.
# Where a remote answer could not be had — no gh, ATK_NO_NETWORK, offline,
# no access — the field is null. Never a guess: "not there" and "could not
# ask" lead a wizard to different screens.
#
# Sourced by bin/atk on demand with lib/init.sh, for `atk init` only.
#
# Needs from bin/atk:   PROJECTS_DIR
# Needs from lib/init.sh:  detect_stack(), suggest_tests(), init_trunk(),
#                          init_render_agents_md(), init_agents_md_in_head(),
#                          and the INIT_* globals
#                          init_parse_args() (lib/init_flags.sh) set
# Needs from lib/json.sh:  json_escape(), json_string()
# Provides to lib/init.sh: init_propose()

INIT_LABEL_NAMES="ready needs-decision approved"

# $1 or JSON null when $1 is empty — for the fields that are null exactly
# when they could not be known.
init_json_or_null() {
  if [ -n "$1" ]; then json_string "$1"; else printf 'null'; fi
}

# Lines of $1 as a JSON array of strings; [] for an empty $1.
init_json_lines() {
  local out="" line
  while IFS= read -r line; do
    out="$out${out:+,}$(json_string "$line")"
  done <<EOF
$1
EOF
  [ -n "$1" ] || out=""
  printf '[%s]' "$out"
}

# True if a gh call from $1 may be tried at all — the same condition under
# which init runs its labels and environment steps, plus gh actually existing.
init_can_ask_gh() {
  [ -z "${ATK_NO_NETWORK:-}" ] && command -v gh >/dev/null 2>&1
}

# Which of the three labels already exist, as a JSON array; null when the
# remote could not be asked. `gh label list` only reads.
init_propose_labels() {
  local dir=$1 have name out=""
  init_can_ask_gh || { printf 'null'; return 0; }
  have=$(cd "$dir" && gh label list --limit 1000 --json name --jq '.[].name' 2>/dev/null) \
    || { printf 'null'; return 0; }
  for name in $INIT_LABEL_NAMES; do
    # GitHub label names are case-insensitive: `Ready` blocks creating `ready`.
    if printf '%s\n' "$have" | grep -qixF "$name"; then
      out="$out${out:+,}$(json_string "$name")"
    fi
  done
  printf '[%s]' "$out"
}

# "slug":…,"exists":… for the production environment. A plain GET only —
# the same existence check init runs before its PUT. Only a 404 means
# "does not exist"; any other failure means "could not ask", i.e. null.
init_propose_environment() {
  local dir=$1 slug exists=null err
  init_can_ask_gh || { printf '"slug":null,"exists":null'; return 0; }
  slug=$(cd "$dir" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || slug=""
  if [ -n "$slug" ]; then
    if err=$(cd "$dir" && gh api "repos/$slug/environments/production" 2>&1 >/dev/null); then
      exists=true
    else
      case "$err" in *"HTTP 404"*) exists=false ;; esac
    fi
  fi
  printf '"slug":%s,"exists":%s' "$(init_json_or_null "$slug")" "$exists"
}

init_propose() {
  local repo=$1 dir=$2
  local branch trunk stack agents_path agents_exists agents_committed content bin
  local prereq="" role wt worktrees="" wt_exists

  # A relative ATK_PROJECTS_DIR would make every path below relative to
  # wherever the caller happened to be; the app needs them absolute.
  case "$dir" in /*) : ;; *) dir="$PWD/$dir" ;; esac

  for bin in git gh tmux; do
    if command -v "$bin" >/dev/null 2>&1; then
      prereq="$prereq${prereq:+,}\"$bin\":true"
    else
      prereq="$prereq${prereq:+,}\"$bin\":false"
    fi
  done

  branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null) || branch=""
  trunk=$(init_trunk "$dir")
  stack=$(detect_stack "$dir")

  # --tests values are listed as given, one element per flag, even one that
  # holds a newline; otherwise one element per suggest_tests() line.
  local tests_json t
  if [ "${#INIT_TESTS[@]}" -gt 0 ]; then
    tests_json=""
    for t in "${INIT_TESTS[@]}"; do tests_json="$tests_json${tests_json:+,}$(json_string "$t")"; done
    tests_json="[$tests_json]"
  else
    tests_json=$(init_json_lines "$(suggest_tests "$stack")")
  fi

  agents_path="$dir/AGENTS.md"
  # On disk and in HEAD, i.e. what `--commit` would leave alone. False for a
  # file that is not there (yet) — init would write and commit one — and for
  # one on disk but never committed, which `--commit` would commit.
  if [ -f "$agents_path" ] && init_agents_md_in_head "$dir"; then
    agents_committed=true
  else
    agents_committed=false
  fi
  if [ -f "$agents_path" ]; then
    agents_exists=true content=null
  else
    # Plus the one trailing newline cmd_init() writes after the rendering.
    agents_exists=false
    content=$(json_string "$(init_render_agents_md "$trunk" "$stack")"$'\n')
  fi

  for role in developer reviewer maintainer; do
    wt="$dir/.worktrees/$repo-$role"
    if [ -d "$wt" ]; then wt_exists=true; else wt_exists=false; fi
    worktrees="$worktrees${worktrees:+,}{\"role\":\"$role\",\"path\":$(json_string "$wt"),\"branch\":$(json_string "$repo-$role"),\"exists\":$wt_exists}"
  done

  printf '{'
  printf '"repo":%s,"dir":%s,' "$(json_string "$repo")" "$(json_string "$dir")"
  printf '"prerequisites":{%s},' "$prereq"
  printf '"branch":%s,"trunk":%s,' "$(init_json_or_null "$branch")" "$(json_string "$trunk")"
  # shellcheck disable=SC2086  # detect_stack() output is space-separated names
  printf '"stack":%s,' "$(init_json_lines "$(printf '%s\n' $stack)")"
  printf '"tests":%s,' "$tests_json"
  printf '"agents_md":{"path":%s,"exists":%s,"committed":%s,"content":%s},' \
    "$(json_string "$agents_path")" "$agents_exists" "$agents_committed" "$content"
  if [ "$INIT_BOUNDARY_GIVEN" -eq 1 ]; then printf '"boundary_given":true,'; else printf '"boundary_given":false,'; fi
  # shellcheck disable=SC2086  # INIT_LABEL_NAMES is a space-separated list
  printf '"labels":{"names":%s,"existing":%s},' \
    "$(init_json_lines "$(printf '%s\n' $INIT_LABEL_NAMES)")" "$(init_propose_labels "$dir")"
  printf '"environment":{"name":"production",%s},' "$(init_propose_environment "$dir")"
  printf '"worktrees":[%s]' "$worktrees"
  printf '}\n'
}
