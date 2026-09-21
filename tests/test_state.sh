#!/usr/bin/env bash
# `.agents/state.md` — the facts tender collects itself before a restart, never
# from the session being replaced. The case the brief calls out as the one
# that matters most: gh is unreachable, and the file has to say so, not go
# blank or invent a row (see .superpowers/sdd/plan/handoff-fakten-brief.md).
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
TENDER="$PWD/bin/tender"
make_sandbox
STUB=$(mktemp -d)

cleanup() {
  tmux kill-session -t tender-demo >/dev/null 2>&1
  rm -rf "$SANDBOX" "$STUB"
}
trap cleanup EXIT

# A real (local, file-based) remote — collect_state()'s "commits ahead" and
# "claim held" both run real git against it, not a stub.
git init -q --bare "$SANDBOX/demo-remote.git"
git -C "$SANDBOX/demo" remote add origin "$SANDBOX/demo-remote.git"
git -C "$SANDBOX/demo" push -q origin main

# Exactly the padding state_line() in lib/state.sh uses — computed here, not
# retyped by eye, so a spacing assertion below can never drift from the
# implementation without the test noticing.
line_for() { printf '%-14s %s' "$1:" "$2"; }

# --- stand-ins, same shape as tests/test_restart.sh --------------------------

cat > "$STUB/fake-agent-responsive.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$PWD/.agents"
while IFS= read -r line; do
  case "$line" in
    *"hand over"*)
      printf 'Working on: pretend issue\n' > "$PWD/.agents/handoff.md"
      exit 0
      ;;
  esac
done
EOF
chmod +x "$STUB/fake-agent-responsive.sh"

# Never prints anything and never exits — playing the successor process
# restart_window() respawns into the pane. Nothing in this file reads pane
# output, so unlike tests/test_restart.sh's claude stub, this one doesn't
# need to cat the context file back out.
cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
sleep 300
EOF
chmod +x "$STUB/claude"
export PATH="$STUB:$PATH"

open_window() {
  local suffix=$1 agent=$2
  local wt="$SANDBOX/demo/.worktrees/demo-developer-$suffix"
  if tmux has-session -t tender-demo 2>/dev/null; then
    tmux new-window -t tender-demo -c "$wt" -n "DEV·$suffix" "$agent"
  else
    tmux new-session -d -s tender-demo -c "$wt" -n "DEV·$suffix" "$agent"
  fi
}

# Creates worktree $1, opens a window running the responsive stand-in,
# restarts it for real (through bin/tender, not by calling collect_state
# directly — this is the path a real restart takes), and prints the
# resulting .agents/state.md.
restart_and_read_state() {
  local suffix=$1
  "$TENDER" demo developer "$suffix" >/dev/null 2>&1
  open_window "$suffix" "$STUB/fake-agent-responsive.sh"
  TENDER_PROJECTS_DIR="$SANDBOX" "$TENDER" restart demo "DEV·$suffix" >/dev/null 2>&1
  cat "$SANDBOX/demo/.worktrees/demo-developer-$suffix/.agents/state.md" 2>/dev/null
}

# --- gh unreachable: the case the brief calls out as the important one ------

echo "collect_state: gh unreachable — 'could not ask', never blank or invented"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: authentication required" >&2
exit 1
EOF
chmod +x "$STUB/gh"

state=$(restart_and_read_state unreachable)
contains "heading is present" "State (collected by tender, not reported by the session)" "$state"
check "open PR says it could not ask" \
  "$(line_for "open PR" "could not ask: gh: authentication required")" \
  "$(printf '%s\n' "$state" | grep '^open PR:')"
check "claim held says it could not ask" \
  "$(line_for "claim held" "could not ask")" \
  "$(printf '%s\n' "$state" | grep '^claim held:')"
lacks "never claims an empty PR queue instead" "$(line_for "open PR" "none")" "$state"
lacks "never claims no claim instead" "$(line_for "claim held" "none")" "$state"

echo "tender restart: gh failing does not fail the restart itself"
# --fresh: the window is now running the claude stub from the restart above,
# which never answers a handover request — --fresh is what skips waiting for
# one, the same reasoning tests/test_restart.sh's --fresh case documents.
out=$(TENDER_PROJECTS_DIR="$SANDBOX" "$TENDER" restart demo DEV·unreachable --fresh 2>&1)
check "exits 0 even though gh cannot be asked" "0" "$?"
contains "still restarts" "restarted DEV·unreachable in demo" "$out"

# --- gh reachable, but genuinely nothing open --------------------------------

echo "collect_state: gh reachable, no open PR — an honest 'none', not silence"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*) printf '' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUB/gh"
state=$(restart_and_read_state none)
check "open PR is an explicit none" \
  "$(line_for "open PR" "none")" "$(printf '%s\n' "$state" | grep '^open PR:')"
check "claim held is an explicit none" \
  "$(line_for "claim held" "none")" "$(printf '%s\n' "$state" | grep '^claim held:')"

# --- gh reachable, a draft PR closing an issue, claim ref actually held -----

echo "collect_state: an open PR with a claim actually held"
# Build and push the claim exactly as roles/developer.md tells an agent to,
# and check both steps. A silent `push -q` here made a CI failure look like a
# lookup bug ("claim held: none") when the push itself was what went wrong —
# a test that cannot tell those two apart is only half a test.
claim_sha=$(printf 'claim test' | git -C "$SANDBOX/demo" hash-object -w --stdin 2>&1) \
  || { printf '  FAIL could not build the claim object\n       %s\n' "$claim_sha"; FAIL=$((FAIL + 1)); }
claim_push=$(git -C "$SANDBOX/demo" push origin "${claim_sha}:refs/claims/issue-42" 2>&1) \
  || { printf '  FAIL could not push the claim ref\n       %s\n' "$claim_push"; FAIL=$((FAIL + 1)); }
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*) printf '7\tfalse\tCloses #42, please review\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUB/gh"
state=$(restart_and_read_state found)
check "reports the PR number, that it's ready, and what it closes" \
  "$(line_for "open PR" "#7 (ready) — closes #42")" \
  "$(printf '%s\n' "$state" | grep '^open PR:')"
check "finds the claim actually held" \
  "$(line_for "claim held" "refs/claims/issue-42")" \
  "$(printf '%s\n' "$state" | grep '^claim held:')"
check "role comes from tender, not gh" \
  "$(line_for "role" "developer")" "$(printf '%s\n' "$state" | grep '^role:')"
check "worktree comes from the directory, not gh" \
  "$(line_for "worktree" "demo-developer-found")" \
  "$(printf '%s\n' "$state" | grep '^worktree:')"
check "branch comes from git, not gh" \
  "$(line_for "branch" "demo-developer-found")" \
  "$(printf '%s\n' "$state" | grep '^branch:')"

# --- ordering: facts land in context.md before the free-text handover -------

echo "the new session's context has facts before free text"
ctx=$(cat "$SANDBOX/demo/.worktrees/demo-developer-found/.agents/context.md")
contains "state section present" "## State (collected by tender" "$ctx"
contains "handover section present" "## Handover from your predecessor" "$ctx"
state_pos=${ctx%%"## State"*}
handover_pos=${ctx%%"## Handover from your predecessor"*}
check "state comes before the handover" "yes" \
  "$([ "${#state_pos}" -lt "${#handover_pos}" ] && echo yes || echo no)"

summary
