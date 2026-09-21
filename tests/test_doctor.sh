#!/usr/bin/env bash
# `tender doctor` actually executes whatever launch_command() resolves to — the
# one command in this whole tool with real, external side effects. Every
# invocation below runs with PATH pinned to a stub directory plus /usr/bin
# and /bin, deliberately excluding wherever a real coding agent happens to
# live on this machine (this development machine has a real `claude` on
# PATH, being Claude Code itself) — a bug that made `tender doctor` reach past
# its stubs would otherwise try to start a real nested session instead of
# failing a test.
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
TENDER="$PWD/bin/tender"
make_sandbox
trap 'rm -rf "$SANDBOX"' EXIT

STUB=$(mktemp -d)
trap 'rm -rf "$SANDBOX" "$STUB"' EXIT
SAFE_PATH="$STUB:/usr/bin:/bin"

TOOLS="$SANDBOX/tools"

cat > "$STUB/okstub" <<'STUBEOF'
#!/usr/bin/env bash
# Reads its context argument and immediately prints the doctor marker tender
# looks for — stands in for a tool that received its role and said so.
cat "$1" >/dev/null
printf 'TENDER-DOCTOR-OK\n'
STUBEOF
chmod +x "$STUB/okstub"

cat > "$STUB/silentstub" <<'STUBEOF'
#!/usr/bin/env bash
# Exits cleanly without ever printing the marker — stands in for a tool that
# started but never acted on the context (or doesn't support this at all).
exit 0
STUBEOF
chmod +x "$STUB/silentstub"

cat > "$STUB/hangstub" <<'STUBEOF'
#!/usr/bin/env bash
# Never exits on its own — stands in for a tool doctor has to kill rather
# than wait for.
while true; do sleep 1; done
STUBEOF
chmod +x "$STUB/hangstub"

cat > "$TOOLS" <<'EOF'
okgtool       okstub {context}       verified:2026-09-21
silenttool    silentstub {context}   unverified
hangtool      hangstub {context}     unverified
notinstalled  no-such-binary {context}   unverified
EOF

echo "doctor: unknown tool refuses rather than guessing"
out=$(TENDER_TOOLS_FILE="$TOOLS" PATH="$SAFE_PATH" "$TENDER" doctor nosuchtool 2>&1)
check "exits 1" "1" "$?"
contains "names the unknown tool" "nosuchtool" "$out"
contains "points at the docs" "docs/tools.md" "$out"

echo "doctor: a tool that answers reports the role arrived"
out=$(TENDER_TOOLS_FILE="$TOOLS" PATH="$SAFE_PATH" "$TENDER" doctor okgtool 2>&1)
check "exits 0" "0" "$?"
contains "reports the tool by name" "okgtool" "$out"
contains "confirms the marker arrived" "role arrived" "$out"

echo "doctor: a tool that starts but stays silent is not reported as working"
out=$(TENDER_TOOLS_FILE="$TOOLS" PATH="$SAFE_PATH" TENDER_DOCTOR_TIMEOUT=3 "$TENDER" doctor silenttool 2>&1)
check "exits 1" "1" "$?"
lacks "does not falsely claim the role arrived" "role arrived" "$out"

echo "doctor: a tool that never answers is killed, not waited for forever"
START=$(date +%s)
out=$(TENDER_TOOLS_FILE="$TOOLS" PATH="$SAFE_PATH" TENDER_DOCTOR_TIMEOUT=1 "$TENDER" doctor hangtool 2>&1)
rc=$?
END=$(date +%s)
check "exits 1" "1" "$rc"
contains "says it gave up waiting" "no response in 1s" "$out"
check "did not block anywhere near the default 15s timeout" "yes" "$([ "$((END - START))" -lt 10 ] && echo yes || echo no)"

echo "doctor: a tool not on PATH is reported as such, never silently skipped"
out=$(TENDER_TOOLS_FILE="$TOOLS" PATH="$SAFE_PATH" "$TENDER" doctor notinstalled 2>&1)
check "exits 1" "1" "$?"
contains "says it is not installed" "not installed" "$out"

echo "doctor: never touches a real project"
BEFORE=$(find "$SANDBOX/demo" -maxdepth 1 | sort)
TENDER_TOOLS_FILE="$TOOLS" PATH="$SAFE_PATH" "$TENDER" doctor okgtool >/dev/null 2>&1
AFTER=$(find "$SANDBOX/demo" -maxdepth 1 | sort)
check "the project directory tree is unchanged" "$BEFORE" "$AFTER"

echo "doctor: without an argument, checks every known tool"
out=$(TENDER_TOOLS_FILE="$TOOLS" PATH="$SAFE_PATH" TENDER_DOCTOR_TIMEOUT=1 "$TENDER" doctor 2>&1)
contains "includes the built-in claude" "claude:" "$out"
contains "includes the built-in codex" "codex:" "$out"
contains "includes a tools-file entry" "okgtool:" "$out"
contains "the built-ins are not on this restricted PATH" "not installed" "$out"

summary
