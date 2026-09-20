#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
MDT="$PWD/bin/mdt"
make_sandbox
trap 'rm -rf "$SANDBOX"' EXIT
export MDT_YES=1 MDT_NO_NETWORK=1

echo "mdt init: prerequisites"
out=$("$MDT" init demo 2>&1)
contains "checks git" "git" "$out"
contains "checks tmux" "tmux" "$out"
lacks "no error text dressed up as ok" "unknown option" "$out"

echo "mdt init: stack detection"
touch "$SANDBOX/demo/Cargo.toml"
out=$("$MDT" init demo 2>&1)
contains "detects rust" "Rust" "$out"
rm "$SANDBOX/demo/Cargo.toml"
printf '{"name":"x"}' > "$SANDBOX/demo/package.json"
out=$("$MDT" init demo 2>&1)
contains "detects node" "Node" "$out"

echo "mdt init: writes AGENTS.md"
check "AGENTS.md created" "yes" "$([ -f "$SANDBOX/demo/AGENTS.md" ] && echo yes || echo no)"
agents=$(cat "$SANDBOX/demo/AGENTS.md")
contains "names the trunk" "trunk:" "$agents"
contains "has a production boundary" "Production boundary" "$agents"
contains "has test commands" "Test commands" "$agents"

echo "mdt init: never overwrites an existing AGENTS.md"
printf 'MY OWN FILE\n' > "$SANDBOX/demo/AGENTS.md"
out=$("$MDT" init demo 2>&1)
check "existing file untouched" "MY OWN FILE" "$(cat "$SANDBOX/demo/AGENTS.md")"
contains "says so" "already has" "$out"

echo "mdt init: creates the worktrees"
for role in developer reviewer maintainer; do
  check "worktree for $role" "yes" \
    "$([ -d "$SANDBOX/demo/.worktrees/demo-$role" ] && echo yes || echo no)"
done

echo "mdt init: tells you what to do next"
contains "names the next command" "mdt demo developer" "$out"
contains "mentions the ready label" "ready" "$out"

echo "mdt init: offers to protect the production boundary"
STUB=$(mktemp -d)
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$*" in
  "api user --jq .id") echo "4242" ;;
  *) echo "{}" ;;
esac
STUBEOF
chmod +x "$STUB/gh"
export GH_CALLS="$STUB/calls"; : > "$GH_CALLS"

# The file-level `export MDT_NO_NETWORK=1` above must be overridden inline here
# (to empty) or this call would silently skip the network step being tested.
out=$(PATH="$STUB:$PATH" MDT_YES=1 MDT_NO_NETWORK= "$MDT" init demo 2>&1)
calls=$(cat "$GH_CALLS")
contains "asks for the user id" "api user" "$calls"
contains "creates the environment" "environments/production" "$calls"
contains "explains what it protects" "wait for you in the browser" "$out"
contains "names the workflow line the user must add" "environment: production" "$out"

# With MDT_NO_NETWORK the environment step must be skipped entirely.
: > "$GH_CALLS"
out=$(PATH="$STUB:$PATH" MDT_YES=1 MDT_NO_NETWORK=1 "$MDT" init demo 2>&1)
lacks "no network means no environment call" "environments/production" "$(cat "$GH_CALLS")"
rm -rf "$STUB"

summary
