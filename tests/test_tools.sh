#!/usr/bin/env bash
# The tools table (issue #2): launch_command() (lib/tools.sh) checks a config
# file before falling back to the built-in claude/codex table. Every test
# here runs through cmd_start() in ATK_DRY_RUN mode (make_sandbox sets it) —
# nothing is actually executed, so this is safe to run anywhere and never
# touches a real tool binary. atk doctor's own execution path is covered
# separately, in tests/test_doctor.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
ATK="$PWD/bin/atk"
make_sandbox
trap 'rm -rf "$SANDBOX"' EXIT

TOOLS="$SANDBOX/tools"

echo "tools: the most important test — no file changes nothing"
check "ATK_TOOLS_FILE points nowhere by default (make_sandbox)" "yes" \
  "$([ -e "$ATK_TOOLS_FILE" ] && echo no || echo yes)"
out=$("$ATK" demo developer 2>&1)
contains "still launches the built-in claude branch" "claude --append-system-prompt-file" "$out"
lacks "does not warn about an unverified path for the default tool" "has never been run" "$out"

echo "tools: an entry for a built-in name overrides it"
cat > "$TOOLS" <<'EOF'
# comment line, and a blank line right after it

claude   claudeoverride --role {context} --flag   verified:2026-09-21
EOF
out=$(ATK_TOOLS_FILE="$TOOLS" "$ATK" demo developer 2>&1)
contains "uses the overriding command" "claudeoverride --role" "$out"
contains "substitutes {context} with the real path" "context.md --flag" "$out"
lacks "the built-in claude flag is gone" "append-system-prompt-file" "$out"
lacks "a verified override stays quiet" "has never been run" "$out"

echo "tools: a new tool, not in the built-in table, is found and launched"
cat > "$TOOLS" <<'EOF'
mytool   mytool --system {context}   unverified
EOF
out=$(ATK_TOOLS_FILE="$TOOLS" ATK_TOOL=mytool "$ATK" demo developer 2>&1)
contains "dry run names the configured tool's own binary" "mytool --system" "$out"
contains "an entry without verified: warns at launch time" "has never been run" "$out"

echo "tools: an entry missing {context} is rejected, by line number, not silently launched"
cat > "$TOOLS" <<'EOF'
# line 1 is this comment
brokentool   brokentool --no-context-token   unverified
EOF
out=$(ATK_TOOLS_FILE="$TOOLS" ATK_TOOL=brokentool "$ATK" demo developer 2>&1)
check "exits 1" "1" "$?"
contains "names the file" "$TOOLS" "$out"
contains "names the line" "$TOOLS:2" "$out"
contains "explains what is missing" "{context}" "$out"
lacks "does not claim to have launched anything" "would launch" "$out"

echo "tools: a broken line does not take the rest of the file down with it"
cat > "$TOOLS" <<'EOF'
onlytwofields verified:2026-09-21
goodtool   goodtool --system {context}   verified:2026-09-21
EOF
out=$(ATK_TOOLS_FILE="$TOOLS" ATK_TOOL=goodtool "$ATK" demo developer 2>&1)
check "the tool below the broken line still starts" "0" "$?"
contains "reports the broken line's own number, not goodtool's" "$TOOLS:1" "$out"
contains "still launches the well-formed line beneath it" "goodtool --system" "$out"
lacks "a verified entry below a broken one still stays quiet" "has never been run" "$out"

echo "tools: comments and blank lines are ignored, not misread as entries"
cat > "$TOOLS" <<'EOF'
# name   command   status

  # indented comment, still a comment

thirdtool   thirdtool --system {context}   verified:2026-09-21
EOF
out=$(ATK_TOOLS_FILE="$TOOLS" ATK_TOOL=thirdtool "$ATK" demo developer 2>&1)
check "exits 0 — the comment lines above it were not read as broken entries" "0" "$?"
lacks "no stray 'too few fields' warning from the comment lines" "too few fields" "$out"

echo "tools: without ATK_TOOLS_FILE, the default path is \$HOME/.config/agentaker/tools"
DEFAULT_HOME=$(mktemp -d)
mkdir -p "$DEFAULT_HOME/.config/agentaker"
cat > "$DEFAULT_HOME/.config/agentaker/tools" <<'EOF'
defaultpathtool   defaultpathtool --system {context}   verified:2026-09-21
EOF
out=$(env -u ATK_TOOLS_FILE -u XDG_CONFIG_HOME HOME="$DEFAULT_HOME" ATK_TOOL=defaultpathtool \
  ATK_PROJECTS_DIR="$ATK_PROJECTS_DIR" ATK_DRY_RUN=1 "$ATK" demo developer 2>&1)
contains "reads \$HOME/.config/agentaker/tools when nothing overrides it" "defaultpathtool --system" "$out"

echo "tools: ATK_TOOLS_FILE overrides the default path (tests need this, and so does anyone with XDG_CONFIG_HOME set)"
out=$(HOME="$DEFAULT_HOME" ATK_TOOLS_FILE="$TOOLS" ATK_TOOL=thirdtool "$ATK" demo developer 2>&1)
contains "still reads the overridden path, not \$HOME/.config" "thirdtool --system" "$out"
rm -rf "$DEFAULT_HOME"

rm -f "$TOOLS"
summary
