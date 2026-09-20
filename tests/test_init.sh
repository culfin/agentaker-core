#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
WTR="$PWD/bin/wtr"
make_sandbox
trap 'rm -rf "$SANDBOX"' EXIT
export WTR_YES=1 WTR_NO_NETWORK=1

echo "wtr init: prerequisites"
out=$("$WTR" init demo 2>&1)
contains "checks git" "git" "$out"
contains "checks tmux" "tmux" "$out"

echo "wtr init: stack detection"
touch "$SANDBOX/demo/Cargo.toml"
out=$("$WTR" init demo 2>&1)
contains "detects rust" "Rust" "$out"
rm "$SANDBOX/demo/Cargo.toml"
printf '{"name":"x"}' > "$SANDBOX/demo/package.json"
out=$("$WTR" init demo 2>&1)
contains "detects node" "Node" "$out"

echo "wtr init: writes AGENTS.md"
check "AGENTS.md created" "yes" "$([ -f "$SANDBOX/demo/AGENTS.md" ] && echo yes || echo no)"
agents=$(cat "$SANDBOX/demo/AGENTS.md")
contains "names the trunk" "trunk:" "$agents"
contains "has a production boundary" "Production boundary" "$agents"
contains "has test commands" "Test commands" "$agents"

echo "wtr init: never overwrites an existing AGENTS.md"
printf 'MY OWN FILE\n' > "$SANDBOX/demo/AGENTS.md"
out=$("$WTR" init demo 2>&1)
check "existing file untouched" "MY OWN FILE" "$(cat "$SANDBOX/demo/AGENTS.md")"
contains "says so" "already has" "$out"

echo "wtr init: creates the worktrees"
for role in developer reviewer integrator; do
  check "worktree for $role" "yes" \
    "$([ -d "$SANDBOX/demo/.worktrees/demo-$role" ] && echo yes || echo no)"
done

echo "wtr init: tells you what to do next"
contains "names the next command" "wtr demo developer" "$out"
contains "mentions the ready label" "ready" "$out"

summary
