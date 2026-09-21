#!/usr/bin/env bash
# Named credentials (issue #5): TENDER_CREDENTIAL=<label> has to get a keychain
# entry into the started agent's environment without the value ever
# appearing in any process's argv. Sections, in order:
#   1. valid_credential_label() / valid_credential_account() — the identifier
#      checks, in isolation.
#   2. The macOS parsing helpers, against a stub `security` on PATH.
#   3. credential_available() — the pre-flight check cmd_start() runs.
#   4. lib/credential.sh executed directly — the pane wrapper's own
#      export-and-exec, in isolation from tmux.
#   5. cmd_start() end to end, via TENDER_DRY_RUN (unset behaviour, bad label,
#      missing credential, a dry run that never prints the value).
#   6. Records (kept outside the worktree, never written by a dry run), the
#      direct mode's refusals, and the Linux parser.
#   7. The argv proof against a real (non-dry-run) tmux session: every
#      `security` caller's argv logged while it is alive, every tmux call
#      logged through a shim, the agent's own argv — plus restart (same
#      checks, and a refusal that leaves the session alone) and a pane whose
#      own lookup fails, which must stay open with the reason.
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
TENDER="$PWD/bin/tender"
make_sandbox
STUB=$(mktemp -d)
trap 'tmux kill-session -t tender-demo >/dev/null 2>&1; rm -rf "$SANDBOX" "$STUB"' EXIT

echo "credential: valid_credential_label() — plain identifiers only"
{
  . "$PWD/lib/credential.sh"
  for ok in work client-x client_x Work1 A a1 x; do
    valid_credential_label "$ok"
    check "accepts '$ok'" "0" "$?"
  done
  for bad in "" "-work" "client x" "../etc" "work;id" 'work$(id)' "work'" '"work"' "-"; do
    valid_credential_label "$bad"
    check "rejects '$bad'" "1" "$?"
  done
  unset STUB_SERVICE STUB_ACCOUNT STUB_VALUE
}

echo "credential: valid_credential_account() — plain shell identifiers only"
{
  . "$PWD/lib/credential.sh"
  for ok in ANTHROPIC_API_KEY OPENAI_API_KEY _X a VAR1; do
    valid_credential_account "$ok"
    check "accepts '$ok'" "0" "$?"
  done
  for bad in "" "1VAR" "VAR NAME" "VAR-NAME" 'VAR;rm'; do
    valid_credential_account "$bad"
    check "rejects '$bad'" "1" "$?"
  done
  unset STUB_SERVICE STUB_ACCOUNT STUB_VALUE
}

# --- a stub `security`, standing in for the real macOS keychain tool -------
#
# Mirrors exactly the two calls lib/credential.sh makes: an account-only
# lookup (no -a, no -w) and a value lookup (-a <account> -w). Controlled by
# three env vars so each section below can point it at a different scenario
# without a new file. Logs every invocation's own argv to $STUB/security.log
# — used below to confirm the stub's own argv, not just this file's, never
# carries the secret either.
cat > "$STUB/security" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SECURITY_LOG"
# The caller's argv, read while the caller is still alive — checked from
# outside afterwards, a finished caller would show nothing and prove nothing.
ps -ww -o args= -p "$PPID" >> "$SECURITY_LOG.callers" 2>/dev/null
case "$*" in
  "find-generic-password -s "*" -a "*" -w")
    service=$3
    # STUB_EMPTY_OK: an entry whose password is empty — the real tool then
    # succeeds and prints just the newline it always appends.
    if [ "$service" = "$STUB_SERVICE" ] && [ -n "${STUB_EMPTY_OK:-}" ]; then
      printf '\n'
      exit 0
    fi
    if [ "$service" = "$STUB_SERVICE" ] && [ -n "${STUB_VALUE:-}" ]; then
      printf '%s\n' "$STUB_VALUE"
      exit 0
    fi
    exit 44
    ;;
  "find-generic-password -s "*)
    service=$3
    if [ "$service" = "$STUB_SERVICE" ] && [ -n "${STUB_ACCOUNT:-}" ]; then
      printf '    "acct"<blob>="%s"\n' "$STUB_ACCOUNT"
      exit 0
    fi
    exit 44
    ;;
  *) exit 2 ;;
esac
STUBEOF
chmod +x "$STUB/security"
# Prepended, not a restricted list: the stub always shadows a real `security`
# on PATH regardless of what follows, and section 6 below needs the real
# `tmux`, `git` and `bash` this machine actually has.
SAFE_PATH="$STUB:$PATH"
export SECURITY_LOG="$STUB/security.log"

echo "credential: the macOS attribute parser reads 'acct' and nothing else"
{
  . "$PWD/lib/credential.sh"
  : > "$SECURITY_LOG"
  export STUB_SERVICE="treetender-cred-work" STUB_ACCOUNT="ANTHROPIC_API_KEY" STUB_VALUE=""
  out=$(PATH="$SAFE_PATH" credential_account_macos "treetender-cred-work")
  check "reads the account name" "ANTHROPIC_API_KEY" "$out"
  out=$(PATH="$SAFE_PATH" credential_account_macos "treetender-cred-nosuch")
  check "an unknown service prints nothing" "" "$out"
  unset STUB_SERVICE STUB_ACCOUNT STUB_VALUE
}

echo "credential: the macOS value lookup returns exactly the password, no wrapping"
{
  . "$PWD/lib/credential.sh"
  : > "$SECURITY_LOG"
  export STUB_SERVICE="treetender-cred-work" STUB_ACCOUNT="ANTHROPIC_API_KEY" STUB_VALUE="sk-abc123"
  out=$(PATH="$SAFE_PATH" credential_value_macos "treetender-cred-work" "ANTHROPIC_API_KEY")
  check "reads the value" "sk-abc123" "$out"
  lacks "the lookup's own argv (logged by the stub) never carries the value" "sk-abc123" "$(cat "$SECURITY_LOG")"
  unset STUB_SERVICE STUB_ACCOUNT STUB_VALUE
}

echo "credential: credential_available() — the pre-flight check"
{
  . "$PWD/lib/credential.sh"
  : > "$SECURITY_LOG"
  export STUB_SERVICE="treetender-cred-work" STUB_ACCOUNT="ANTHROPIC_API_KEY" STUB_VALUE="sk-abc123"
  PATH="$SAFE_PATH" credential_available "work"
  check "a complete entry is available" "0" "$?"

  export STUB_SERVICE="treetender-cred-other"
  PATH="$SAFE_PATH" credential_available "work"
  check "a label with no matching service is not available" "1" "$?"
  export STUB_SERVICE="treetender-cred-work"

  PATH="$SAFE_PATH" credential_available "not a label"
  check "a malformed label is rejected before any lookup" "1" "$?"

  save_value=$STUB_VALUE
  export STUB_VALUE=""
  PATH="$SAFE_PATH" credential_available "work"
  check "an entry the lookup cannot read is not available" "1" "$?"
  export STUB_VALUE=$save_value

  STUB_EMPTY_OK=1 PATH="$SAFE_PATH" credential_available "work"
  check "an entry with an empty password is not available (lookup succeeds, prints only a newline)" "1" "$?"

  save_account=$STUB_ACCOUNT
  export STUB_ACCOUNT="1NOTANIDENTIFIER"
  PATH="$SAFE_PATH" credential_available "work"
  check "an account attribute that is not a valid identifier is rejected" "1" "$?"
  export STUB_ACCOUNT=$save_account
  unset STUB_SERVICE STUB_ACCOUNT STUB_VALUE
}

echo "credential: lib/credential.sh executed directly — export then exec"
{
  export STUB_SERVICE="treetender-cred-work" STUB_ACCOUNT="TESTVAR" STUB_VALUE="sk-direct-exec"
  : > "$SECURITY_LOG"
  MARKER="$STUB/direct-exec-ran"
  rm -f "$MARKER"
  out=$(PATH="$SAFE_PATH" bash "$PWD/lib/credential.sh" work \
    bash -c 'printf "%s" "$TESTVAR" > "$1"' -- "$MARKER" 2>&1)
  check "exits 0" "0" "$?"
  check "the agent's own env carried the value" "sk-direct-exec" "$(cat "$MARKER" 2>/dev/null)"

  rm -f "$MARKER"
  export STUB_SERVICE="treetender-cred-nomatch"
  out=$(PATH="$SAFE_PATH" bash "$PWD/lib/credential.sh" work \
    bash -c 'printf "%s" "$TESTVAR" > "$1"' -- "$MARKER" 2>&1)
  rc=$?
  check "a missing entry exits 1" "1" "$rc"
  contains "explains it is refusing to start" "refusing to start" "$out"
  check "the wrapped command never ran" "yes" "$([ -e "$MARKER" ] && echo no || echo yes)"
  export STUB_SERVICE="treetender-cred-work"

  out=$(PATH="$SAFE_PATH" bash "$PWD/lib/credential.sh" "not a label" \
    bash -c 'printf ran > "$1"' -- "$MARKER" 2>&1)
  check "a malformed label exits 1 even when passed straight to this file" "1" "$?"
  contains "names it as not a credential label" "not a credential label" "$out"
  check "the wrapped command never ran either" "yes" "$([ -e "$MARKER" ] && echo no || echo yes)"
  unset STUB_SERVICE STUB_ACCOUNT STUB_VALUE
}

echo "credential: TENDER_CREDENTIAL unset behaves exactly as before"
out=$("$TENDER" demo developer 2>&1)
contains "dry run still names the tool" "claude --append-system-prompt-file" "$out"
lacks "no credential.sh anywhere in the launch line" "credential.sh" "$out"

echo "credential: a malformed TENDER_CREDENTIAL aborts before tmux is touched"
out=$(TENDER_CREDENTIAL="not a label" "$TENDER" demo developer 2>&1)
check "exits 1" "1" "$?"
contains "names it as not a credential label" "is not a credential label" "$out"
lacks "never claims it would launch anything" "would launch" "$out"

echo "credential: a missing keychain entry aborts before tmux is touched"
out=$(PATH="$SAFE_PATH" STUB_SERVICE="treetender-cred-elsewhere" TENDER_CREDENTIAL=work "$TENDER" demo developer 2>&1)
check "exits 1" "1" "$?"
contains "says no readable credential was found" "no readable credential named 'work'" "$out"
contains "points at docs/setup.md" "docs/setup.md" "$out"
lacks "never claims it would launch anything" "would launch" "$out"

echo "credential: a dry run with a real entry wraps the launch, without the value"
export STUB_SERVICE="treetender-cred-work" STUB_ACCOUNT="ANTHROPIC_API_KEY" STUB_VALUE="sk-dry-run-secret"
out=$(PATH="$SAFE_PATH" TENDER_CREDENTIAL=work "$TENDER" demo developer 2>&1)
check "exits 0" "0" "$?"
contains "the dry run names lib/credential.sh as the outermost command" "lib/credential.sh work" "$out"
contains "the real agent command still follows it" "append-system-prompt-file" "$out"
lacks "the dry run output never contains the value" "sk-dry-run-secret" "$out"

echo "credential: a dry run records nothing, and says nothing about the value"
record_of() { ( . "$PWD/lib/credential.sh"; credential_record_file "$1" ); }
record=$(record_of "$SANDBOX/demo/.worktrees/demo-developer")
check "the dry run above left no record" "no" "$([ -e "$record" ] && echo yes || echo no)"
unset STUB_SERVICE STUB_ACCOUNT STUB_VALUE

echo "credential: a start without a credential says when it drops a recorded one"
{
  . "$PWD/lib/credential.sh"
  wt_w="$SANDBOX/demo/.worktrees/demo-developer"
  credential_record "$wt_w" work
  out=$(credential_record "$wt_w" "" 2>&1)
  contains "warns that a restart now restores none" "restores none" "$out"
  contains "names the dropped label" "'work'" "$out"
  check "the record is gone" "no" "$([ -e "$(credential_record_file "$wt_w")" ] && echo yes || echo no)"
  out=$(credential_record "$wt_w" "" 2>&1)
  check "with no record there is nothing to warn about" "" "$out"
}

echo "credential: the record lives outside the worktree"
case "$record" in
  "$SANDBOX/demo/"*) check "not under the worktree" "outside" "inside" ;;
  "$TENDER_STATE_DIR/"*) check "under TENDER_STATE_DIR" "outside" "outside" ;;
  *) check "under TENDER_STATE_DIR" "$TENDER_STATE_DIR/..." "$record" ;;
esac

echo "credential: executed directly, an empty value or a blocked name refuses to start"
{
  MARKER="$STUB/direct-exec-ran"; rm -f "$MARKER"
  export STUB_SERVICE="treetender-cred-work" STUB_ACCOUNT="TESTVAR" STUB_VALUE=""
  out=$(STUB_EMPTY_OK=1 PATH="$SAFE_PATH" bash "$PWD/lib/credential.sh" work bash -c 'printf ran > "$1"' -- "$MARKER" 2>&1)
  check "an entry with an empty password exits 1" "1" "$?"
  contains "... and says it is empty" "is empty" "$out"
  check "the wrapped command never ran" "no" "$([ -e "$MARKER" ] && echo yes || echo no)"
  out=$(STUB_EMPTY_OK=1 PATH="$SAFE_PATH" TENDER_CREDENTIAL=work "$TENDER" demo developer 2>&1)
  check "a start with an empty entry is refused before tmux" "1" "$?"
  lacks "... and never claims it would launch" "would launch" "$out"
  for blocked in PATH BASH_ENV LD_PRELOAD DYLD_INSERT_LIBRARIES SHELLOPTS TENDER_TOOL; do
    export STUB_ACCOUNT="$blocked" STUB_VALUE="sk-blocked"
    out=$(PATH="$SAFE_PATH" bash "$PWD/lib/credential.sh" work bash -c 'printf ran > "$1"' -- "$MARKER" 2>&1)
    check "an account named $blocked exits 1" "1" "$?"
  done
  check "... and the wrapped command never ran for any of them" "no" "$([ -e "$MARKER" ] && echo yes || echo no)"
  unset STUB_SERVICE STUB_ACCOUNT STUB_VALUE
}

echo "credential: the Linux parser reads the account, and never holds the secret line"
{
  LINUX_STUB=$(mktemp -d)
  cat > "$LINUX_STUB/secret-tool" <<'EOF'
#!/usr/bin/env bash
# The split `secret-tool search --all` really makes (libsecret
# tool/secret-tool.c): item header and secret on stdout, the attributes on
# stderr via g_printerr.
printf '[/org/freedesktop/secrets/collection/login/7]\nlabel = treetender-cred-work\nsecret = sk-linux-secret\ncreated = 2026-09-21 10:00:00\n'
printf 'attribute.account = OPENAI_API_KEY\nattribute.service = treetender-cred-work\n' >&2
EOF
  chmod +x "$LINUX_STUB/secret-tool"
  . "$PWD/lib/credential.sh"
  out=$(PATH="$LINUX_STUB:$PATH" credential_account_linux "treetender-cred-work")
  check "reads the account attribute" "OPENAI_API_KEY" "$out"
  lacks "prints nothing of the secret" "sk-linux-secret" "$out"
  trace=$(PATH="$LINUX_STUB:$PATH" bash -xc '. "$1"; credential_account_linux treetender-cred-work' _ "$PWD/lib/credential.sh" 2>&1)
  lacks "a trace (bash -x) of the lookup never shows the secret" "sk-linux-secret" "$trace"
  rm -rf "$LINUX_STUB"
}

echo "credential: the value never touches any process's argv (ps -o args proof)"
if ! command -v tmux >/dev/null 2>&1; then
  echo "  skip (tmux not installed)"
elif [ "$(uname)" != Darwin ] && [ "$(uname)" != Linux ]; then
  echo "  skip (ps -o args= is assumed BSD/GNU-compatible; unknown platform $(uname))"
else
  SECRET_VALUE='sk-TESTSECRET-should-never-appear-in-argv-9f3a'
  tmux kill-session -t tender-demo >/dev/null 2>&1

  # Every tmux call tender makes, logged with its full argv before it runs —
  # a `tmux ... -e KEY=value` would show up here even though it leaves the
  # agent's own argv clean.
  REAL_TMUX=$(command -v tmux)
  cat > "$STUB/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB/tmux.log"
exec "$REAL_TMUX" "\$@"
EOF
  chmod +x "$STUB/tmux"

  cat > "$STUB/agent-stub" <<EOF
#!/usr/bin/env bash
ps -ww -o args= -p "\$\$" > "$STUB/argv-snapshot.txt"
printf ' ARGV0=%s ARGN=%s' "\$0" "\$*" >> "$STUB/argv-snapshot.txt"
printf '%s' "\${TESTVAR:-<unset>}" > "$STUB/env-snapshot.txt"
sleep 20
EOF
  chmod +x "$STUB/agent-stub"
  TOOLS="$STUB/tools"
  printf 'agentstub  %s {context}  verified:2026-09-21\n' "$STUB/agent-stub" > "$TOOLS"

  wait_for() { local i=0; while [ ! -s "$1" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done; }

  rm -f "$STUB"/argv-snapshot.txt "$STUB"/env-snapshot.txt "$STUB/tmux.log" "$SECURITY_LOG.callers"
  : > "$SECURITY_LOG"
  TENDER_TOOLS_FILE="$TOOLS" TENDER_TOOL=agentstub TENDER_CREDENTIAL=work \
    STUB_SERVICE="treetender-cred-work" STUB_ACCOUNT=TESTVAR STUB_VALUE="$SECRET_VALUE" \
    PATH="$SAFE_PATH" TENDER_DRY_RUN= "$TENDER" demo developer </dev/null >"$STUB/start.out" 2>"$STUB/start.err"
  start_rc=$?
  wait_for "$STUB/env-snapshot.txt"
  # No terminal here, as for the desktop app: the start must still count as
  # one that worked, not fail on `tmux attach` after the session is up.
  check "a start without a terminal exits 0 (new session)" "0" "$start_rc"
  contains "... and says how to attach instead" "attach with: tender attach demo" "$(cat "$STUB/start.out")"

  check "the value DID arrive in the agent's environment (positive control)" "$SECRET_VALUE" "$(cat "$STUB/env-snapshot.txt" 2>/dev/null)"
  lacks "the agent's own live argv never carries the value" "$SECRET_VALUE" "$(cat "$STUB/argv-snapshot.txt" 2>/dev/null)"
  callers=$(cat "$SECURITY_LOG.callers" 2>/dev/null)
  check "both lookups' callers were seen alive (pre-flight + pane)" "yes" \
    "$([ "$(grep -c 'find-generic-password -s treetender-cred-work -a TESTVAR -w' "$SECURITY_LOG")" -ge 2 ] && [ -n "$callers" ] && echo yes || echo no)"
  contains "one caller is lib/credential.sh, run directly in the pane" "credential.sh work" "$callers"
  lacks "no caller of a lookup carried the value in its argv" "$SECRET_VALUE" "$callers"
  lacks "no lookup's own argv carried the value" "$SECRET_VALUE" "$(cat "$SECURITY_LOG")"
  tmux_calls=$(cat "$STUB/tmux.log" 2>/dev/null)
  contains "the tmux shim saw tender create the session (positive control)" "new-session" "$tmux_calls"
  lacks "no tmux call carried the value in its argv" "$SECRET_VALUE" "$tmux_calls"
  lacks "tender's own output never carries the value" "$SECRET_VALUE" "$(cat "$STUB/start.out" "$STUB/start.err")"
  check "a real start records the label" "work" "$(cat "$(record_of "$SANDBOX/demo/.worktrees/demo-developer")" 2>/dev/null)"

  echo "credential: tender restart puts the same credential back, still never in argv"
  # The restarted pane looks the key up afresh; in this test the stub's
  # "keychain" is its environment, which the pane inherits from the tmux
  # server started above — hence the same value as the first start.
  rm -f "$STUB/argv-snapshot.txt" "$STUB/env-snapshot.txt" "$STUB/tmux.log"
  out=$(STUB_SERVICE="treetender-cred-work" STUB_ACCOUNT=TESTVAR STUB_VALUE="$SECRET_VALUE" \
    PATH="$SAFE_PATH" TENDER_TOOLS_FILE="$TOOLS" TENDER_TOOL=agentstub \
    "$TENDER" restart demo DEV --fresh 2>&1)
  check "exits 0" "0" "$?"
  contains "says which credential it restores" "restoring credential 'work'" "$out"
  wait_for "$STUB/env-snapshot.txt"
  check "the restarted agent has the value in its environment (positive control)" \
    "$SECRET_VALUE" "$(cat "$STUB/env-snapshot.txt" 2>/dev/null)"
  lacks "the restarted agent's live argv never carries the value" "$SECRET_VALUE" "$(cat "$STUB/argv-snapshot.txt" 2>/dev/null)"
  contains "the tmux shim saw the respawn (positive control)" "respawn-pane" "$(cat "$STUB/tmux.log" 2>/dev/null)"
  lacks "no restart tmux call carried the value" "$SECRET_VALUE" "$(cat "$STUB/tmux.log" 2>/dev/null)"
  lacks "restart's own output never carries the value" "$SECRET_VALUE" "$out"

  echo "credential: a restart whose credential became unreadable leaves the session alone"
  pid_before=$(tmux display-message -p -t "tender-demo:DEV" '#{pane_pid}')
  out=$(PATH="$SAFE_PATH" STUB_SERVICE="treetender-cred-gone" TENDER_TOOLS_FILE="$TOOLS" \
    TENDER_TOOL=agentstub "$TENDER" restart demo DEV --fresh 2>&1)
  check "exits 1" "1" "$?"
  contains "says why it did not restart" "is not restarted without it" "$out"
  check "the running pane was not touched" "$pid_before" "$(tmux display-message -p -t "tender-demo:DEV" '#{pane_pid}')"
  tmux kill-session -t tender-demo >/dev/null 2>&1

  echo "credential: a lookup that fails inside the pane keeps the window open with the reason"
  # The tmux server is started with an environment in which the entry does
  # not exist; tender's own pre-flight check (run with the stub's entry)
  # passes. Only the pane's own lookup fails — the gap the second lookup is
  # there to close, and the one case where nobody would otherwise see why.
  # Set on the session itself (-e), not left to whichever server happens to
  # be running: every pane in it, the one tender adds included, gets these.
  tmux new-session -d -s tender-demo -n holder -e "PATH=$SAFE_PATH" \
    -e STUB_SERVICE=treetender-cred-elsewhere -e STUB_ACCOUNT=TESTVAR -e STUB_VALUE=x "sleep 300"
  rm -f "$STUB/env-snapshot.txt"
  TENDER_TOOLS_FILE="$TOOLS" TENDER_TOOL=agentstub TENDER_CREDENTIAL=work \
    STUB_SERVICE="treetender-cred-work" STUB_ACCOUNT=TESTVAR STUB_VALUE="$SECRET_VALUE" \
    PATH="$SAFE_PATH" TENDER_DRY_RUN= "$TENDER" demo developer </dev/null >/dev/null 2>&1
  check "a start without a terminal exits 0 (window in an existing session)" "0" "$?"
  # Waits for the refusal itself — only once it is on screen does "still
  # there" say anything; checked any earlier, it would pass on a pane that
  # simply had not got that far yet.
  i=0; pane=""
  while [ "$i" -lt 200 ]; do
    pane=$(tmux capture-pane -p -t tender-demo:DEV 2>/dev/null)
    case "$pane" in *"refusing to start"*) break ;; esac
    sleep 0.05; i=$((i + 1))
  done
  contains "it shows why" "refusing to start" "$pane"
  sleep 0.5
  check "the window is still there after its lookup failed" "yes" \
    "$(tmux list-windows -t tender-demo -F '#{window_name}' | grep -qxF DEV && echo yes || echo no)"
  check "the agent never started" "no" "$([ -e "$STUB/env-snapshot.txt" ] && echo yes || echo no)"
  tmux kill-session -t tender-demo >/dev/null 2>&1
fi

summary
