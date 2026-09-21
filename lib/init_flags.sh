#!/usr/bin/env bash
# Argument parsing, help text and the exit-code contract for `tender init` —
# split out of lib/init.sh to keep it under the 450-line ceiling bin/tender-lint
# enforces (see bin/tender-lint's own comment on the list this file joins, and
# lib/tabs.sh's header for the same reasoning applied to bin/tender itself).
#
# Why this exists (issue #3): a graphical wizard can propose the same values
# detect_stack()/suggest_tests() propose, and confirm the same four steps a
# human confirms today — but it cannot answer a prompt on a pty. This file is
# the seam: it turns those four confirmations and their proposed values into
# flags, and turns "something went wrong" into an exit code specific enough
# that the caller never has to parse stderr prose to react correctly.
#
# Sourced by bin/tender on demand, immediately before lib/init.sh, only for
# `tender init` — see lib/init.sh's own header for why that whole subcommand is
# on-demand rather than eager.
#
# Needs from bin/tender:     die()
# Provides to lib/init.sh: init_parse_args() (sets the INIT_* globals below),
#                          init_help(), refuse_step()

# The exit-code contract. A UI reads this, not stderr:
#   0        done — at least one of the four steps made a change
#   1        a prerequisite failed (die(), e.g. "not a git repository")
#   2        usage error — bad or missing flag value
#   3        nothing to do — every step already satisfied, skipped, or
#            declined; nothing refused
#   21-24    refused at step N (1=AGENTS.md 2=labels 3=environment
#            4=worktrees) — today only step 1 can refuse (--yes without
#            --boundary, or a --commit git refused); 22-24 are reserved,
#            not yet reachable
INIT_STEP_NAMES=(AGENTS.md labels environment worktrees)

# Prints which step refused and why, then exits with that step baked into the
# code itself (20 + step) — so a caller who only checks the exit code, not
# stderr, still knows which of the four steps to blame.
refuse_step() {
  local step=$1 reason=$2
  printf 'tender init: refused at step %d (%s) — %s\n' \
    "$step" "${INIT_STEP_NAMES[$((step - 1))]}" "$reason" >&2
  exit $((20 + step))
}

init_help() {
  cat <<'EOF'
Usage: tender init <repo> [flags]

Runs the same four steps as interactive `tender init <repo>` — write AGENTS.md,
create the three labels, lock the production boundary, create the three role
worktrees — but takes what each step proposes as a flag instead of asking,
so a caller that cannot answer a prompt (a GUI on the other end of a pipe)
can still drive it. The logic that proposes those values (detect_stack(),
suggest_tests()) does not move or duplicate — flags only override it.

Values:
  --trunk <name>       override the detected trunk branch
  --reviewer <login>   GitHub login of the account that reviews here
  --tests <cmd>        a test command line; repeat the flag for more than one
  --boundary <text>    the production boundary line for AGENTS.md.
                        --boundary '' means deliberately none — omitting the
                        flag entirely is a different thing (see below).
  Each value must be one line of plain text: a newline, carriage return, tab
  or other control character is a usage error (exit 2).

Confirmations (each defaults to the interactive "yes"):
  --yes                 answer all four confirmations, non-interactively
  --no-agents-md         skip writing AGENTS.md
  --no-labels            skip creating the three labels
  --no-environment       skip the protected "production" environment
  --no-worktrees         skip creating the three role worktrees

Setup wizard:
  --propose --json     print, as one JSON object on stdout, everything init
                        would do with these values — prerequisites, branch,
                        trunk, stack, test commands, the exact AGENTS.md text,
                        labels, environment, worktrees — and change nothing.
                        --propose requires --json (usage error otherwise).
                        Where something could not be asked (no gh, offline,
                        TENDER_NO_NETWORK), the answer is null, never a guess.
  --commit             after writing AGENTS.md, commit exactly that file on
                        the branch HEAD is on — before the worktrees are made,
                        so they contain it. Other changes stay uncommitted.
                        Never pushes. A refused commit exits 21. An AGENTS.md
                        that exists but was never committed (not in HEAD) is
                        committed the same way, so a rerun finishes a refused
                        one; one already in HEAD is left alone, edits and all.

Without --yes, this is the same interactive tool it always was — flags just
pre-fill what it proposes, and it still stops to ask. With --yes and no
--boundary, `init` refuses rather than writing an AGENTS.md with no boundary
anyone chose: a caller that forgot the flag must not silently end up with a
project that has none.

Exit codes: 0 done, 1 prerequisite error, 2 usage error, 3 nothing to do,
21-24 refused at step N (1=AGENTS.md 2=labels 3=environment 4=worktrees).
EOF
}

# Sets INIT_REPO and the INIT_* fields below from "$@". An unknown flag, a
# flag missing its value, or a second positional argument are usage errors
# (exit 2) — cmd_init() never runs with arguments it could not make sense of.
init_parse_args() {
  INIT_REPO=""
  INIT_TRUNK=""
  INIT_REVIEWER=""
  INIT_TESTS=()
  INIT_BOUNDARY=""
  INIT_BOUNDARY_GIVEN=0
  INIT_YES=0
  INIT_SKIP_AGENTS=0
  INIT_SKIP_LABELS=0
  INIT_SKIP_ENVIRONMENT=0
  INIT_SKIP_WORKTREES=0
  INIT_PROPOSE=0
  INIT_JSON=0
  INIT_COMMIT=0

  # shellcheck disable=SC2034  # every INIT_* set below is read by cmd_init()
  # in lib/init.sh after this function returns — not unused, just not read
  # from this file, the same split lib/tabs.sh and lib/tools.sh already use
  # for LAUNCH_CMD/TOOL_STATUS (see their own headers).
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) init_help; exit 0 ;;
      --trunk)
        [ $# -ge 2 ] || die "--trunk needs a value" 2
        INIT_TRUNK=$2; shift 2 ;;
      --reviewer)
        [ $# -ge 2 ] || die "--reviewer needs a value" 2
        INIT_REVIEWER=$2; shift 2 ;;
      --tests)
        [ $# -ge 2 ] || die "--tests needs a value" 2
        INIT_TESTS+=("$2"); shift 2 ;;
      --boundary)
        # $# -ge 2 accepts an empty "$2" ('--boundary ""') just as readily as
        # a real one — it only demands the flag's argument slot was filled.
        # That is the whole trick behind INIT_BOUNDARY_GIVEN: it stays 0 only
        # when --boundary never appears at all.
        [ $# -ge 2 ] || die "--boundary needs a value ('' for deliberately none)" 2
        INIT_BOUNDARY=$2; INIT_BOUNDARY_GIVEN=1; shift 2 ;;
      --yes)             INIT_YES=1; shift ;;
      --no-agents-md)    INIT_SKIP_AGENTS=1; shift ;;
      --no-labels)       INIT_SKIP_LABELS=1; shift ;;
      --no-environment)  INIT_SKIP_ENVIRONMENT=1; shift ;;
      --no-worktrees)    INIT_SKIP_WORKTREES=1; shift ;;
      --propose)         INIT_PROPOSE=1; shift ;;
      --json)            INIT_JSON=1; shift ;;
      --commit)          INIT_COMMIT=1; shift ;;
      --) shift ;;
      -*) die "unknown flag '$1' for init — see 'tender init --help'" 2 ;;
      *)
        [ -z "$INIT_REPO" ] || die "unexpected argument '$1' — repo is already '$INIT_REPO'" 2
        INIT_REPO=$1; shift ;;
    esac
  done

  # Every value lands on a line of its own in AGENTS.md (or inside one). A
  # newline would start a line of its own — a forged `trunk:` or a new
  # `## ` section — and the other control characters have no business in a
  # branch name, a login, a command line or a boundary either. [[:cntrl:]]
  # is 0x00-0x1f plus 0x7f.
  local flag value
  for flag in --trunk --reviewer --boundary; do
    case $flag in
      --trunk) value=$INIT_TRUNK ;; --reviewer) value=$INIT_REVIEWER ;; *) value=$INIT_BOUNDARY ;;
    esac
    case "$value" in *[[:cntrl:]]*) die "$flag must be one line of plain text" 2 ;; esac
  done
  if [ "${#INIT_TESTS[@]}" -gt 0 ]; then
    for value in "${INIT_TESTS[@]}"; do
      case "$value" in *[[:cntrl:]]*) die "--tests must be one line of plain text" 2 ;; esac
    done
  fi

  # JSON is only ever the output of a proposal; a proposal has no other form.
  [ "$INIT_PROPOSE" -eq 0 ] || [ "$INIT_JSON" -eq 1 ] \
    || die "--propose requires --json — see 'tender init --help'" 2
  [ "$INIT_JSON" -eq 0 ] || [ "$INIT_PROPOSE" -eq 1 ] \
    || die "--json only goes with --propose — see 'tender init --help'" 2
}
