#!/usr/bin/env bash
# `mdt doctor` — the hand-check that verified Claude Code on 2026-09-20
# (docs/tools.md), as a command anyone can run against their own tool: start
# it with a throwaway context asking it to name itself, and report whether
# the answer arrived.
#
# Sourced by bin/mdt on demand, the same as lib/init.sh and lib/manage.sh:
# `doctor` is not on the everyday `mdt <repo> <role>` path.
#
# Needs from bin/mdt: die(), launch_command(), TOOL
# Needs from lib/tools.sh (already sourced unconditionally): tools_known_names()
# Provides to it:     cmd_doctor()

DOCTOR_MARKER='MDT-DOCTOR-OK'

# Runs $3.. with stdin closed and its combined output captured to $2, for at
# most $1 seconds. Whole-second polling — the same style wait_for_handoff()
# in lib/manage.sh uses, where the timeout is a safety margin, not a
# precision instrument, and no fractional-second `sleep` that isn't portable
# to every `sleep(1)` mdt already has to run under. Returns the command's own
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
  local tool=$1 timeout=${MDT_DOCTOR_TIMEOUT:-15}
  local tmp
  tmp=$(mktemp -d) || { printf '  could not create a scratch directory\n'; return 1; }
  # shellcheck disable=SC2064  # $tmp is fixed now, on purpose — not
  # re-evaluated at trap time, when it would no longer be in scope.
  trap "rm -rf '$tmp'" RETURN

  local ctx="$tmp/context.md"
  cat > "$ctx" <<EOF
# mandate doctor check

This is a throwaway diagnostic context, not a real project — nothing you do
here is kept or seen by anyone. Before waiting for anything else, print
exactly this line and then stop:

$DOCTOR_MARKER
EOF

  local prior_tool=${TOOL:-}
  TOOL=$tool
  LAUNCH_CMD=()
  # shellcheck disable=SC2034  # reset before the call, same as cmd_start()
  # in bin/mdt — launch_command() always overwrites it, this just keeps a
  # stale value from a previous doctor_probe() call in this same loop from
  # ever being visible if that ever changed.
  TOOL_STATUS=verified
  local known=0
  launch_command "$ctx" && known=1
  TOOL=$prior_tool
  if [ "$known" -eq 0 ]; then
    printf '  no launch command known for this tool\n'
    return 1
  fi

  command -v "${LAUNCH_CMD[0]}" >/dev/null 2>&1 || {
    printf '  not installed (%s not on PATH)\n' "${LAUNCH_CMD[0]}"
    return 1
  }

  local out="$tmp/output" rc
  ( cd "$tmp" && run_with_timeout "$timeout" "$out" "${LAUNCH_CMD[@]}" )
  rc=$?

  if [ "$rc" -eq 124 ]; then
    printf '  no response in %ss\n' "$timeout"
    return 1
  fi
  if grep -qF "$DOCTOR_MARKER" "$out" 2>/dev/null; then
    printf '  role arrived\n'
    return 0
  fi
  printf '  started (exit %s) but the role never arrived — see docs/tools.md\n' "$rc"
  return 1
}

# `mdt doctor` (no argument): every tool mdt currently knows how to start —
# the built-ins plus the tools file. `mdt doctor <tool>`: only that one, and
# it has to be a name mdt actually knows, or this says so and stops, the same
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
