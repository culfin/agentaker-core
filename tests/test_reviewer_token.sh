#!/usr/bin/env bash
# The reviewer token (issue #10): keychain service treetender-reviewer has to
# reach the reviewer agent as GH_TOKEN without the value ever appearing in
# any tmux argv -- the same proof tests/test_credential.sh gives named
# credentials. Soft, unlike those: a missing token warns and starts anyway.
# Sections, in order:
#   1. Dry runs: who gets wrapped (reviewer only), the missing-token warning,
#      and the order when a named credential is also given.
#   2. lib/credential.sh --reviewer-token executed directly, without tmux.
#   3. Real starts on the private tmux server (tests/lib.sh): the token in the
#      agent's environment, in no tmux argv, a pre-check that never asked
#      for the value; restart; a token gone by the time the pane looks.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
TENDER="$PWD/bin/tender"
make_sandbox
STUB=$(mktemp -d)
trap 'tmux kill-session -t tender-demo >/dev/null 2>&1; rm -rf "$SANDBOX" "$STUB"' EXIT
# Whatever the developer's own shell carries must not stand in for the token
# under test -- nor reach the tmux server these tests start.
unset GH_TOKEN STUB_REVIEWER_PRESENT STUB_REVIEWER_TOKEN STUB_SERVICE STUB_ACCOUNT STUB_VALUE

# --- a stub `security`, never the real keychain -----------------------------
# Serves treetender-reviewer (attributes when STUB_REVIEWER_PRESENT is set,
# the value on -w when STUB_REVIEWER_TOKEN is) and one named credential, the
# way tests/test_credential.sh's stub does. Every call is logged with its own
# argv *and* its caller's, read while the caller is alive -- which tells
# tender's own pre-check apart from the pane's lookup.
cat > "$STUB/security" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s | caller: %s\n' "$*" "$(ps -ww -o args= -p "$PPID" 2>/dev/null)" >> "$SECURITY_LOG"
case "$*" in
  "find-generic-password -s treetender-reviewer -w")
    [ -n "${STUB_REVIEWER_TOKEN:-}" ] && { printf '%s\n' "$STUB_REVIEWER_TOKEN"; exit 0; }
    exit 44 ;;
  "find-generic-password -s treetender-reviewer")
    [ -n "${STUB_REVIEWER_PRESENT:-}" ] && { printf '    "acct"<blob>="someone"\n'; exit 0; }
    exit 44 ;;
  "find-generic-password -s "*" -a "*" -w")
    [ "$3" = "${STUB_SERVICE:-}" ] && [ -n "${STUB_VALUE:-}" ] && { printf '%s\n' "$STUB_VALUE"; exit 0; }
    exit 44 ;;
  "find-generic-password -s "*)
    [ "$3" = "${STUB_SERVICE:-}" ] && [ -n "${STUB_ACCOUNT:-}" ] && { printf '    "acct"<blob>="%s"\n' "$STUB_ACCOUNT"; exit 0; }
    exit 44 ;;
  *) exit 2 ;;
esac
STUBEOF
# No secret-tool on this PATH either way: one that exits 1 shadows a real one.
printf '#!/bin/sh\nexit 1\n' > "$STUB/secret-tool"
chmod +x "$STUB/security" "$STUB/secret-tool"
SAFE_PATH="$STUB:$PATH"
export SECURITY_LOG="$STUB/security.log"
TOKEN='ghp_TESTREVIEWER-should-never-appear-in-argv-7c21'
WARNING='no reviewer token found — approvals will fail. See docs/setup.md'
PANE_WARNING='could not be read here — starting without GH_TOKEN or GITHUB_TOKEN'

echo "reviewer token: a dry run wraps the reviewer, with no value anywhere"
: > "$SECURITY_LOG"
out=$(PATH="$SAFE_PATH" STUB_REVIEWER_PRESENT=1 STUB_REVIEWER_TOKEN="$TOKEN" "$TENDER" demo reviewer 2>&1)
check "exits 0" "0" "$?"
contains "the launch runs lib/credential.sh --reviewer-token" "lib/credential.sh --reviewer-token" "$out"
lacks "no warning when the entry exists" "$WARNING" "$out"
lacks "the dry run never carries the value" "$TOKEN" "$out"
contains "the pre-check asked the keychain (positive control)" "find-generic-password -s treetender-reviewer | caller" "$(cat "$SECURITY_LOG")"
lacks "the pre-check never asked for the value (-w)" "treetender-reviewer -w" "$(cat "$SECURITY_LOG")"

echo "reviewer token: missing — warns, starts anyway, unwrapped"
out=$(PATH="$SAFE_PATH" "$TENDER" demo reviewer 2>&1)
check "exits 0" "0" "$?"
contains "says the token is missing" "$WARNING" "$out"
contains "still launches" "would launch" "$out"
lacks "unwrapped" "--reviewer-token" "$out"

echo "reviewer token: other roles never wrap, and never ask"
for role in developer maintainer none; do
  : > "$SECURITY_LOG"
  out=$(PATH="$SAFE_PATH" STUB_REVIEWER_PRESENT=1 STUB_REVIEWER_TOKEN="$TOKEN" "$TENDER" demo "$role" 2>&1)
  lacks "$role is not wrapped" "--reviewer-token" "$out"
  lacks "$role never looks the reviewer token up" "treetender-reviewer" "$(cat "$SECURITY_LOG")"
done

echo "reviewer token: with a named credential, the reviewer wrapper is outside"
out=$(PATH="$SAFE_PATH" STUB_REVIEWER_PRESENT=1 STUB_REVIEWER_TOKEN="$TOKEN" \
  STUB_SERVICE=treetender-cred-work STUB_ACCOUNT=TESTVAR STUB_VALUE=named-value \
  TENDER_CREDENTIAL=work "$TENDER" demo reviewer 2>&1)
check "exits 0" "0" "$?"
contains "credential.sh --reviewer-token, then credential.sh work" \
  "lib/credential.sh --reviewer-token bash $PWD/lib/credential.sh work " "$out"

echo "reviewer token: lib/credential.sh --reviewer-token executed directly"
{
  MARKER="$STUB/direct.out"; rm -f "$MARKER"
  out=$(PATH="$SAFE_PATH" STUB_REVIEWER_TOKEN="$TOKEN" bash "$PWD/lib/credential.sh" --reviewer-token \
    bash -c 'printf "%s" "${GH_TOKEN:-<unset>}" > "$1"' -- "$MARKER" 2>&1)
  check "exits 0" "0" "$?"
  check "exports GH_TOKEN" "$TOKEN" "$(cat "$MARKER" 2>/dev/null)"
  lacks "says nothing of the value" "$TOKEN" "$out"
  rm -f "$MARKER"
  out=$(PATH="$SAFE_PATH" bash "$PWD/lib/credential.sh" --reviewer-token \
    bash -c 'printf "%s" "${GH_TOKEN:-<unset>}" > "$1"' -- "$MARKER" 2>&1)
  check "no token: still exits 0" "0" "$?"
  contains "no token: warns, and says it starts without GH_TOKEN" "$PANE_WARNING" "$out"
  check "no token: the command still ran, without GH_TOKEN" "<unset>" "$(cat "$MARKER" 2>/dev/null)"
  # Two-account mode: whatever the pane inherited is someone else's token.
  rm -f "$MARKER"
  GH_TOKEN=inherited GITHUB_TOKEN=inherited PATH="$SAFE_PATH" bash "$PWD/lib/credential.sh" --reviewer-token \
    bash -c 'printf "%s %s" "${GH_TOKEN:-<unset>}" "${GITHUB_TOKEN:-<unset>}" > "$1"' -- "$MARKER" >/dev/null 2>&1
  check "no token: an inherited GH_TOKEN and GITHUB_TOKEN are cleared" "<unset> <unset>" "$(cat "$MARKER" 2>/dev/null)"
  trace=$(PATH="$SAFE_PATH" STUB_REVIEWER_TOKEN="$TOKEN" bash -x "$PWD/lib/credential.sh" --reviewer-token true 2>&1)
  lacks "an inherited bash -x never prints the value" "$TOKEN" "$trace"
}

echo "reviewer token: a real start — in the agent's environment, in no tmux argv"
if ! command -v tmux >/dev/null 2>&1; then
  echo "  skip (tmux not installed)"
else
  REAL_TMUX=$(command -v tmux)
  cat > "$STUB/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB/tmux.log"
exec "$REAL_TMUX" "\$@"
EOF
  chmod +x "$STUB/tmux"
  cat > "$STUB/agent-stub" <<EOF
#!/usr/bin/env bash
ps -ww -o args= -p "\$\$" > "$STUB/argv.txt"
printf '%s' "\${GITHUB_TOKEN:-<unset>}" > "$STUB/github-token.txt"
printf '%s %s' "\${GH_TOKEN:-<unset>}" "\${TESTVAR:-<unset>}" > "$STUB/env.txt"
sleep 20
EOF
  chmod +x "$STUB/agent-stub"
  TOOLS="$STUB/tools"
  printf 'agentstub  %s {context}  verified:2026-09-22\n' "$STUB/agent-stub" > "$TOOLS"
  wait_for() { local i=0; while [ ! -s "$1" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done; }
  reset_logs() { rm -f "$STUB/argv.txt" "$STUB/env.txt" "$STUB/github-token.txt" "$STUB/tmux.log"; : > "$SECURITY_LOG"; }
  run_tender() {
    PATH="$SAFE_PATH" TENDER_TOOLS_FILE="$TOOLS" TENDER_TOOL=agentstub TENDER_DRY_RUN="" \
      "$TENDER" "$@" </dev/null >"$STUB/out.txt" 2>&1
  }
  tmux kill-session -t tender-demo >/dev/null 2>&1

  reset_logs
  STUB_REVIEWER_PRESENT=1 STUB_REVIEWER_TOKEN="$TOKEN" run_tender demo reviewer
  check "exits 0" "0" "$?"
  wait_for "$STUB/env.txt"
  check "the agent has GH_TOKEN (positive control)" "$TOKEN <unset>" "$(cat "$STUB/env.txt" 2>/dev/null)"
  contains "the tmux shim saw the start (positive control)" "new-session" "$(cat "$STUB/tmux.log" 2>/dev/null)"
  lacks "no tmux argv carries the token" "$TOKEN" "$(cat "$STUB/tmux.log" 2>/dev/null)"
  lacks "no tmux argv sets GH_TOKEN at all" "GH_TOKEN" "$(cat "$STUB/tmux.log" 2>/dev/null)"
  lacks "the agent's live argv never carries the token" "$TOKEN" "$(cat "$STUB/argv.txt" 2>/dev/null)"
  lacks "tender's own output never carries it" "$TOKEN" "$(cat "$STUB/out.txt")"
  sec=$(cat "$SECURITY_LOG")
  contains "tender's pre-check asked, attributes only (positive control)" \
    "find-generic-password -s treetender-reviewer | caller: " "$sec"
  lacks "tender's own process never ran -w" "treetender-reviewer -w" \
    "$(grep -v 'credential.sh --reviewer-token' "$SECURITY_LOG")"
  contains "the value was read inside the pane, by credential.sh" \
    "treetender-reviewer -w | caller: bash $PWD/lib/credential.sh --reviewer-token" "$sec"
  lacks "no lookup's caller carried the token" "$TOKEN" "$sec"

  echo "reviewer token: restart puts it back the same way"
  reset_logs
  STUB_REVIEWER_PRESENT=1 STUB_REVIEWER_TOKEN="$TOKEN" run_tender restart demo REV --fresh
  check "exits 0" "0" "$?"
  wait_for "$STUB/env.txt"
  check "the restarted agent has GH_TOKEN" "$TOKEN <unset>" "$(cat "$STUB/env.txt" 2>/dev/null)"
  contains "the tmux shim saw the respawn (positive control)" "respawn-pane" "$(cat "$STUB/tmux.log" 2>/dev/null)"
  lacks "no restart tmux argv carries the token" "$TOKEN" "$(cat "$STUB/tmux.log" 2>/dev/null)"
  lacks "restart's pre-check never ran -w in tender's process" "treetender-reviewer -w" \
    "$(grep -v 'credential.sh --reviewer-token' "$SECURITY_LOG")"

  echo "reviewer token: restart without a token warns and restarts anyway"
  reset_logs
  run_tender restart demo REV --fresh
  check "exits 0" "0" "$?"
  contains "says the token is missing" "$WARNING" "$(cat "$STUB/out.txt")"
  wait_for "$STUB/env.txt"
  # The pane's server still carries the stub's token from the first start;
  # unwrapped, the pane never looks it up, so GH_TOKEN stays unset.
  check "the agent restarted, without GH_TOKEN" "<unset> <unset>" "$(cat "$STUB/env.txt" 2>/dev/null)"
  tmux kill-session -t tender-demo >/dev/null 2>&1

  echo "reviewer token: present at the pre-check, gone in the pane — warns there, starts anyway, clears inherited tokens"
  # The session's own environment (-e) has an entry without a readable
  # value; tender's pre-check, in the test's environment, sees one. The
  # server itself is started with GH_TOKEN/GITHUB_TOKEN set, standing in for
  # the developer's own login that a two-account reviewer must not act under.
  GH_TOKEN=inherited GITHUB_TOKEN=inherited tmux new-session -d -s tender-demo -n holder \
    -e "PATH=$SAFE_PATH" -e "SECURITY_LOG=$SECURITY_LOG" \
    -e STUB_REVIEWER_PRESENT=1 -e STUB_REVIEWER_TOKEN= "sleep 300"
  reset_logs
  run_tender demo developer
  wait_for "$STUB/env.txt"
  check "an unwrapped window there inherits GH_TOKEN (positive control)" "inherited <unset>" "$(cat "$STUB/env.txt" 2>/dev/null)"
  check "... and GITHUB_TOKEN (positive control)" "inherited" "$(cat "$STUB/github-token.txt" 2>/dev/null)"
  reset_logs
  STUB_REVIEWER_PRESENT=1 STUB_REVIEWER_TOKEN="$TOKEN" run_tender demo reviewer
  check "exits 0" "0" "$?"
  wait_for "$STUB/env.txt"
  check "the agent started, without GH_TOKEN" "<unset> <unset>" "$(cat "$STUB/env.txt" 2>/dev/null)"
  check "... and without GITHUB_TOKEN" "<unset>" "$(cat "$STUB/github-token.txt" 2>/dev/null)"
  contains "the pane shows the warning, naming both" "$PANE_WARNING" "$(tmux capture-pane -p -J -t tender-demo:REV 2>/dev/null)"
  tmux kill-session -t tender-demo >/dev/null 2>&1

  echo "reviewer token: with a named credential — both arrive; the named one wins GH_TOKEN"
  reset_logs
  STUB_REVIEWER_PRESENT=1 STUB_REVIEWER_TOKEN="$TOKEN" STUB_SERVICE=treetender-cred-work \
    STUB_ACCOUNT=TESTVAR STUB_VALUE=named-value TENDER_CREDENTIAL=work run_tender demo reviewer
  check "exits 0" "0" "$?"
  wait_for "$STUB/env.txt"
  check "the agent has both" "$TOKEN named-value" "$(cat "$STUB/env.txt" 2>/dev/null)"
  lacks "no tmux argv carries either" "$TOKEN" "$(cat "$STUB/tmux.log" 2>/dev/null)"
  tmux kill-session -t tender-demo >/dev/null 2>&1
  reset_logs
  STUB_REVIEWER_PRESENT=1 STUB_REVIEWER_TOKEN="$TOKEN" STUB_SERVICE=treetender-cred-work \
    STUB_ACCOUNT=GH_TOKEN STUB_VALUE=named-gh-token TENDER_CREDENTIAL=work run_tender demo reviewer
  wait_for "$STUB/env.txt"
  check "a named credential whose account is GH_TOKEN wins" "named-gh-token <unset>" "$(cat "$STUB/env.txt" 2>/dev/null)"
  tmux kill-session -t tender-demo >/dev/null 2>&1

  echo "reviewer token: a developer joining a session the reviewer created gets no GH_TOKEN"
  # The regression the old `tmux new-session -e GH_TOKEN=...` had: -e on
  # new-session sets the *session's* environment, so every later window in
  # it -- the developer's included -- inherited the reviewer's token.
  reset_logs
  STUB_REVIEWER_PRESENT=1 STUB_REVIEWER_TOKEN="$TOKEN" run_tender demo reviewer
  wait_for "$STUB/env.txt"
  check "the reviewer created the session, with its token (positive control)" "$TOKEN <unset>" "$(cat "$STUB/env.txt" 2>/dev/null)"
  reset_logs
  STUB_REVIEWER_PRESENT=1 STUB_REVIEWER_TOKEN="$TOKEN" run_tender demo developer
  wait_for "$STUB/env.txt"
  contains "the developer joined via new-window (positive control)" "new-window" "$(cat "$STUB/tmux.log" 2>/dev/null)"
  check "the developer agent has no GH_TOKEN" "<unset> <unset>" "$(cat "$STUB/env.txt" 2>/dev/null)"
  lacks "the session environment holds no GH_TOKEN" "GH_TOKEN=" "$(tmux show-environment -t tender-demo 2>/dev/null)"
  tmux kill-session -t tender-demo >/dev/null 2>&1

  echo "reviewer token: the Linux branch (no security, secret-tool only)"
  # A PATH on which `security` does not exist at all -- this machine's real
  # one and tests/lib.sh's stand-in both shadowed out, like test_throttle.sh
  # shadows gh -- and a logging secret-tool that holds the token.
  LINUX=$(mktemp -d)
  mkdir -p "$LINUX/stub"
  cat > "$LINUX/stub/secret-tool" <<'LEOF'
#!/usr/bin/env bash
printf '%s | caller: %s\n' "$*" "$(ps -ww -o args= -p "$PPID" 2>/dev/null)" >> "$SECRET_TOOL_LOG"
case "$*" in
  "lookup service treetender-reviewer")
    [ -n "${STUB_LINUX_TOKEN:-}" ] && { printf '%s' "$STUB_LINUX_TOKEN"; exit 0; }
    exit 1 ;;
  *) exit 1 ;;
esac
LEOF
  chmod +x "$LINUX/stub/secret-tool"
  cp "$STUB/tmux" "$LINUX/stub/tmux"
  LINUX_PATH="$LINUX/stub"
  IFS=':' read -ra path_dirs <<< "$PATH"
  for dir in "${path_dirs[@]}"; do
    [ "$dir" = "$STUB" ] && continue
    if [ -x "$dir/security" ] || [ -x "$dir/secret-tool" ]; then
      shadow="$LINUX/${dir//\//_}"
      mkdir -p "$shadow"
      for entry in "$dir"/*; do
        case "$(basename "$entry")" in security|secret-tool) continue ;; esac
        ln -s "$entry" "$shadow/$(basename "$entry")" 2>/dev/null
      done
      LINUX_PATH="$LINUX_PATH:$shadow"
    else
      LINUX_PATH="$LINUX_PATH:$dir"
    fi
  done
  export SECRET_TOOL_LOG="$LINUX/secret-tool.log"
  check "no security on that PATH (setup)" "" "$(PATH="$LINUX_PATH" command -v security)"
  : > "$SECRET_TOOL_LOG"
  out=$(PATH="$LINUX_PATH" STUB_LINUX_TOKEN="$TOKEN" "$TENDER" demo reviewer 2>&1)
  contains "the pre-check finds the entry and wraps" "lib/credential.sh --reviewer-token" "$out"
  lacks "tender's output never carries the value" "$TOKEN" "$out"
  contains "the pre-check asked secret-tool (positive control)" "lookup service treetender-reviewer | caller: " "$(cat "$SECRET_TOOL_LOG")"
  trace=$(PATH="$LINUX_PATH" STUB_LINUX_TOKEN="$TOKEN" bash -x "$TENDER" demo reviewer 2>&1)
  contains "the trace shows the pre-check ran (positive control)" "secret-tool lookup service treetender-reviewer" "$trace"
  lacks "a bash -x trace of tender never shows the value — its stdout was not captured" "$TOKEN" "$trace"
  reset_logs
  PATH="$LINUX_PATH" STUB_LINUX_TOKEN="$TOKEN" TENDER_TOOLS_FILE="$TOOLS" TENDER_TOOL=agentstub TENDER_DRY_RUN="" \
    "$TENDER" demo reviewer </dev/null >"$STUB/out.txt" 2>&1
  check "a real start exits 0" "0" "$?"
  wait_for "$STUB/env.txt"
  check "the pane exported GH_TOKEN from secret-tool" "$TOKEN <unset>" "$(cat "$STUB/env.txt" 2>/dev/null)"
  contains "... read inside the pane, by credential.sh" "caller: bash $PWD/lib/credential.sh --reviewer-token" "$(cat "$SECRET_TOOL_LOG")"
  lacks "no tmux argv carries it" "$TOKEN" "$(cat "$STUB/tmux.log" 2>/dev/null)"
  tmux kill-session -t tender-demo >/dev/null 2>&1
  rm -rf "$LINUX"
fi

summary
