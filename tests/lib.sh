# Minimal assertions. No framework — this must run wherever bash does.

# --- tmux isolation ----------------------------------------------------------
# Every test runs against a private tmux server, never the developer's own.
#
# Not hypothetical. On 2026-09-21 an experiment run from inside a coding-agent
# session did `export TMUX_TMPDIR=$(mktemp -d); tmux kill-server`, believing it
# was isolated. It was not: while $TMUX is set — as it is whenever the shell
# itself runs inside tmux — tmux takes its socket from $TMUX and ignores
# TMUX_TMPDIR. That kill-server ended every session on the real server,
# including other live conversations.
#
# So both halves are required: unset TMUX, *and* point TMUX_TMPDIR somewhere
# private. `cd -P` resolves macOS's /var -> /private/var symlink, so the path
# compares equal to the socket path tmux reports.
unset TMUX TMUX_PANE
TMUX_TMPDIR=$(cd -P "$(mktemp -d)" && pwd)
export TMUX_TMPDIR
TMUX_ISOLATED_SOCKET=""

# "Looked isolated" was exactly the failure, so this is checked, not assumed:
# start a probe session, ask tmux which socket it landed on, and refuse to run
# a single test unless that socket is under our private directory. Whatever the
# answer, only the probe's own uniquely named session is ever removed — never
# the server — so this check cannot do damage even when isolation has failed.
# An empty TMUX_TMPDIR (mktemp failed) would turn the pattern below into "/?*",
# which matches every absolute path — including the real server's socket. The
# check would wave through exactly the case it exists to stop.
if [ -z "$TMUX_TMPDIR" ] || [ ! -d "$TMUX_TMPDIR" ]; then
  printf 'tests/lib.sh: REFUSING TO RUN — could not create a private tmux directory.\n' >&2
  exit 97
fi

if command -v tmux >/dev/null 2>&1; then
  __probe="tender-isolation-probe-$$"
  if tmux new-session -d -s "$__probe" 2>/dev/null; then
    __sock=$(tmux display-message -p -t "$__probe" '#{socket_path}' 2>/dev/null)
    tmux kill-session -t "$__probe" 2>/dev/null
    case "$__sock" in
      "$TMUX_TMPDIR"/?*) TMUX_ISOLATED_SOCKET=$__sock ;;
      *)
        printf 'tests/lib.sh: REFUSING TO RUN — tmux resolved to %s, not a private socket under %s.\n' \
          "${__sock:-<nothing>}" "$TMUX_TMPDIR" >&2
        printf 'tests/lib.sh: running these tests now could touch your real tmux sessions.\n' >&2
        exit 97
        ;;
    esac
  fi
  unset __probe __sock
fi

# --- keychain isolation -------------------------------------------------------
# No test may reach the real OS keychain: a reviewer start asks it whether a
# token exists, a named credential reads it. So `security` and `secret-tool`
# are shadowed for every test by stand-ins that find nothing; a test that
# needs an entry puts its own stub *in front of* this directory on PATH.
# Kept under the private tmux directory, which summary() removes.
TEST_NOKEYCHAIN="$TMUX_TMPDIR/nokeychain"
mkdir -p "$TEST_NOKEYCHAIN"
printf '#!/bin/sh\nexit 44\n' > "$TEST_NOKEYCHAIN/security"
printf '#!/bin/sh\nexit 1\n' > "$TEST_NOKEYCHAIN/secret-tool"
chmod +x "$TEST_NOKEYCHAIN/security" "$TEST_NOKEYCHAIN/secret-tool"
export PATH="$TEST_NOKEYCHAIN:$PATH"

PASS=0
FAIL=0

check() {
  local label=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$label" "$expected" "$actual"
  fi
}

contains() {
  local label=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$label" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL %s\n       expected to contain: %s\n       actual: %s\n' "$label" "$needle" "$haystack" ;;
  esac
}

lacks() {
  local label=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) FAIL=$((FAIL + 1)); printf '  FAIL %s\n       should not contain: %s\n' "$label" "$needle" ;;
    *) PASS=$((PASS + 1)); printf '  ok   %s\n' "$label" ;;
  esac
}

summary() {
  printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
  # Stop the private server by its explicit socket path. `-S` with a path under
  # our own temp directory cannot reach any other server, which is the only
  # reason a kill-server is acceptable here at all.
  if [ -n "$TMUX_ISOLATED_SOCKET" ]; then
    tmux -S "$TMUX_ISOLATED_SOCKET" kill-server 2>/dev/null
  fi
  rm -rf "$TMUX_TMPDIR" 2>/dev/null
  [ "$FAIL" -eq 0 ]
}

# A throwaway projects directory holding one throwaway git repo.
#
# TENDER_TOOLS_FILE points at a path that never exists unless a test creates it:
# without this, "no tools file" tests would silently read whatever a
# developer happens to have at the real default
# (${XDG_CONFIG_HOME:-$HOME/.config}/treetender/tools) — hermetic either way,
# but only on purpose if it's pinned here rather than left to whatever the
# host happens to have.
make_sandbox() {
  SANDBOX=$(mktemp -d)
  export TENDER_PROJECTS_DIR="$SANDBOX"
  export TENDER_DRY_RUN=1
  export TENDER_TOOLS_FILE="$SANDBOX/no-such-tools-file"
  # Where a start records its credential label (lib/credential.sh) — kept
  # out of the real ~/.local/state, which a test has no business writing to.
  export TENDER_STATE_DIR="$SANDBOX/state"
  git init -q -b main "$SANDBOX/demo"
  git -C "$SANDBOX/demo" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
}
