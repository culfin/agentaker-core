#!/usr/bin/env bash
# `wtc restart` against a stand-in, not a real coding agent — a real AI
# session is not a deterministic test subject (see .superpowers plan, task
# 16). The stand-ins below play the two roles restart has to cope with: one
# that responds to the handover phrase, and one that never does.
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
WTC="$PWD/bin/wtc"
make_sandbox
STUB=$(mktemp -d)

cleanup() {
  tmux kill-session -t wtc-demo >/dev/null 2>&1
  rm -rf "$SANDBOX" "$STUB"
}
trap cleanup EXIT

# --- stand-ins -------------------------------------------------------------

# Waits on input; writes .agents/handoff.md the moment a line contains the
# handover phrase, then exits. Playing the currently-running coding session.
cat > "$STUB/fake-agent-responsive.sh" <<'EOF'
#!/usr/bin/env bash
while IFS= read -r line; do
  case "$line" in
    *"hand over"*)
      mkdir -p "$PWD/.agents"
      printf 'Working on: pretend issue\nNext: nothing\n' > "$PWD/.agents/handoff.md"
      exit 0
      ;;
  esac
done
EOF
chmod +x "$STUB/fake-agent-responsive.sh"

# Reads and discards every line forever. Playing a wedged session that never
# answers.
cat > "$STUB/fake-agent-silent.sh" <<'EOF'
#!/usr/bin/env bash
while IFS= read -r line; do
  :
done
EOF
chmod +x "$STUB/fake-agent-silent.sh"

# Stands in for the real `claude` CLI on $PATH: launch_command() invokes it
# as `claude --append-system-prompt-file <ctx>` exactly as it would the real
# tool, so this exercises the genuine dispatch, not a substitute for it. It
# prints the assembled context so a test can see what restart actually
# passed to the successor, then sits — a real coding session doesn't exit
# either.
cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--append-system-prompt-file" ] && cat "$2"
sleep 300
EOF
chmod +x "$STUB/claude"
export PATH="$STUB:$PATH"

# A worktree in the shape cmd_start() leaves one in, without launching
# anything real — WTC_DRY_RUN (set by make_sandbox) keeps cmd_start from
# touching tmux or a real coding agent at all.
make_worktree() {
  "$WTC" demo developer "$1" >/dev/null 2>&1
}

# Starts the real tmux window a running session would have, cwd'd into the
# worktree, running $2 as the stand-in "currently running" process. Mirrors
# how tests/test_list_drop.sh fakes an open window for `wtc drop` to see.
open_window() {
  local suffix=$1 agent=$2
  local wt="$SANDBOX/demo/.worktrees/demo-developer-$suffix"
  if tmux has-session -t wtc-demo 2>/dev/null; then
    tmux new-window -t wtc-demo -c "$wt" -n "DEV·$suffix" "$agent"
  else
    tmux new-session -d -s wtc-demo -c "$wt" -n "DEV·$suffix" "$agent"
  fi
  tmux set-window-option -t "wtc-demo:DEV·$suffix" automatic-rename off
  tmux set-window-option -t "wtc-demo:DEV·$suffix" allow-rename off
}

echo "wtc restart: happy path — hand over, replace, carry the state forward"
make_worktree happy
open_window happy "$STUB/fake-agent-responsive.sh"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" restart demo DEV·happy 2>&1)
check "exits 0" "0" "$?"
contains "reports asking for a handover" "asking DEV·happy in demo to hand over" "$out"
contains "reports the handover arrived" "received a handover" "$out"
contains "reports the restart" "restarted DEV·happy in demo" "$out"
sleep 0.3
pane=$(tmux capture-pane -p -S - -t "wtc-demo:DEV·happy")
contains "the successor's context has the base rules" "Every role" "$pane"
contains "the successor's context has the role" "Role: developer" "$pane"
contains "the successor's context carries the handover section" "Handover from your predecessor" "$pane"
contains "... with the predecessor's actual content" "pretend issue" "$pane"
check "the window name survived" "DEV·happy" \
  "$(tmux display-message -p -t "wtc-demo:DEV·happy" '#{window_name}')"
check "the window index survived" "yes" \
  "$(tmux list-windows -t wtc-demo -F '#{window_name}' | grep -qxF 'DEV·happy' && echo yes || echo no)"
check "automatic-rename is still off (Task 15 held)" "off" \
  "$(tmux show-window-options -t "wtc-demo:DEV·happy" | awk '$1=="automatic-rename"{print $2}')"
check "allow-rename is still off" "off" \
  "$(tmux show-window-options -t "wtc-demo:DEV·happy" | awk '$1=="allow-rename"{print $2}')"
check "remain-on-exit was put back (not left on)" "off" \
  "$(tmux show-window-options -t "wtc-demo:DEV·happy" | awk '$1=="remain-on-exit"{print $2}')"

echo "wtc restart: --fresh replaces without asking, and does not wait"
make_worktree fresh
open_window fresh "$STUB/fake-agent-silent.sh"
# A handoff sitting on disk already, left over from some earlier attempt —
# --fresh must not pick it up either; the point of --fresh is to skip a
# handover entirely, not just to skip asking for a new one.
mkdir -p "$SANDBOX/demo/.worktrees/demo-developer-fresh/.agents"
printf 'Working on: a previous attempt, not this one\n' \
  > "$SANDBOX/demo/.worktrees/demo-developer-fresh/.agents/handoff.md"
start=$(date +%s)
out=$(WTC_HANDOFF_TIMEOUT=999 WTC_PROJECTS_DIR="$SANDBOX" "$WTC" restart demo DEV·fresh --fresh 2>&1)
rc=$?
elapsed=$(( $(date +%s) - start ))
check "exits 0" "0" "$rc"
lacks "never asks for a handover" "asking" "$out"
contains "says it's skipping the handover" "without a handover (--fresh)" "$out"
check "returns fast — did not sit through the 999s timeout" "yes" \
  "$([ "$elapsed" -lt 10 ] && echo yes || echo no)"
sleep 0.3
pane=$(tmux capture-pane -p -S - -t "wtc-demo:DEV·fresh")
contains "still gets the base rules" "Every role" "$pane"
lacks "carries no handover section" "Handover from your predecessor" "$pane"
lacks "and none of the stale handoff's content either" "a previous attempt" "$pane"

echo "wtc restart: a session that never responds is not restarted"
make_worktree timeout
open_window timeout "$STUB/fake-agent-silent.sh"
# A stale handoff already on disk, from some earlier attempt — must not be
# mistaken for a fresh answer, or a wedged session would look handed-over.
mkdir -p "$SANDBOX/demo/.worktrees/demo-developer-timeout/.agents"
printf 'STALE — should never be read as a real handover\n' \
  > "$SANDBOX/demo/.worktrees/demo-developer-timeout/.agents/handoff.md"
out=$(WTC_HANDOFF_TIMEOUT=2 WTC_PROJECTS_DIR="$SANDBOX" "$WTC" restart demo DEV·timeout 2>&1)
check "exits 1" "1" "$?"
# The exact phrase, not bare "DEV·timeout": that substring also appears in
# the separate --fresh suggestion below it, which would let this pass even
# if the timeout message itself never named the session.
contains "names the session that didn't respond, and where" "DEV·timeout in demo did not hand over" "$out"
contains "says its state would be lost" "state would be lost" "$out"
contains "names --fresh as the explicit way out" "wtc restart demo DEV·timeout --fresh" "$out"
check "the stale handoff was cleared, not reused" "no" \
  "$([ -e "$SANDBOX/demo/.worktrees/demo-developer-timeout/.agents/handoff.md" ] && echo yes || echo no)"
# A moment for a (wrongly) respawned pane's process to actually print, so the
# capture-pane checks below can't pass by racing a real respawn instead of
# proving one never happened.
sleep 0.3
check "the original process is still alive" "0" \
  "$(tmux display-message -p -t "wtc-demo:DEV·timeout" '#{pane_dead}')"
# pane_dead alone can't tell "still the original" from "replaced by another
# live process" — the claude stub is alive too. capture-pane can: the stub
# would have printed the context file (see the happy-path test), the silent
# stand-in never prints anything at all.
lacks "and it was never replaced — nothing was printed to the pane" "Every role" \
  "$(tmux capture-pane -p -S - -t "wtc-demo:DEV·timeout")"
check "remain-on-exit was put back after the abort" "off" \
  "$(tmux show-window-options -t "wtc-demo:DEV·timeout" | awk '$1=="remain-on-exit"{print $2}')"

echo "wtc restart: no running window — said so, nothing touched"
make_worktree missing
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" restart demo DEV·missing 2>&1)
check "exits 1" "1" "$?"
contains "says there's no running session" "no running session" "$out"

echo "wtc restart: an unknown label is explained, not confused with a missing window"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" restart demo NOSUCH 2>&1)
check "exits 1" "1" "$?"
contains "says the label wasn't found" "no worktree named" "$out"

echo "wtc restart: missing arguments print usage"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" restart demo 2>&1)
check "exits 2" "2" "$?"
contains "prints usage" "Usage:" "$out"

echo "wtc restart --all: skips a dirty worktree, restarts a clean one"
# --all has no repo argument — it sweeps every running window under
# PROJECTS_DIR, so the windows opened above have to be closed first, or
# they'd be swept into this count too (the happy/fresh ones are now running
# the claude stub, which never reads stdin — a handover request to either
# would just sit until WTC_HANDOFF_TIMEOUT).
tmux kill-window -t "wtc-demo:DEV·happy" 2>/dev/null
tmux kill-window -t "wtc-demo:DEV·fresh" 2>/dev/null
tmux kill-window -t "wtc-demo:DEV·timeout" 2>/dev/null
make_worktree allclean
open_window allclean "$STUB/fake-agent-responsive.sh"
make_worktree alldirty
open_window alldirty "$STUB/fake-agent-responsive.sh"
echo dirty > "$SANDBOX/demo/.worktrees/demo-developer-alldirty/dirty.txt"
out=$(WTC_PROJECTS_DIR="$SANDBOX" "$WTC" restart --all 2>&1)
# The exact phrase, not bare "DEV·alldirty": that substring also shows up in
# a success line ("restarted DEV·alldirty in demo") if the dirty check were
# ever bypassed, which would let this pass on the very failure it's there to
# catch.
contains "names the dirty one it skipped" "skipping DEV·alldirty in demo" "$out"
contains "says what to do about it" "commit or discard" "$out"
contains "restarted the clean one" "restarted DEV·allclean in demo" "$out"
contains "prints a summary line" "restarted 1, skipped 1" "$out"
rm -f "$SANDBOX/demo/.worktrees/demo-developer-alldirty/dirty.txt"

summary
