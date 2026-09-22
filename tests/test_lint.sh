#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
LINT="$PWD/bin/atk-lint"

echo "lint: this repository"
out=$("$LINT" . 2>&1); check "repository is consistent" "0" "$?"

echo "lint: a broken example is caught"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/roles" "$TMP/agents" "$TMP/examples" "$TMP/bin"
touch "$TMP/roles/_base.md" "$TMP/roles/developer.md"
printf 'x\n' > "$TMP/agents/real-agent.md"

printf 'trunk: main\n\n## Roles\narchitect\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "unknown role fails" "1" "$?"
contains "names the unknown role" "architect" "$out"

printf '## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "missing trunk fails" "1" "$?"
contains "says trunk" "trunk" "$out"

printf 'trunk: main\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "missing boundary fails" "1" "$?"
contains "says production boundary" "roduction boundary" "$out"

printf 'trunk: main\n\n## Subagents\nghost-agent\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "unknown subagent fails" "1" "$?"
contains "names the unknown subagent" "ghost-agent" "$out"

echo "lint: an example's max-open-prs must be a positive integer"
printf 'trunk: main\nreviewer: x\nmax-open-prs: 0\n\n## Test commands\nx\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "max-open-prs: 0 fails" "1" "$?"
contains "names the bad value" "max-open-prs '0' is not a positive integer" "$out"
printf 'trunk: main\nreviewer: x\nmax-open-prs: 3  # small\n\n## Test commands\nx\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1)
lacks "max-open-prs: 3 with a comment passes" "max-open-prs" "$out"
printf 'trunk: main\nreviewer: x\nmax-open-prs: 1234567890\n\n## Test commands\nx\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1)
contains "ten digits fails" "max-open-prs '1234567890' is not a positive integer" "$out"

echo "lint: vendor names in roles are caught"
printf 'trunk: main\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
printf 'Use Claude for this.\n' > "$TMP/roles/developer.md"
out=$("$LINT" "$TMP" 2>&1); check "vendor name in a role fails" "1" "$?"
contains "names the offending file" "developer.md" "$out"

echo "lint: reviewer field is required"
printf 'trunk: main\n\n## Test commands\nx\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "missing reviewer fails" "1" "$?"
contains "says reviewer" "reviewer:" "$out"

echo "lint: a heading without a space is caught, not silently skipped"
printf 'trunk: main\nreviewer: example-reviewer\n\n## Test commands\nx\n\n##Roles\narchitect\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "malformed heading fails" "1" "$?"
contains "names the malformed heading" "space after ##" "$out"

# Same content with the heading repaired: now the unknown role itself must be the
# complaint — proving the section really was being skipped before.
printf 'trunk: main\nreviewer: example-reviewer\n\n## Test commands\nx\n\n## Roles\narchitect\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "repaired heading exposes the bad role" "1" "$?"
contains "names the unknown role" "architect" "$out"

echo "lint: a file over the line ceiling is caught, including the moved file"
TMP2=$(mktemp -d); trap 'rm -rf "$TMP" "$TMP2"' EXIT
mkdir -p "$TMP2/roles" "$TMP2/examples" "$TMP2/bin" "$TMP2/lib"
touch "$TMP2/roles/_base.md"
printf 'x\n' > "$TMP2/lib/init.sh"
yes '# padding' | head -451 >> "$TMP2/lib/init.sh"
out=$("$LINT" "$TMP2" 2>&1); check "oversized lib/init.sh fails" "1" "$?"
contains "names lib/init.sh, not just bin/atk" "lib/init.sh is" "$out"
rm -f "$TMP2/lib/init.sh"
yes '# padding' | head -451 > "$TMP2/lib/throttle.sh"
out=$("$LINT" "$TMP2" 2>&1); check "oversized lib/throttle.sh fails" "1" "$?"
contains "names lib/throttle.sh" "lib/throttle.sh is" "$out"

echo "lint: single-account mode documentation is required in each role file"
printf 'trunk: main\n\nreviewer: example-reviewer\n\n## Test commands\nx\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
printf '# x\nPropose, never assume\nNever create credentials\nNever commit without asking\nNever invent a value\n' > "$TMP/INSTALL.md"

printf '# developer\nNo mention of the default mode here.\n' > "$TMP/roles/developer.md"
out=$("$LINT" "$TMP" 2>&1); check "missing single-account mode fails" "1" "$?"
contains "names the file missing it" "roles/developer.md" "$out"
contains "explains what was lost" "single-account mode documentation" "$out"

printf '# developer\nDetects single-account mode from AGENTS.md.\n' > "$TMP/roles/developer.md"
out=$("$LINT" "$TMP" 2>&1); check "restored mention passes" "0" "$?"

echo "lint: a label a role uses must be one init.sh creates"
mkdir -p "$TMP/lib"
printf '# developer\nDetects single-account mode from AGENTS.md.\ngh pr edit <N> --add-label approved\n' > "$TMP/roles/developer.md"
printf 'gh label create ready --description "x"\n' > "$TMP/lib/init.sh"
out=$("$LINT" "$TMP" 2>&1); check "label without a creator fails" "1" "$?"
contains "names the orphaned label" "approved" "$out"
contains "names where it should be created" "lib/init.sh" "$out"

printf 'gh label create ready --description "x"\ngh label create approved --description "x"\n' > "$TMP/lib/init.sh"
out=$("$LINT" "$TMP" 2>&1); check "created label passes" "0" "$?"

printf '# developer\nDetects single-account mode from AGENTS.md.\n' > "$TMP/roles/developer.md"

echo "lint: INSTALL.md guard rails"
# roles/developer.md still holds the "restored mention" text left by the
# single-account-mode case above, which is harmless prose here — leave it,
# so this block tests only INSTALL.md rather than resetting an unrelated file.
printf '# x\nPropose, never assume\nNever create credentials\nNever commit without asking\nNever invent a value\n' > "$TMP/INSTALL.md"
printf 'trunk: main\n\nreviewer: example-reviewer\n\n## Test commands\nx\n\n## Production boundary\nnone\n' > "$TMP/examples/a.AGENTS.md"
out=$("$LINT" "$TMP" 2>&1); check "intact INSTALL.md passes" "0" "$?"

printf '# x\nPropose, never assume\nNever commit without asking\nNever invent a value\n' > "$TMP/INSTALL.md"
out=$("$LINT" "$TMP" 2>&1); check "missing guard rail fails" "1" "$?"
contains "names the lost guard rail" "Never create credentials" "$out"

rm "$TMP/INSTALL.md"
out=$("$LINT" "$TMP" 2>&1); check "absent INSTALL.md fails" "1" "$?"

summary
