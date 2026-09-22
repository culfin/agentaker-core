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
# The keychain stand-ins from tests/lib.sh stay first: no test reaches the
# real keychain, not even through a hand-built PATH.
SAFE_PATH="$TEST_NOKEYCHAIN:$STUB:/usr/bin:/bin"

TOOLS="$SANDBOX/tools"

# Issue #9's convention, checked over a whole output: every line below a tool
# heading is either "role arrived", a gap ("human:"/"fixable:"), or the
# "action:" that must follow each gap directly. Prints the first offending
# line, or nothing.
gap_shape_violation() {
  # `exit` in awk still runs END, so each finding sets done first.
  printf '%s\n' "$1" | awk '
    function bad(msg) { print msg; done = 1; exit }
    /^[^ ].*:$/                           { if (want) bad("no action after: " gap); next }
    /^  (human|fixable): /                { if (want) bad("no action after: " gap); want = 1; gap = $0; next }
    /^  action: ./                        { if (!want) bad("action without a gap: " $0); want = 0; next }
    /^  role arrived$/                    { if (want) bad("no action after: " gap); next }
    /./                                   { bad("line outside the convention: " $0) }
    END                                   { if (!done && want) print "no action after: " gap }'
}

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
contains "says who can fix it" "  human: started (exit 0) but the role never arrived" "$out"
contains "names the next step, with the tool" "  action: check silenttool's line in your tools file" "$out"

echo "doctor: a built-in whose role never arrives points at lib/tools.sh, not a tools-file line"
# `codex` is built in; a stub of that name on PATH starts, stays silent and
# exits — and there is no tools file, as for most users.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/codex"; chmod +x "$STUB/codex"
out=$(TENDER_TOOLS_FILE="$SANDBOX/no-tools-file" PATH="$SAFE_PATH" TENDER_DOCTOR_TIMEOUT=3 "$TENDER" doctor codex 2>&1)
check "exits 1" "1" "$?"
contains "names the built-in launch line" "check codex's built-in launch line in lib/tools.sh — or override it with a line in your tools file" "$out"
lacks "does not send them to a tools-file line that is not there" "codex's line in your tools file" "$out"
rm -f "$STUB/codex"

echo "doctor: a tool that never answers is killed, not waited for forever"
START=$(date +%s)
out=$(TENDER_TOOLS_FILE="$TOOLS" PATH="$SAFE_PATH" TENDER_DOCTOR_TIMEOUT=1 "$TENDER" doctor hangtool 2>&1)
rc=$?
END=$(date +%s)
check "exits 1" "1" "$rc"
contains "says it gave up waiting" "no response in 1s" "$out"
contains "reads as unconfirmed, not as broken" "  human: could not confirm automatically — no response in 1s" "$out"
contains "offers a longer timeout for this tool" "TENDER_DOCTOR_TIMEOUT=60 tender doctor hangtool" "$out"
check "did not block anywhere near the default 15s timeout" "yes" "$([ "$((END - START))" -lt 10 ] && echo yes || echo no)"

echo "doctor: a tool not on PATH is reported as such, never silently skipped"
out=$(TENDER_TOOLS_FILE="$TOOLS" PATH="$SAFE_PATH" "$TENDER" doctor notinstalled 2>&1)
check "exits 1" "1" "$?"
contains "says it is not installed" "not installed" "$out"
contains "a human gap, naming the binary" "  human: not installed (no-such-binary not on PATH)" "$out"
contains "says what to install and how to re-check" "  action: install no-such-binary, or put its directory on PATH, then run: tender doctor notinstalled" "$out"

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
check "every gap in a full run is followed by its action (issue #9)" "" "$(gap_shape_violation "$out")"
contains "the full run did report gaps (positive control)" "  human: " "$out"

echo "doctor: the convention check itself catches a gap without an action"
check "a bare gap is caught" "no action after:   human: x" "$(gap_shape_violation "$(printf 'tool:\n  human: x\n')")"
check "an old-style line is caught" "line outside the convention:   no response in 1s" "$(gap_shape_violation "$(printf 'tool:\n  no response in 1s\n')")"
check "an action without a gap is caught" "action without a gap:   action: x" "$(gap_shape_violation "$(printf 'tool:\n  action: x\n')")"
check "a gap followed by the next tool is caught" "no action after:   human: x" "$(gap_shape_violation "$(printf 'a:\n  human: x\nb:\n  role arrived\n')")"

summary
