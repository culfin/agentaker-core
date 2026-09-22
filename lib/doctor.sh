#!/usr/bin/env bash
# `atk doctor` — the hand-check that verified Claude Code on 2026-09-20
# (docs/tools.md), as a command anyone can run against their own tool: start
# it with a throwaway context asking it to name itself, and report whether
# the answer arrived.
#
# Sourced by bin/atk on demand, the same as lib/init.sh and lib/manage.sh:
# `doctor` is not on the everyday `atk <repo> <role>` path.
#
# Needs from bin/atk: die(), launch_command(), TOOL
# Needs from lib/tools.sh (already sourced unconditionally): tools_known_names()
# Provides to it:     cmd_doctor()

DOCTOR_MARKER='ATK-DOCTOR-OK'

# Every gap doctor reports says who can close it and how (issue #9): a
# `fixable:` line when atk can close it itself, `human:` when only a person
# at this machine can — then always an `action:` line naming the exact next
# step. One helper, so no path can print the one without the other. Nothing
# is `fixable:` yet: there is no `--fix`, and nothing doctor finds is
# something atk could safely repair on its own.
doctor_gap() {
  printf '  %s: %s\n  action: %s\n' "$1" "$2" "$3"
}

# Runs $3.. with stdin closed and its combined output captured to $2, for at
# most $1 seconds. Whole-second polling — the same style wait_for_handoff()
# in lib/manage.sh uses, where the timeout is a safety margin, not a
# precision instrument, and no fractional-second `sleep` that isn't portable
# to every `sleep(1)` atk already has to run under. Returns the command's own
# exit status, or 124 (the same code GNU timeout(1) uses) once it has to be
# killed rather than waited for.
run_with_timeout() {
  local timeout=$1 outfile=$2
  shift 2
  "$@" </dev/null >"$outfile" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$timeout" ]; then
      kill "$pid" 2>/dev/null
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# One tool, one probe. Never touches a real project: its own mktemp -d, its
# own context file, both gone before this returns — the trap fires on return,
# not just on a clean one, so a probe that dies partway still cleans up.
#
# What this cannot fully verify: the two-point contract (docs/tools.md) says
# a tool must accept a system prompt from a file, not that it must act on an
# instruction in that file before anything else — a tool that only speaks
# after a first interactive message will report "no response" here even
# though it works fine by hand in a real tmux window. That is a limit of
# probing without a TTY or a way to ask a question, not a bug in the tool;
# see docs/tools.md.
doctor_probe() {
  local tool=$1 timeout=${ATK_DOCTOR_TIMEOUT:-15}
  local tmp
  tmp=$(mktemp -d) || {
    doctor_gap human "could not create a scratch directory" \
      "check that ${TMPDIR:-/tmp} exists and is writable, then run: atk doctor $tool"
    return 1
  }
  # shellcheck disable=SC2064  # $tmp is fixed now, on purpose — not
  # re-evaluated at trap time, when it would no longer be in scope.
  trap "rm -rf '$tmp'" RETURN

  local ctx="$tmp/context.md"
  cat > "$ctx" <<EOF
# agentaker doctor check

This is a throwaway diagnostic context, not a real project — nothing you do
here is kept or seen by anyone. Before waiting for anything else, print
exactly this line and then stop:

$DOCTOR_MARKER
EOF

  local prior_tool=${TOOL:-}
  TOOL=$tool
  LAUNCH_CMD=()
  # shellcheck disable=SC2034  # reset before the call, same as cmd_start()
  # in bin/atk — launch_command() always overwrites it, this just keeps a
  # stale value from a previous doctor_probe() call in this same loop from
  # ever being visible if that ever changed.
  TOOL_STATUS=verified
  local known=0 from_file=0
  # Whether the tools file has a line for it — decides where the fix goes if
  # the role never arrives. A subshell, so the lookup's own LAUNCH_CMD and
  # messages stay out of this one.
  ( tools_file_lookup "$tool" "$ctx" ) >/dev/null 2>&1 && from_file=1
  launch_command "$ctx" && known=1
  TOOL=$prior_tool
  if [ "$known" -eq 0 ]; then
    doctor_gap human "no launch command known for this tool" \
      "add a line for $tool to your tools file (${ATK_TOOLS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/agentaker/tools}) — see docs/tools.md"
    return 1
  fi

  command -v "${LAUNCH_CMD[0]}" >/dev/null 2>&1 || {
    doctor_gap human "not installed (${LAUNCH_CMD[0]} not on PATH)" \
      "install ${LAUNCH_CMD[0]}, or put its directory on PATH, then run: atk doctor $tool"
    return 1
  }

  local out="$tmp/output" rc
  ( cd "$tmp" && run_with_timeout "$timeout" "$out" "${LAUNCH_CMD[@]}" )
  rc=$?

  if [ "$rc" -eq 124 ]; then
    # Neither a pass nor a failure: a tool that only speaks after a first
    # message looks exactly like this (see the header above).
    doctor_gap human "could not confirm automatically — no response in ${timeout}s" \
      "start it in a real session (ATK_TOOL=$tool atk <repo> <role>) and check it names its role; or allow more time: ATK_DOCTOR_TIMEOUT=60 atk doctor $tool"
    return 1
  fi
  if grep -qF "$DOCTOR_MARKER" "$out" 2>/dev/null; then
    printf '  role arrived\n'
    return 0
  fi
  local where="$tool's line in your tools file"
  [ "$from_file" -eq 1 ] \
    || where="$tool's built-in launch line in lib/tools.sh — or override it with a line in your tools file"
  doctor_gap human "started (exit $rc) but the role never arrived" \
    "check $where: {context} must reach the option that takes a system prompt from a file — see docs/tools.md"
  return 1
}

# `atk doctor` (no argument): every tool atk currently knows how to start —
# the built-ins plus the tools file. `atk doctor <tool>`: only that one, and
# it has to be a name atk actually knows, or this says so and stops, the same
# as launch_command() itself would at real launch time.
cmd_doctor() {
  local requested=${1:-}
  local -a names=()

  if [ -n "$requested" ]; then
    local n known=0
    while IFS= read -r n; do
      [ "$n" = "$requested" ] && known=1
    done < <(tools_known_names)
    [ "$known" -eq 1 ] \
      || die "no launch command known for tool '$requested' — see docs/tools.md"
    names=("$requested")
  else
    local n
    while IFS= read -r n; do
      names+=("$n")
    done < <(tools_known_names)
  fi

  local name rc=0
  for name in "${names[@]}"; do
    printf '%s:\n' "$name"
    doctor_probe "$name" || rc=1
  done
  return "$rc"
}
