#!/usr/bin/env bash
# JSON string escaping, shared by every subcommand that prints --json:
# `tender claims --json` (lib/claims.sh) and `tender init --propose --json`
# (lib/init_propose.sh). One escaper, so a value that survives one of them
# survives the other.
#
# Sourced by bin/tender on demand, before whichever of those files needs it.
#
# Needs from bin/tender: nothing
# Provides to it:     json_escape(), json_string()

# $1 escaped for use between double quotes in JSON: backslash, quote, the
# named control characters, and every other control character as \u00XX —
# all of them, since a multi-line AGENTS.md or a test command a user typed can
# carry any of them. Escaped newlines are still one line of output, so a
# record-per-line format (claims) stays one line per record. Bash strings
# cannot hold NUL, so there is none to escape.
json_escape() {
  local s=$1 i hex c
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  # The rest of 0x01-0x1f (8-10, 12 and 13 are handled above). printf -v
  # rather than $(...) keeps this free of subshells; measured to work on
  # macOS's bash 3.2, including \001, which bash uses internally.
  for i in 1 2 3 4 5 6 7 11 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    printf -v hex '%02x' "$i"
    printf -v c "\\x$hex"
    case "$s" in *"$c"*) s=${s//"$c"/\\u00$hex} ;; esac
  done
  printf '%s' "$s"
}

# $1 as a complete JSON string, quotes included.
json_string() { printf '"%s"' "$(json_escape "$1")"; }
