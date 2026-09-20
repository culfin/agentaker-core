#!/usr/bin/env bash
# SessionStart hook: emit this worktree's role.
#
# Convenience only. The supported path is `wtc <repo> <role>`, which works with
# any coding agent. This exists for sessions started by hand in a worktree that
# already has a .agents/ROLE.
#
# Fail-open throughout: a missing or unreadable file never stops a session.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
ROLES_DIR="${WTC_ROLES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/roles}"
ROLE_FILE="$PROJECT_DIR/.agents/ROLE"

[ -f "$ROLE_FILE" ] || exit 0
role=$(tr -d '[:space:]' < "$ROLE_FILE" 2>/dev/null) || exit 0
[ -n "$role" ] || exit 0

# A role is a file stem, never a path.
case "$role" in
  *[!a-z0-9_-]*|-*) printf 'worktree-crew: no role file for "%s".\n' "$role"; exit 0 ;;
esac

if [ ! -f "$ROLES_DIR/$role.md" ]; then
  printf 'worktree-crew: no role file for "%s".\n' "$role"
  exit 0
fi

cat "$ROLES_DIR/_base.md" 2>/dev/null
printf '\n\n'
cat "$ROLES_DIR/$role.md" 2>/dev/null
exit 0
