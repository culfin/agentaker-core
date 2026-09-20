#!/usr/bin/env bash
# Tab and window legibility: the role tag, iTerm2 tab colour, and the pane
# wrapper that pins both before a coding agent's first paint.
#
# Split out of bin/mdt to keep it under the 450-line ceiling (see
# CONTRIBUTING.md) — not for on-demand loading like lib/init.sh and
# lib/manage.sh. role_tag() and wrap_launch_command() run on every
# cmd_start()/restart_window() call, in bin/mdt and lib/manage.sh alike, so
# bin/mdt sources this unconditionally, right after it resolves MDT_HOME.
#
# Needs from bin/mdt: nothing — every function here is self-contained.
# Provides to it:     role_tag(), wrap_launch_command() (sets LAUNCH_CMD)

# --- legible tabs --------------------------------------------------------
# A terminal tab shows one line and the user reads it at a glance: project,
# then who. Everything else is noise — the session name already carries
# "mdt", so repeating it costs characters and says nothing.
#
# developer -> DEV, reviewer -> REV, maintainer -> MNT, none -> ---, anything
# else -> its first three characters, uppercased. tr, not ${var^^}: bash 3.2
# (still /bin/bash on macOS) doesn't have the latter.
role_tag() {
  case "$1" in
    developer)  printf 'DEV' ;;
    reviewer)   printf 'REV' ;;
    maintainer) printf 'MNT' ;;
    # `printf --` and not bare `printf '---'`: bash's own printf builtin reads
    # a format string starting with `-` as an option and refuses it — found
    # by the test in tests/test_start.sh that runs this exact case, not by
    # reading the code.
    none)       printf -- '---' ;;
    *)          printf '%s' "$(printf '%.3s' "$1" | tr '[:lower:]' '[:upper:]')" ;;
  esac
}

# iTerm2's own tab-colour codes are proprietary, and only iTerm2 understands
# them — a stray escape sequence in a terminal that doesn't is worse than no
# colour, it prints garbage. Every mdt-launched pane runs inside tmux, so
# TERM_PROGRAM inside the pane is always "tmux" (tmux sets it itself); that
# check has to happen here, in mdt's own process, before tmux exists in the
# picture. iTerm2's tmux integration sets LC_TERMINAL for exactly this reason
# — it's the one signal that survives being wrapped in tmux.
iterm2_detected() {
  [ "${TERM_PROGRAM:-}" = "iTerm2" ] || [ "${LC_TERMINAL:-}" = "iTerm2" ]
}

tab_colour_rgb() {
  case "$1" in
    developer)  printf '0;122;255' ;;
    reviewer)   printf '255;204;0' ;;
    maintainer) printf '52;199;89' ;;
    *)          return 1 ;;
  esac
}

# One DCS-wrapped OSC 6 component (iTerm2's per-channel tab colour code).
# tmux's passthrough convention requires doubling any ESC embedded in the
# wrapped payload; each component command here carries exactly one (its own
# leading ESC), so the wrap is a single doubling. Three calls — red, green,
# blue — build the full colour; see tab_colour_sequence().
osc6_component() {
  printf '\033Ptmux;\033]6;1;bg;%s;brightness;%s\a\033\\' "$1" "$2"
}

# The full escape sequence for $1's tab colour, or nothing (rc 1) if the role
# has none. Emitting this is the caller's job — see wrap_launch_command(),
# which runs it from inside the new pane itself, not from here, so there is
# no race against the allow-passthrough option that has to be on first.
tab_colour_sequence() {
  local rgb r g b
  rgb=$(tab_colour_rgb "$1") || return 1
  IFS=';' read -r r g b <<EOF
$rgb
EOF
  printf '%s%s%s' "$(osc6_component red "$r")" "$(osc6_component green "$g")" "$(osc6_component blue "$b")"
}

# Wraps $2.. (a vendor launch command) so that, from inside the new pane
# itself, window options are pinned before the coding agent's first paint,
# and $1's tab colour is set alongside it. Sets the global LAUNCH_CMD.
#
# The window name survives only if two other actors are stopped from
# touching it — measured, not assumed: a coding agent that sets its own
# process/window title, on a stock tmux (automatic-rename defaults on), gets
# its own name back within moments of starting, silently, with no error
# anywhere. `allow-rename` (the program renaming itself via escape sequence)
# and `automatic-rename` (tmux's own rename-to-current-command) are two
# separate mechanisms; measured against a real coding-agent session,
# allow-rename was already off and the rename still happened —
# automatic-rename was the one responsible. Both are turned off anyway, since
# either could be the culprit on a different tmux config.
#
# This has to run from inside the pane itself, window-scoped via its own
# $TMUX_PANE, as its first act: a `tmux set-window-option` issued from mdt's
# own process, after creation, would race the pane's first automatic-rename
# evaluation. Measured with a stand-in command across 3 seconds of wall time:
# zero flicker once this runs before anything else does.
#
# Colour, right after, if the role has one, MDT_TAB_COLOUR hasn't disabled
# it, and this is iTerm2. It has to come from inside the pane to reach the
# terminal at all, and turning allow-passthrough on from inside — same
# $TMUX_PANE, window-scoped, never global — avoids the same race: a pane
# that starts emitting before the option is on.
#
# Used by both cmd_start() and cmd_restart() — a restarted pane needs exactly
# the same protection a freshly started one does, or this fix silently stops
# applying to it the moment the two drift apart.
wrap_launch_command() {
  local role=$1
  shift
  local colour_seq=""
  if [ "${MDT_TAB_COLOUR:-1}" != "0" ] && iterm2_detected; then
    colour_seq=$(tab_colour_sequence "$role") || colour_seq=""
  fi
  # shellcheck disable=SC2034  # global, read by the caller (bin/mdt's
  # cmd_start(), lib/manage.sh's restart_window()) after this returns — not
  # unused, just not read from this file, now that this lives apart from them.
  LAUNCH_CMD=(sh -c '
    tmux set-window-option -t "$TMUX_PANE" automatic-rename off 2>/dev/null
    tmux set-window-option -t "$TMUX_PANE" allow-rename off 2>/dev/null
    tmux set-option -t "$TMUX_PANE" allow-passthrough on 2>/dev/null
    printf "%s" "$1"
    shift
    exec "$@"
  ' mdt "$colour_seq" "$@")
}
