#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
TENDER="$PWD/bin/tender"
make_sandbox
trap 'rm -rf "$SANDBOX"' EXIT

echo "tender status: arguments"
out=$(TENDER_OWNER= "$TENDER" status 2>&1); check "no owner exits 1" "1" "$?"
contains "no owner is explained" "owner" "$out"

echo "tender status: sections"
# gh is stubbed so the test needs neither network nor credentials.
STUB=$(mktemp -d); trap 'rm -rf "$SANDBOX" "$STUB"' EXIT
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
# Records its arguments and prints one fake row, so the test can assert
# both the output shape and the search terms used.
printf '%s\n' "$*" >> "$GH_CALLS"
echo "  demo#1  a fake row"
STUBEOF
chmod +x "$STUB/gh"
export GH_CALLS="$STUB/calls"
: > "$GH_CALLS"

echo "tender status: sections, without a reviewer login"
out=$(PATH="$STUB:$PATH" TENDER_REVIEWER= "$TENDER" status someowner 2>&1)
contains "shows ready work" "ready to pick up" "$out"
contains "shows review queue" "waiting for review" "$out"
contains "shows merge queue" "approved" "$out"
contains "shows human queue" "waiting on you" "$out"
contains "admits the queue is approximate" "TENDER_REVIEWER" "$out"
contains "notes that blocked issues are already counted, when there is a row to count" \
  "blocked issues are counted here" "$out"

calls=$(cat "$GH_CALLS")
contains "asks for the ready label" "--label ready" "$calls"
contains "falls back to review none" "review none" "$calls"
contains "asks for approved PRs" "review approved" "$calls"
contains "asks for decisions" "needs-decision" "$calls"
# This proves the filter is REQUESTED, not that it filters: the stub replaces gh,
# so the --jq expression never runs. Real filtering is verified against a live
# organisation — see the task report.
contains "filters out dependabot" "dependabot" "$calls"

echo "tender status: with a reviewer login"
: > "$GH_CALLS"
out=$(PATH="$STUB:$PATH" TENDER_REVIEWER=somereviewer "$TENDER" status someowner 2>&1)
calls=$(cat "$GH_CALLS")
contains "asks for that reviewer's queue" "review-requested somereviewer" "$calls"
lacks "does not fall back" "review none" "$calls"
lacks "no approximation notice" "TENDER_REVIEWER" "$out"

echo "tender status: the blocked-issues note is section-specific, not unconditional"
# gh search issues has no dependency filter (see bin/tender's comment above the
# call) — the note is compensating for that gap, so it must track whether the
# READY section actually had a row, not just print unconditionally. A stub
# that returns a row for every section except "ready" isolates that.
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$*" in
  *"--label ready"*) ;;  # no rows — an empty "ready to pick up" section
  *) echo "  demo#1  a fake row" ;;
esac
STUBEOF
chmod +x "$STUB/gh"
: > "$GH_CALLS"
out=$(PATH="$STUB:$PATH" TENDER_REVIEWER=r "$TENDER" status someowner 2>&1)
contains "still reports an empty ready section" "(none)" "$out"
lacks "says nothing about blocked issues when there was nothing to count" \
  "blocked issues are counted here" "$out"

echo "tender status: a failed query is not an empty board"
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
echo "gh: could not authenticate" >&2
exit 1
STUBEOF
chmod +x "$STUB/gh"
out=$(PATH="$STUB:$PATH" TENDER_REVIEWER=r "$TENDER" status someowner 2>&1)
check "failed queries exit 1" "1" "$?"
contains "says it could not ask" "could not ask" "$out"
lacks "does not claim an empty queue" "(none)" "$out"
contains "warns the board is incomplete" "incomplete" "$out"
lacks "says nothing about blocked issues when the ready query itself failed" \
  "blocked issues are counted here" "$out"

echo "tender attach: arguments"
out=$("$TENDER" attach 2>&1); check "attach without repo exits 2" "2" "$?"

echo "tender attach: missing tmux is diagnosed as missing tmux"
# Hide only the tmux binary, not whatever directory it lives in: on GitHub's
# ubuntu-latest runner both tmux AND bash live in /usr/bin, so dropping that
# directory from PATH broke the script's own "#!/usr/bin/env bash" shebang
# (exit 127) instead of exercising the tmux check — passed locally (Homebrew
# keeps tmux in /opt/homebrew/bin, away from bash) and failed in CI for a
# reason that had nothing to do with the code under test. Shadow each PATH
# directory that contains tmux with a symlink copy of everything else in it,
# so every other tool the script needs stays reachable.
NOTMUX_TMP=$(mktemp -d)
NOTMUX_PATH=""
IFS=':' read -ra path_dirs <<< "$PATH"
for dir in "${path_dirs[@]}"; do
    if [ -x "$dir/tmux" ]; then
        shadow="$NOTMUX_TMP${dir//\//_}"
        mkdir -p "$shadow"
        for entry in "$dir"/*; do
            [ "$(basename "$entry")" = "tmux" ] && continue
            ln -s "$entry" "$shadow/$(basename "$entry")" 2>/dev/null
        done
        NOTMUX_PATH="$NOTMUX_PATH:$shadow"
    else
        NOTMUX_PATH="$NOTMUX_PATH:$dir"
    fi
done
out=$(PATH="${NOTMUX_PATH#:}" "$TENDER" attach demo 2>&1)
check "exits 1" "1" "$?"
contains "names tmux" "tmux is not installed" "$out"
rm -rf "$NOTMUX_TMP"

echo "tender status: an issue on hold is not 'ready to pick up' (issue #6)"
# Here the --jq expression really runs: a gh stand-in applies it, with a real
# jq, to a listing with one held and one free issue.
if command -v jq >/dev/null 2>&1; then
  JQSTUB=$(mktemp -d)
  cat > "$JQSTUB/gh" <<'JQEOF'
#!/usr/bin/env bash
q=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && q=$a; prev=$a; done
case "$*" in
  *"--label ready"*)
    printf '[{"repository":{"name":"acme"},"number":1,"title":"free","labels":[{"name":"ready"}]},{"repository":{"name":"acme"},"number":2,"title":"held","labels":[{"name":"ready"},{"name":"needs-decision"}]}]' | jq -r "$q" ;;
esac
exit 0
JQEOF
  chmod +x "$JQSTUB/gh"
  out=$(PATH="$JQSTUB:$PATH" TENDER_REVIEWER=r "$TENDER" status someowner 2>&1)
  contains "a free ready issue is listed" "acme#1  free" "$out"
  lacks "a held one is not" "acme#2  held" "$out"
  rm -rf "$JQSTUB"
else
  echo "  skip (jq not installed — the --jq expression needs a real jq to run)"
fi

summary
