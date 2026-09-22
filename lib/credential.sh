#!/usr/bin/env bash
# Named credentials (issue #5): TENDER_CREDENTIAL=<label> selects an entry an
# app already wrote to the OS keychain and gets it into the started agent's
# *environment* -- never into any process's argv, where `ps` could read it
# for as long as that process lives. See tests/test_credential.sh for the
# `ps -o args` proof this file exists to satisfy.
#
# Dual-purpose on purpose, not two files -- one new lib/ file, per the
# 450-line ceiling (CONTRIBUTING.md):
#
#   - Sourced by bin/tender, unconditionally, next to lib/tabs.sh and
#     lib/tools.sh: cmd_start() calls credential_available() on every run,
#     before tmux exists in the picture, so a missing or unreadable
#     credential aborts the start with a clear message rather than launching
#     an agent that quietly authenticates as someone else.
#   - Exec'd directly, by bash rather than sourced, as the innermost layer of
#     the pane wrapper cmd_start() hands to tmux (see
#     credential_wrapper_argv()) -- the one place the lookup is allowed to
#     touch the keychain a second time, from inside the new pane's own
#     process, at the moment the agent actually starts. See
#     credential_export_or_die()'s own header for why it re-checks rather
#     than trusting what tender's process already saw.
#
# The guard at the bottom tells the two modes apart.
#
# Needs from bin/tender: nothing at source time.
# Provides to it:      valid_credential_label(), credential_available(),
#                       credential_wrapper_argv() and reviewer_token_wrap()
#                       (both set LAUNCH_CMD), credential_record(); and to
#                       lib/manage.sh's restart, credential_recorded() and
#                       reviewer_token_wrap()
#
# Storage contract (agreed in issue #5 -- the app writes what this reads):
#   keychain service: treetender-cred-<label>
#   account:          the environment variable name to export
#   password:         the value
# This file never names a variable it exports in advance -- it exports
# whatever account name the entry carries. Which variable a tool reads is
# the app's business, not this project's; see CONTRIBUTING.md, "Vendor
# neutrality is enforced, not just asked for".

credential_service_name() { printf 'treetender-cred-%s' "$1"; }

# The label ends up in a keychain service name (above) and, unavoidably, in
# the argv of the `security`/`secret-tool` calls below and of the wrapper
# script itself (see credential_wrapper_argv()) -- never in a value that
# reaches a shell's own parsing, since it is always passed as a separate
# argv word, but a keychain service name built from an unchecked label is
# still an injection surface into whatever reads *that* back later. Same
# shape as valid_role_name() in bin/tender: letters, digits, - and _, never
# starting with - (a leading dash could be read as an option by something
# further down the chain). Checked before every use, both here and again by
# credential_export_or_die(), which cannot assume the argv it was handed
# came from this file's own credential_wrapper_argv().
valid_credential_label() {
  case "$1" in
    ""|*[!A-Za-z0-9_-]*|-*) return 1 ;;
    *) return 0 ;;
  esac
}

# The account name the keychain hands back is not something this file
# generates -- it is whatever the app wrote. Reject anything that is not a
# plain shell identifier before it is ever used in `export NAME=value`
# rather than trusting it: this is the one place a hostile or corrupted
# keychain entry could otherwise inject something into the wrapper's own
# shell.
#
# A plain identifier is not yet a harmless one: an entry whose account is
# PATH, BASH_ENV or LD_PRELOAD would bend how the agent itself starts, and a
# readonly name (SHELLOPTS, UID) makes the export fail. Those are refused
# outright. The list names no vendor's variables -- only the shell's, the
# loader's and this project's own.
valid_credential_account() {
  case "$1" in
    ""|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
    PATH|HOME|IFS|ENV|SHELL|USER|LOGNAME|PWD|OLDPWD|TERM|TMPDIR|CDPATH) return 1 ;;
    BASH_*|BASHOPTS|SHELLOPTS|PS4|PROMPT_COMMAND|UID|EUID|PPID|GROUPS) return 1 ;;
    LD_*|DYLD_*|TMUX*|TENDER_*|RANDOM|SECONDS|LINENO) return 1 ;;
    *) return 0 ;;
  esac
}

# Which environment variable an entry at service $1 carries -- never the
# value. `security find-generic-password` without -w never touches the
# password stream at all, whether or not -g is also given (verified by
# hand: -g prints attributes to stdout and the password to *stderr*, -w
# alone or omitted never prints a password anywhere) -- so this only ever
# reads the "acct" attribute line.
credential_account_macos() {
  local out
  out=$(security find-generic-password -s "$1" 2>/dev/null) || return 1
  out=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*"acct"<blob>="\([^"]*\)"$/\1/p' | head -n1)
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Linux counterpart. `secret-tool search` splits its output: the secret goes
# to stdout, the `attribute.<name> = <value>` lines to *stderr* (g_printerr
# in libsecret's tool/secret-tool.c). So stderr is the one read here and
# stdout is thrown away -- the secret never enters this pipe at all, and
# nothing here is held where a trace (`bash -x`) would print it.
credential_account_linux() {
  local out
  out=$(secret-tool search --all service "$1" 2>&1 >/dev/null \
    | sed -n 's/^attribute\.account = \(.*\)$/\1/p')
  out=${out%%$'\n'*}
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Prints the account name for service $1 and returns 0, or returns 1 with
# nothing printed -- no entry, no tool installed, or an account attribute
# that doesn't pass valid_credential_account(). Tries macOS then Linux, the
# same order and the same "try the next one even if the first tool exists
# but the lookup itself failed" shape as reviewer_token_export() below.
credential_find_account() {
  local service=$1 account
  if command -v security >/dev/null 2>&1; then
    account=$(credential_account_macos "$service") && [ -n "$account" ] \
      && valid_credential_account "$account" && { printf '%s' "$account"; return 0; }
  fi
  if command -v secret-tool >/dev/null 2>&1; then
    account=$(credential_account_linux "$service") && [ -n "$account" ] \
      && valid_credential_account "$account" && { printf '%s' "$account"; return 0; }
  fi
  return 1
}

credential_value_macos() {
  security find-generic-password -s "$1" -a "$2" -w 2>/dev/null
}

credential_value_linux() {
  secret-tool lookup service "$1" account "$2" 2>/dev/null
}

# Prints the value for service $1 / account $2 and returns 0, or returns 1
# with nothing printed. This is the one call in this file whose *output* is
# the secret -- its own argv, on both platforms, never contains it; only
# the service and account names do, and neither is a secret.
credential_find_value() {
  local service=$1 account=$2
  if command -v security >/dev/null 2>&1; then
    credential_value_macos "$service" "$account" && return 0
  fi
  if command -v secret-tool >/dev/null 2>&1; then
    credential_value_linux "$service" "$account" && return 0
  fi
  return 1
}

# The pre-flight check cmd_start() runs in its own process, before tmux
# exists in the picture: label shaped right, an entry exists, it names a
# usable account, and the value it holds is non-empty. Deliberately does
# not leave the value anywhere a caller could read it back -- the point of
# this call is "can this be read", not "here is what it says"; the actual
# export happens later, inside the new pane, via credential_export_or_die().
#
# Counts the value's bytes instead of holding it: this runs in tender's own
# process, where a trace (`bash -x bin/tender ...`) would print any variable
# assigned here. Newlines are not counted -- `security -w` ends its output
# with one, so an empty password would otherwise count as one byte.
credential_available() {
  local label=$1 service account bytes
  valid_credential_label "$label" || return 1
  service=$(credential_service_name "$label")
  account=$(credential_find_account "$service") || return 1
  bytes=$(set -o pipefail; credential_find_value "$service" "$account" | tr -d '\n' | wc -c) || return 1
  [ "${bytes// /}" -gt 0 ]
}

# Sets LAUNCH_CMD to the argv that runs *this same file*, directly rather
# than sourced (see the guard at the bottom), ahead of $3.. -- so the lookup
# and export below happen inside the new pane's own process, and the actual
# agent command ($3..) only ever appears in argv with no credential
# anywhere near it. $1 (TENDER_HOME) and $2 (the label) both travel through
# this argv in plain sight; neither is a secret.
credential_wrapper_argv() {
  local tender_home=$1 label=$2
  shift 2
  # shellcheck disable=SC2034  # global, read by the caller (bin/tender's
  # cmd_start()) after this returns — not unused, just not read from this
  # file, same as lib/tabs.sh's own wrap_launch_command().
  LAUNCH_CMD=(bash "$tender_home/lib/credential.sh" "$label" "$@")
}

# Which label a worktree's session was started with -- the label, never the
# value -- because `tender restart` builds a new launch line long after
# TENDER_CREDENTIAL has left anyone's environment. Without it a restart would
# bring the agent back without its key, the one outcome issue #5 rules out.
#
# Kept outside the worktree on purpose: the agent works in there, and a
# `git clean -fdx` (which removes .agents/, excluded as it is) would
# otherwise delete the record and turn the next restart into one without a
# key. One file per worktree, named by a hash of its resolved path.
credential_record_file() {
  local wt dir hash
  wt=$(cd -P "$1" 2>/dev/null && pwd) || return 1
  dir="${TENDER_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/treetender}/credentials"
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$wt" | shasum -a 256)
  else
    hash=$(printf '%s' "$wt" | sha256sum)
  fi
  hash=${hash%% *}
  [ -n "$hash" ] || return 1
  printf '%s/%s' "$dir" "$hash"
}

# Called by cmd_start() only after tmux accepted the new window -- never on a
# dry run, never on a start that failed -- so the record always describes a
# session that really runs. A start without a credential removes it.
credential_record() {
  local wt=$1 label=$2 file previous
  file=$(credential_record_file "$wt") || return 1
  if [ -n "$label" ]; then
    mkdir -p "${file%/*}" && printf '%s\n' "$label" > "$file"
  elif [ -f "$file" ]; then
    # Another window of this worktree may still run with that key; from now
    # on a restart of it would come back without one. Said, not silent.
    previous=$(head -n 1 "$file")
    printf "tender: this worktree was last started with credential '%s' and this start has none -- a later restart of either window restores none\n" "$previous" >&2
    rm -f "$file"
  fi
}

# For `tender restart`: prints the recorded label (nothing if the session
# was started without one) and returns 0 -- or returns 1 with its own message
# when a label is recorded but unusable. Called before restart touches the
# running session, so a refusal leaves that session exactly as it was. Says
# which label it restores, so a surprising one is visible.
credential_recorded() {
  local file label
  file=$(credential_record_file "$1") || {
    printf 'tender: cannot tell whether %s was started with a credential -- not restarting without knowing\n' "$1" >&2
    return 1
  }
  [ -f "$file" ] || return 0
  label=$(head -n 1 "$file")
  if ! valid_credential_label "$label"; then
    printf 'tender: %s holds no valid credential label -- not restarting without it\n' "$file" >&2
    return 1
  fi
  if ! credential_available "$label"; then
    printf "tender: no readable credential named '%s' in the keychain -- this session was started with it, so it is not restarted without it. See docs/setup.md\n" "$label" >&2
    return 1
  fi
  printf "restoring credential '%s', as the session was started with it\n" "$label" >&2
  printf '%s' "$label"
}

# --- the reviewer token (issue #10) ----------------------------------------
# The reviewer's own hosting-account token, keychain service
# treetender-reviewer, exported as GH_TOKEN. Same route as a named credential
# -- looked up inside the pane, never in any argv -- but *soft*: the reviewer
# without a token still works in single-account mode (docs/setup.md, section
# 7), so a missing token warns and starts anyway, both here and in the pane.
REVIEWER_TOKEN_WARNING='tender: no reviewer token found — approvals will fail. See docs/setup.md'

# Whether an entry exists -- never its value. macOS: without -w, `security`
# prints attributes only. Linux: `secret-tool lookup` can only print the
# value, so its stdout goes straight to /dev/null, never into a variable a
# trace (`bash -x bin/tender ...`) could print.
reviewer_token_available() {
  if command -v security >/dev/null 2>&1; then
    security find-generic-password -s treetender-reviewer >/dev/null 2>&1 && return 0
  fi
  if command -v secret-tool >/dev/null 2>&1; then
    secret-tool lookup service treetender-reviewer >/dev/null 2>&1 && return 0
  fi
  return 1
}

# For cmd_start() and restart_window(): wraps LAUNCH_CMD ($2..) in this file's
# direct mode with --reviewer-token when an entry exists; otherwise warns and
# leaves it unwrapped. Called after credential_wrapper_argv(), so a named
# credential's own export runs later, inside, and wins over GH_TOKEN.
reviewer_token_wrap() {
  local tender_home=$1
  shift
  if reviewer_token_available; then
    # shellcheck disable=SC2034  # global, read by the caller -- see above
    LAUNCH_CMD=(bash "$tender_home/lib/credential.sh" --reviewer-token "$@")
  else
    printf '%s\n' "$REVIEWER_TOKEN_WARNING" >&2
  fi
}

# Direct mode only, inside the pane: the two lookups tender itself used to
# make, now in the pane's own process. Exports GH_TOKEN when non-empty; says
# the warning into the pane otherwise and returns 0 either way -- the caller
# execs the agent regardless.
reviewer_token_export() {
  local value=""
  if command -v security >/dev/null 2>&1; then
    value=$(security find-generic-password -s treetender-reviewer -w 2>/dev/null) || value=""
  fi
  if [ -z "$value" ] && command -v secret-tool >/dev/null 2>&1; then
    value=$(secret-tool lookup service treetender-reviewer 2>/dev/null) || value=""
  fi
  if [ -n "$value" ]; then
    export GH_TOKEN="$value"
  else
    printf '%s\n' "$REVIEWER_TOKEN_WARNING" >&2
  fi
  value=""
}

# The export-and-exec that only runs when this file is executed directly
# (see the guard below), never when it is sourced. $1 is the label; $2.. is
# the agent's own launch command, already fully resolved by cmd_start().
#
# Looks the credential up *again* rather than trusting whatever
# credential_available() saw a moment earlier: that call ran in tender's own
# process, a different process from this one, and closing that gap matters
# more than the extra keychain round trip costs -- an agent started without
# its key might silently authenticate as someone else, which is worse than
# a slower start. See issue #5, "Careful with".
credential_export_or_die() {
  local label=$1 service account value
  valid_credential_label "$label" || {
    printf 'tender: "%s" is not a credential label -- refusing to start without it.\n' "$label" >&2
    return 1
  }
  service=$(credential_service_name "$label")
  account=$(credential_find_account "$service") || {
    printf 'tender: no credential named "%s" in the keychain -- refusing to start without it. See docs/setup.md\n' "$label" >&2
    return 1
  }
  value=$(credential_find_value "$service" "$account") || {
    printf 'tender: credential "%s" is unreadable -- refusing to start without it. See docs/setup.md\n' "$label" >&2
    return 1
  }
  if [ -z "$value" ]; then
    printf 'tender: credential "%s" is empty -- refusing to start without it. See docs/setup.md\n' "$label" >&2
    value=""
    return 1
  fi
  # A name that passed valid_credential_account() can still refuse the
  # export; checked, so the agent never starts believing it has its key.
  if ! export "$account=$value" 2>/dev/null || [ "${!account-}" != "$value" ]; then
    printf 'tender: credential "%s" could not be put into the environment as %s -- refusing to start without it.\n' "$label" "$account" >&2
    value=""
    return 1
  fi
  value=""
}

# Tells the two modes apart: sourced (bin/tender, and this file's own tests,
# want only the functions above) versus executed directly (the pane wrapper
# cmd_start() builds via credential_wrapper_argv(), or with --reviewer-token
# via reviewer_token_wrap() -- never a label, which cannot start with -).
# Standard bash idiom -- BASH_SOURCE[0] is this file's own path either way;
# $0 only matches it when this file itself was the thing bash was told to run.
#
# Executed directly, this is the pane's own process: tracing is switched off
# first (an inherited `set -x` would print the value), and a refusal keeps
# the window open until someone has read why -- otherwise tmux closes the
# pane with the message the moment this exits, and on a restart the old
# agent is already gone by then. Only when a terminal is attached: the
# tests, which have none, get the exit status straight away.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  { set +x; } 2>/dev/null
  set -uo pipefail
  if [ "${1:-}" = --reviewer-token ]; then
    shift
    reviewer_token_export
    exec "$@"
  fi
  credential_label=${1:-}
  shift || true
  if ! credential_export_or_die "$credential_label"; then
    if [ -t 0 ]; then
      printf 'tender: this window stays open so the reason above can be read -- press Enter to close it.\n' >&2
      read -r _ || true
    fi
    exit 1
  fi
  exec "$@"
fi
