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

# --- issue #3: flags for a non-interactive caller (a GUI) ------------------
# These use their own throwaway sandboxes, not $SANDBOX/demo above, so they
# cannot interact with state the tests before them already built up there
# (an existing AGENTS.md, existing worktrees).

echo "mdt init: flags override what trunk/reviewer/tests/boundary would otherwise propose"
FLAG_SANDBOX=$(mktemp -d)
git init -q -b main "$FLAG_SANDBOX/flagged"
git -C "$FLAG_SANDBOX/flagged" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
out=$(MDT_PROJECTS_DIR="$FLAG_SANDBOX" MDT_NO_NETWORK=1 MDT_DRY_RUN=1 "$MDT" init flagged \
  --trunk release --reviewer octocat --tests 'pnpm test' --tests 'pnpm build' \
  --boundary 'gh workflow run deploy.yml' --yes 2>&1)
check "at least one step changed something: exits done (0)" "0" "$?"
agents=$(cat "$FLAG_SANDBOX/flagged/AGENTS.md")
contains "uses the overridden trunk" "trunk: release" "$agents"
contains "uses the overridden reviewer" "reviewer: octocat" "$agents"
contains "uses the first overridden test command" "pnpm test" "$agents"
contains "uses the second overridden test command" "pnpm build" "$agents"
contains "uses the overridden boundary text" "gh workflow run deploy.yml" "$agents"
lacks "does not fall back to the generic boundary example" "Replace this with yours" "$agents"
lacks "does not fall back to the stack-detected placeholder" "no test command detected" "$agents"
rm -rf "$FLAG_SANDBOX"

echo "mdt init: --boundary '' writes an explicit 'deliberately none', not the generic example"
BOUND_SANDBOX=$(mktemp -d)
git init -q -b main "$BOUND_SANDBOX/none"
git -C "$BOUND_SANDBOX/none" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
out=$(MDT_PROJECTS_DIR="$BOUND_SANDBOX" MDT_NO_NETWORK=1 MDT_DRY_RUN=1 "$MDT" init none --boundary '' --yes 2>&1)
check "an explicit empty boundary still exits done (0)" "0" "$?"
agents=$(cat "$BOUND_SANDBOX/none/AGENTS.md")
contains "says the boundary was deliberately left blank" "intentionally left blank" "$agents"
lacks "does not fall back to the generic boundary example" "Replace this with yours" "$agents"
rm -rf "$BOUND_SANDBOX"

echo "mdt init: --yes without --boundary refuses rather than silently writing no boundary"
REFUSE_SANDBOX=$(mktemp -d)
git init -q -b main "$REFUSE_SANDBOX/norefuse"
git -C "$REFUSE_SANDBOX/norefuse" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
out=$(MDT_PROJECTS_DIR="$REFUSE_SANDBOX" MDT_NO_NETWORK=1 MDT_DRY_RUN=1 "$MDT" init norefuse --yes 2>&1)
check "exits refused at step 1 (20 + step)" "21" "$?"
contains "names which step refused" "step 1 (AGENTS.md)" "$out"
contains "names the missing flag" "--boundary" "$out"
check "does not write an AGENTS.md with no boundary anyone chose" "no" \
  "$([ -f "$REFUSE_SANDBOX/norefuse/AGENTS.md" ] && echo yes || echo no)"
rm -rf "$REFUSE_SANDBOX"

echo "mdt init: the existing env-var route (MDT_YES, no --yes flag) is untouched by the boundary guard"
LEGACY_SANDBOX=$(mktemp -d)
git init -q -b main "$LEGACY_SANDBOX/legacy"
git -C "$LEGACY_SANDBOX/legacy" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
out=$(MDT_PROJECTS_DIR="$LEGACY_SANDBOX" MDT_YES=1 MDT_NO_NETWORK=1 MDT_DRY_RUN=1 "$MDT" init legacy 2>&1)
check "the interactive env-var route still succeeds with no --boundary given" "0" "$?"
contains "still writes AGENTS.md with the generic boundary placeholder, unchanged" \
  "Replace this with yours" "$(cat "$LEGACY_SANDBOX/legacy/AGENTS.md")"
rm -rf "$LEGACY_SANDBOX"

echo "mdt init: --no-agents-md / --no-labels / --no-environment / --no-worktrees skip individually"
SKIP_SANDBOX=$(mktemp -d)
git init -q -b main "$SKIP_SANDBOX/skipme"
git -C "$SKIP_SANDBOX/skipme" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
out=$(MDT_PROJECTS_DIR="$SKIP_SANDBOX" MDT_DRY_RUN=1 "$MDT" init skipme \
  --no-agents-md --no-labels --no-environment --no-worktrees --yes 2>&1)
check "a run that skips every step, and refuses nothing, has nothing to do: exits 3" "3" "$?"
contains "reports the AGENTS.md skip" "skipped: AGENTS.md (--no-agents-md)" "$out"
contains "reports the labels skip" "skipped: labels (--no-labels)" "$out"
contains "reports the environment skip" "skipped: production environment (--no-environment)" "$out"
contains "reports the worktrees skip" "skipped: worktrees (--no-worktrees)" "$out"
check "AGENTS.md not written" "no" "$([ -f "$SKIP_SANDBOX/skipme/AGENTS.md" ] && echo yes || echo no)"
check "no worktree created" "no" "$([ -d "$SKIP_SANDBOX/skipme/.worktrees/skipme-developer" ] && echo yes || echo no)"
rm -rf "$SKIP_SANDBOX"

echo "mdt init: exit codes distinguish done from nothing-to-do across two runs"
IDEM_SANDBOX=$(mktemp -d)
git init -q -b main "$IDEM_SANDBOX/idem"
git -C "$IDEM_SANDBOX/idem" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
out=$(MDT_PROJECTS_DIR="$IDEM_SANDBOX" MDT_NO_NETWORK=1 MDT_DRY_RUN=1 "$MDT" init idem --yes --boundary 'npm publish' 2>&1)
check "first run creates AGENTS.md and worktrees: exits done (0)" "0" "$?"
out=$(MDT_PROJECTS_DIR="$IDEM_SANDBOX" MDT_NO_NETWORK=1 MDT_DRY_RUN=1 "$MDT" init idem --yes --boundary 'npm publish' 2>&1)
check "second run finds it all already there: exits nothing-to-do (3)" "3" "$?"
rm -rf "$IDEM_SANDBOX"

echo "mdt init: bad flags are usage errors, not silently ignored"
out=$("$MDT" init demo --trunk 2>&1)
check "a flag missing its value exits 2" "2" "$?"
contains "names the flag" "--trunk" "$out"

out=$("$MDT" init demo --nope 2>&1)
check "an unknown flag exits 2" "2" "$?"
contains "names the flag" "--nope" "$out"

out=$("$MDT" init demo extra 2>&1)
check "a second positional argument exits 2" "2" "$?"
contains "explains the repo is already set" "already" "$out"

echo "mdt init: --help documents the flags and exits 0 without requiring a repo"
out=$("$MDT" init --help 2>&1)
check "exits 0" "0" "$?"
contains "documents --boundary and its tri-state" "deliberately none" "$out"
contains "documents the exit codes" "21-24 refused at step N" "$out"

summary
