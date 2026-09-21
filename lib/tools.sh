#!/usr/bin/env bash
# The external tools table (issue #2): a config file line overrides
# launch_command()'s built-in `case` for the tool it names, so adding a
# coding agent no longer needs a code change or a release. The built-in
# branches stay as the default — without a file, or without a line in it for
# the tool being launched, behaviour is byte-for-byte what it was before this
# file existed. See docs/tools.md for the format and the two-point contract
# every tool has to meet.
#
# Sourced by bin/mdt unconditionally, right after lib/tabs.sh: launch_command()
# runs on every cmd_start(), the hot path, and lib/manage.sh's restart_window()
# calls it too — the same reason lib/tabs.sh is loaded eagerly rather than on
# demand (see its own header) rather than sourced only for the subcommands
# that need it, the way lib/init.sh and lib/manage.sh are.
#
# Needs from bin/mdt: die(), TOOL
# Provides to it:     launch_command() (sets LAUNCH_CMD, TOOL_STATUS)
# Provides to lib/doctor.sh, on demand, for `mdt doctor`:
#                      tools_file_path(), tools_known_names()

# ${XDG_CONFIG_HOME:-$HOME/.config}/mandate/tools, or MDT_TOOLS_FILE to
# override it — tests need the override, so they never read (or race) a real
# file a developer happens to have at the default path.
tools_file_path() {
  printf '%s' "${MDT_TOOLS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/mandate/tools}"
}

# True (rc 0) if $1 is blank, or a comment once its leading whitespace is
# stripped — the only two kinds of line tools_file_lookup() and
# tools_known_names() skip outright, before spending a `read -a` on it.
tools_file_skip_line() {
  local trimmed=${1#"${1%%[![:space:]]*}"}
  case "$trimmed" in
    ''|'#'*) return 0 ;;
    *)       return 1 ;;
  esac
}

# Splits $1 on whitespace into the global array TOOLS_FIELDS. `read -a`, not
# `( $1 )`: the latter is subject to pathname expansion on anything that
# looks like a glob, the former just splits on IFS. This is also the reason
# the format stays whitespace-split rather than shell-quoted: a parser for
# quoted arguments is exactly the dependency docs/tools.md says this file
# format exists to avoid, and an argument that itself needs an embedded space
# genuinely cannot be expressed here — see docs/tools.md, "What the format
# cannot do", rather than silently mis-splitting it.
tools_split_line() {
  read -r -a TOOLS_FIELDS <<< "$1"
}

# Scans the tools file for a line naming $1 (the tool). On a match, sets
# LAUNCH_CMD (the line's command tokens, with the literal token `{context}`
# replaced by $2) and TOOL_STATUS (verified if the status column starts with
# `verified:`, unverified otherwise), and returns 0.
#
# Returns 1 if there is no file, or no line names $1 — the caller
# (launch_command(), below) falls back to the built-in table, exactly the
# behaviour from before this file existed.
#
# A line naming $1 that has no `{context}` token is not folded into that
# same "not found" case: the tool would start and never receive its role,
# silently — the docs/tools.md warning table is not in front of anyone at
# that moment either. That is treated as fatal (die()), not skipped.
#
# Every other malformed line — one with too few fields, whatever tool it
# names or fails to — is reported with its file and line number to stderr
# and skipped, so one bad row never hides a good row beneath it.
tools_file_lookup() {
  local tool=$1 ctx=$2 file
  file=$(tools_file_path)
  [ -r "$file" ] || return 1

  local line lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    tools_file_skip_line "$line" && continue

    local -a TOOLS_FIELDS=()
    tools_split_line "$line"
    local n=${#TOOLS_FIELDS[@]}
    if [ "$n" -lt 3 ]; then
      printf 'mdt: %s:%d: too few fields (need name, command with {context}, status) — skipping\n' \
        "$file" "$lineno" >&2
      continue
    fi
    [ "${TOOLS_FIELDS[0]}" = "$tool" ] || continue

    local status=${TOOLS_FIELDS[$((n - 1))]}
    local i has_ctx=0
    LAUNCH_CMD=()
    for ((i = 1; i <= n - 2; i++)); do
      if [ "${TOOLS_FIELDS[$i]}" = '{context}' ]; then
        LAUNCH_CMD+=("$ctx")
        has_ctx=1
      else
        LAUNCH_CMD+=("${TOOLS_FIELDS[$i]}")
      fi
    done
    if [ "$has_ctx" -eq 0 ]; then
      die "$file:$lineno: '$tool' has no {context} in its launch command — it would start and never receive its role. Fix the line (see docs/tools.md) or remove it."
    fi

    case "$status" in
      verified:*) TOOL_STATUS=verified ;;
      *)          TOOL_STATUS=unverified ;;
    esac
    return 0
  done < "$file"

  return 1
}

# Every tool name mdt currently knows how to start: the built-in two, plus
# every validly-shaped line in the tools file (malformed ones are reported
# and skipped, same as tools_file_lookup() — used by `mdt doctor` with no
# argument, which has to enumerate the same set launch_command() would ever
# actually use). Order: built-ins first, then the file, first-seen kept —
# not sorted, so `mdt doctor`'s own output order stays predictable across
# runs of the same file rather than shuffling with locale collation.
tools_known_names() {
  {
    printf 'claude\ncodex\n'
    local file; file=$(tools_file_path)
    if [ -r "$file" ]; then
      local line lineno=0
      while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        tools_file_skip_line "$line" && continue
        local -a TOOLS_FIELDS=()
        tools_split_line "$line"
        if [ "${#TOOLS_FIELDS[@]}" -lt 3 ]; then
          printf 'mdt: %s:%d: too few fields (need name, command with {context}, status) — skipping\n' \
            "$file" "$lineno" >&2
          continue
        fi
        printf '%s\n' "${TOOLS_FIELDS[0]}"
      done < "$file"
    fi
  } | awk '!seen[$0]++'
}

# --- the one vendor-aware function -------------------------------------------
# Sets the global array LAUNCH_CMD to the argv that starts $TOOL with $1 (the
# assembled role file) as its system prompt. Returns 1 when the tool is
# unknown to both the tools file and the built-in table below.
#
# A global rather than a printed list, for two reasons: `mapfile` does not exist
# in bash 3.2, which is still /bin/bash on macOS, and a multi-line prompt would
# shred any line-based protocol anyway.
#
# The tools file (tools_file_lookup(), above) is tried first; a line in it for
# $TOOL overrides the case below. Nothing in the file changes what happens
# when the file doesn't exist, or has no line for $TOOL — the two everyday
# tools stay exactly this readable, and adding a third no longer needs either.
launch_command() {
  local ctx=$1 tool=${TOOL:-claude}
  # Set alongside LAUNCH_CMD so the caller can say out loud that a path was
  # never run. A wrong flag here fails silently in the worst way: the session
  # starts, looks fine, and simply has no role -- and the docs table saying
  # "unverified" is not in front of anyone at that moment.
  TOOL_STATUS=verified

  tools_file_lookup "$tool" "$ctx" && return 0

  case "$tool" in
    claude)
      # Verified 2026-09-20 against Claude Code.
      LAUNCH_CMD=(claude --append-system-prompt-file "$ctx")
      ;;
    codex)
      # UNVERIFIED — codex was not installed when this was written.
      # If this is wrong, fix it here and say so in docs/tools.md.
      # shellcheck disable=SC2034  # global, read by the caller (bin/mdt's
      # cmd_start(), lib/doctor.sh's doctor_probe()) after this returns.
      TOOL_STATUS=unverified
      LAUNCH_CMD=(codex --prompt-file "$ctx")
      ;;
    *)
      LAUNCH_CMD=()
      return 1
      ;;
  esac
}
