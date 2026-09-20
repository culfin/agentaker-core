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
contains "has a review tools section — roles/reviewer.md sends the reviewer there" "Review tools" "$agents"
contains "has a subagents section — roles/reviewer.md sends the reviewer there too" "Subagents" "$agents"
lacks "does not claim agents will refuse to release — nothing enforces that without a lock" \
  "agents will refuse to release" "$agents"

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
  "api repos/"*"/environments/production")
    # The plain GET (no -X) is cmd_init's existence check, run before the PUT.
    # Answer it from GH_ENV_EXISTS so a test can simulate either case.
    if [ -n "${GH_ENV_EXISTS:-}" ]; then echo "{}"; else exit 1; fi
    ;;
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
contains "checks whether the environment already exists first" "api repos/{}/environments/production" "$calls"
contains "creates the environment" "environments/production" "$calls"
contains "explains what it protects" "wait for you in the browser" "$out"
contains "names the workflow line the user must add" "environment: production" "$out"
contains "reports a fresh create accurately" "environment created: production" "$out"
lacks "does not call a create a claim about an update" "environment updated" "$out"

echo "mdt init: an environment that already exists is reported as updated, not created"
: > "$GH_CALLS"
out=$(PATH="$STUB:$PATH" MDT_YES=1 MDT_NO_NETWORK= GH_ENV_EXISTS=1 "$MDT" init demo 2>&1)
contains "reports an update, not a fresh create" "environment updated: production already existed" "$out"
lacks "does not claim it was freshly created" "environment created: production (" "$out"

# With MDT_NO_NETWORK the environment step must be skipped entirely.
: > "$GH_CALLS"
out=$(PATH="$STUB:$PATH" MDT_YES=1 MDT_NO_NETWORK=1 "$MDT" init demo 2>&1)
lacks "no network means no environment call" "environments/production" "$(cat "$GH_CALLS")"
rm -rf "$STUB"

echo "mdt init: prints the detected trunk, not a hardcoded 'main'"
# A fixture whose trunk genuinely isn't main: a main-trunked fixture (like
# `demo` above) can't tell "reads \$trunk" apart from "always prints main" —
# both produce identical output there.
TRUNK_SANDBOX=$(mktemp -d)
git init -q -b development "$TRUNK_SANDBOX/other-trunk"
git -C "$TRUNK_SANDBOX/other-trunk" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
out=$(MDT_PROJECTS_DIR="$TRUNK_SANDBOX" MDT_YES=1 MDT_NO_NETWORK=1 "$MDT" init other-trunk 2>&1)
contains "pull command names the detected trunk" \
  "pull $TRUNK_SANDBOX/other-trunk development" "$out"
lacks "does not fall back to main for a non-main trunk" \
  "pull $TRUNK_SANDBOX/other-trunk main" "$out"
rm -rf "$TRUNK_SANDBOX"

summary
