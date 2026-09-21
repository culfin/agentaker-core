#!/usr/bin/env bash
# Pins the tmux isolation in tests/lib.sh. It exists because on 2026-09-21 an
# experiment that "looked isolated" ran `tmux kill-server` against the real
# server and ended every session on it. If the isolation is ever removed or
# weakened, this file goes red instead of the next test run doing damage.
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh

echo "isolation: the shell a test runs in is not attached to any tmux"
check "TMUX is unset inside tests" "" "${TMUX:-}"

echo "isolation: every test file goes through tests/lib.sh"
# A test file that skips lib.sh skips the isolation with it.
missing=""
for t in tests/test_*.sh; do
  grep -q '^\. tests/lib\.sh' "$t" || missing="$missing $t"
done
check "no test file bypasses lib.sh" "" "$missing"

if command -v tmux >/dev/null 2>&1; then
  echo "isolation: tmux resolves to a private socket"
  contains "the probe found a socket" "/" "$TMUX_ISOLATED_SOCKET"
  case "$TMUX_ISOLATED_SOCKET" in
    "$TMUX_TMPDIR"/?*) check "that socket is under the private directory" "yes" "yes" ;;
    *) check "that socket is under the private directory" "yes" "no: $TMUX_ISOLATED_SOCKET" ;;
  esac

  echo "isolation: a session made here lands on the private server"
  tmux new-session -d -s isolation-check
  sock=$(tmux display-message -p -t isolation-check '#{socket_path}')
  check "a test's own session uses the verified socket" "$TMUX_ISOLATED_SOCKET" "$sock"
  tmux kill-session -t isolation-check 2>/dev/null
else
  echo "isolation: tmux not installed — nothing a test could reach"
fi

summary
