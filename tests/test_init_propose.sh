#!/usr/bin/env bash
# `tender init --propose --json` and `tender init --commit` (app issue #6, the
# setup wizard): the proposal changes nothing and renders AGENTS.md exactly
# as init writes it; --commit commits exactly AGENTS.md before the worktrees
# exist, and nothing else.
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
TENDER="$PWD/bin/tender"
make_sandbox
STUB=$(mktemp -d)
cleanup() { rm -rf "$SANDBOX" "$STUB"; }
trap cleanup EXIT
export TENDER_NO_NETWORK=1 TENDER_DRY_RUN=1
# The commits in here must not depend on the machine's git configuration: a
# global core.hooksPath, commit.gpgsign or missing identity would change
# whether --commit succeeds. No global or system config at all; each test
# repo carries its own identity.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# A fresh repo in the sandbox with one commit; $1 is its name.
fresh_repo() {
  git init -q -b main "$SANDBOX/$1"
  git -C "$SANDBOX/$1" config user.name t
  git -C "$SANDBOX/$1" config user.email t@e
  git -C "$SANDBOX/$1" commit -q --allow-empty -m init
}

# A pre-commit hook in repo $1 that refuses every commit.
refusing_hook() {
  printf '#!/bin/sh\necho "hook says no" >&2\nexit 1\n' > "$SANDBOX/$1/.git/hooks/pre-commit"
  chmod +x "$SANDBOX/$1/.git/hooks/pre-commit"
}

# Field $2 (a Python expression over `d`) of the JSON in $1, printed as JSON
# — so a string keeps its quotes and null/true/"null"/"true" stay apart;
# "INVALID" if $1 is not JSON at all — a real parser, not a pattern match.
# The eval runs only the expressions written in this file, never anything
# from tender's output.
jget() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("INVALID: %s" % e); sys.exit(0)
v = eval(sys.argv[1])
print(json.dumps(v), end="")
' "$2"
}

# Everything a proposal must leave exactly as it found it.
snapshot() {
  local d="$SANDBOX/$1" exclude
  exclude=$(git -C "$d" rev-parse --git-path info/exclude)
  case "$exclude" in /*) : ;; *) exclude="$d/$exclude" ;; esac
  printf 'status:%s\nexclude:%s\nworktrees:%s\nhead:%s\nagents:%s\nwtdir:%s\n' \
    "$(git -C "$d" status --porcelain --ignored)" "$(cat "$exclude" 2>/dev/null)" \
    "$(git -C "$d" worktree list --porcelain)" "$(git -C "$d" rev-parse HEAD)" \
    "$([ -e "$d/AGENTS.md" ] && echo yes || echo no)" \
    "$([ -e "$d/.worktrees" ] && echo yes || echo no)"
}

# The AGENTS.md text a proposal in $1 carries, written to file $2 byte for byte.
proposed_content() {
  printf '%s' "$1" | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["agents_md"]["content"])' > "$2"
}

echo "tender init --propose --json: offline, it describes and changes nothing"
fresh_repo acme
touch "$SANDBOX/acme/package.json"
before=$(snapshot acme)
out=$("$TENDER" init acme --propose --json 2>/dev/null)
check "exits 0" "0" "$?"
check "is one valid JSON object" '"dict"' "$(jget "$out" 'type(d).__name__')"
after=$(snapshot acme)
check "no side effects: status, exclude, worktrees, HEAD, files all unchanged" "$before" "$after"
check "repo" '"acme"' "$(jget "$out" 'd["repo"]')"
check "dir is absolute" "\"$SANDBOX/acme\"" "$(jget "$out" 'd["dir"]')"
check "prerequisites name git gh tmux" '["gh", "git", "tmux"]' "$(jget "$out" 'sorted(d["prerequisites"])')"
check "prerequisite git is a boolean true" "true" "$(jget "$out" 'd["prerequisites"]["git"]')"
check "branch is what HEAD is on" '"main"' "$(jget "$out" 'd["branch"]')"
check "trunk as init would use it" '"main"' "$(jget "$out" 'd["trunk"]')"
check "stack is detect_stack() as a list" '["Node"]' "$(jget "$out" 'd["stack"]')"
check "tests are suggest_tests() for that stack" '["pnpm lint", "pnpm test", "pnpm build"]' "$(jget "$out" 'd["tests"]')"
check "agents_md.path" "\"$SANDBOX/acme/AGENTS.md\"" "$(jget "$out" 'd["agents_md"]["path"]')"
check "agents_md.exists false" "false" "$(jget "$out" 'd["agents_md"]["exists"]')"
check "agents_md.committed false when there is none yet" "false" "$(jget "$out" 'd["agents_md"]["committed"]')"
check "agents_md.content is the AGENTS.md text" "true" "$(jget "$out" 'd["agents_md"]["content"].startswith("# Agents in this project\n")')"
check "boundary_given false without --boundary" "false" "$(jget "$out" 'd["boundary_given"]')"
check "labels.names" '["ready", "needs-decision", "approved"]' "$(jget "$out" 'd["labels"]["names"]')"
check "labels.existing is null offline — never guessed" "null" "$(jget "$out" 'd["labels"]["existing"]')"
check "environment.name" '"production"' "$(jget "$out" 'd["environment"]["name"]')"
check "environment.slug null offline" "null" "$(jget "$out" 'd["environment"]["slug"]')"
check "environment.exists null offline" "null" "$(jget "$out" 'd["environment"]["exists"]')"
check "three worktrees, in role order" '["developer", "reviewer", "maintainer"]' "$(jget "$out" '[w["role"] for w in d["worktrees"]]')"
check "worktree path" "\"$SANDBOX/acme/.worktrees/acme-reviewer\"" "$(jget "$out" 'd["worktrees"][1]["path"]')"
check "worktree branch" '"acme-reviewer"' "$(jget "$out" 'd["worktrees"][1]["branch"]')"
check "worktree exists false" "false" "$(jget "$out" 'd["worktrees"][1]["exists"]')"

echo "tender init --propose --json: an unknown stack is an empty list"
fresh_repo bare
out=$("$TENDER" init bare --propose --json 2>/dev/null)
check "stack []" "[]" "$(jget "$out" 'd["stack"]')"

echo "tender init --propose --json: value flags are rendered by the core, quotes and backslashes included"
tricky='deploy "prod" \ now \n is not a newline — nor is \t'
out=$("$TENDER" init acme --propose --json --trunk release --reviewer octocat \
  --tests 'pnpm test -- --grep "a\b"' --tests 'second' --boundary "$tricky" 2>/dev/null)
check "still valid JSON" '"dict"' "$(jget "$out" 'type(d).__name__')"
check "trunk from --trunk" '"release"' "$(jget "$out" 'd["trunk"]')"
check "branch is still what HEAD is on" '"main"' "$(jget "$out" 'd["branch"]')"
check "tests from --tests, one element per flag, exactly" \
  '["pnpm test -- --grep \"a\\b\"", "second"]' "$(jget "$out" 'd["tests"]')"
check "boundary_given true" "true" "$(jget "$out" 'd["boundary_given"]')"
check "the boundary survives the round trip byte for byte" "yes" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if "\n    " + sys.argv[1] + "\n" in d["agents_md"]["content"] else "no", end="")' "$tricky")"
check "the multi-line content keeps its newlines" "true" "$(jget "$out" 'd["agents_md"]["content"].count("\n") > 30')"
check "--boundary '' counts as given" "true" \
  "$(jget "$("$TENDER" init acme --propose --json --boundary '' 2>/dev/null)" 'd["boundary_given"]')"

echo "json_escape (lib/json.sh): every control character comes out as valid JSON"
all=$(printf 'q" b\\ n\n r\r t\t b\b f\f x\001\002\003\004\005\006\007\013\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037 del\177 ü —')
decoded=$(bash -c '. lib/json.sh; json_string "$1"' _ "$all" \
  | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin))')
check "round-trips through a real JSON parser unchanged" "$all" "$decoded"

echo "tender init --propose --json: its AGENTS.md is byte-identical to the one init writes"
fresh_repo same
args=(--reviewer octocat --tests 'pnpm test' --tests 'say "hi" \ there' --boundary "$tricky")
out=$("$TENDER" init same --propose --json "${args[@]}" 2>/dev/null)
proposed_content "$out" "$SANDBOX/proposed.md"
"$TENDER" init same "${args[@]}" --yes --no-worktrees >/dev/null 2>&1
check "init wrote the file" "yes" "$([ -f "$SANDBOX/same/AGENTS.md" ] && echo yes || echo no)"
check "byte-identical (cmp)" "same" "$(cmp -s "$SANDBOX/proposed.md" "$SANDBOX/same/AGENTS.md" && echo same || echo differ)"
fresh_repo plain
out=$("$TENDER" init plain --propose --json 2>/dev/null)
proposed_content "$out" "$SANDBOX/proposed-plain.md"
TENDER_YES=1 "$TENDER" init plain --no-worktrees >/dev/null 2>&1
check "byte-identical with no flags at all (placeholders)" "same" \
  "$(cmp -s "$SANDBOX/proposed-plain.md" "$SANDBOX/plain/AGENTS.md" && echo same || echo differ)"

echo "tender init --propose --json: an existing AGENTS.md is reported, not re-rendered"
out=$("$TENDER" init same --propose --json 2>/dev/null)
check "exists true" "true" "$(jget "$out" 'd["agents_md"]["exists"]')"
check "committed false: on disk, never committed" "false" "$(jget "$out" 'd["agents_md"]["committed"]')"
check "content null" "null" "$(jget "$out" 'd["agents_md"]["content"]')"

echo "tender init --propose --json: existing worktrees are reported"
"$TENDER" init same --yes --boundary '' --no-agents-md >/dev/null 2>&1
out=$("$TENDER" init same --propose --json 2>/dev/null)
check "worktree exists true" "true" "$(jget "$out" 'd["worktrees"][0]["exists"]')"

echo "tender init --propose --json: --commit does not change the proposal"
a=$("$TENDER" init acme --propose --json 2>/dev/null)
b=$("$TENDER" init acme --propose --json --commit 2>/dev/null)
check "identical output" "$a" "$b"

echo "tender init --propose: usage and prerequisite errors"
out=$("$TENDER" init acme --propose 2>&1)
check "--propose without --json exits 2" "2" "$?"
contains "says --propose requires --json" "--propose requires --json" "$out"
out=$("$TENDER" init acme --json 2>&1)
check "--json without --propose exits 2" "2" "$?"
out=$("$TENDER" init nosuch --propose --json 2>/dev/null)
check "not a git repository exits 1" "1" "$?"
check "and prints nothing on stdout" "" "$out"
out=$("$TENDER" init --help 2>&1)
contains "--help documents --propose" "--propose requires --json" "$out"
contains "--help documents --commit" "--commit" "$out"
contains "--help documents the one-line rule" "one line of plain text" "$out"

echo "tender init: a value flag holding a control character is a usage error"
# A newline in --trunk would put a second, forged line into AGENTS.md; the
# rule is the same for all four flags and for init and --propose alike.
for flag in --trunk --reviewer --tests --boundary; do
  for pair in "newline:"$'\n' "carriage return:"$'\r' "tab:"$'\t'; do
    what=${pair%%:*} ch=${pair#*:}
    # --yes so a run that got through would write, and the check below saw it;
    # --boundary '' only for the other flags, or it would replace the value.
    if [ "$flag" = --boundary ]; then extra=(); else extra=(--boundary ''); fi
    out=$("$TENDER" init acme "$flag" "a${ch}b" --yes ${extra[@]+"${extra[@]}"} 2>&1)
    check "$flag with a $what exits 2" "2" "$?"
    contains "$flag with a $what: says why" "$flag must be one line of plain text" "$out"
  done
done
out=$("$TENDER" init acme --propose --json --reviewer "$(printf 'a\177b')" 2>&1)
check "--propose too, and DEL (0x7f) too: exits 2" "2" "$?"
check "and prints no JSON" "" "$(printf '%s' "$out" | grep '^{')"
check "nothing was written by the refused runs" "no" "$([ -f "$SANDBOX/acme/AGENTS.md" ] && echo yes || echo no)"

echo "tender init --propose --json: with network, only the allowed read-only gh calls"
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$*" in
  "label list"*)
    [ -n "${GH_LABELS_FAIL:-}" ] && { echo "could not connect" >&2; exit 1; }
    printf 'Ready\nbug\napproved-ish\n' ;;
  "repo view"*) echo "owner/acme" ;;
  "api repos/owner/acme/environments/production")
    case "${GH_ENV:-404}" in
      yes) echo "{}" ;;
      404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      *)   echo "error connecting to api.github.com" >&2; exit 1 ;;
    esac ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUBEOF
chmod +x "$STUB/gh"
# Every call --propose may make, exactly. Anything else in the log — a
# create, a PUT, a new read nobody reviewed — fails the check below.
cat > "$STUB/allowed" <<'ALLOWEOF'
label list --limit 1000 --json name --jq .[].name
repo view --json nameWithOwner --jq .nameWithOwner
api repos/owner/acme/environments/production
ALLOWEOF
export GH_CALLS="$STUB/calls"; : > "$GH_CALLS"
before=$(snapshot acme)
out=$(PATH="$STUB:$PATH" TENDER_NO_NETWORK='' "$TENDER" init acme --propose --json 2>/dev/null)
check "exits 0 and is valid JSON" '"dict"' "$(jget "$out" 'type(d).__name__')"
check "no side effects with network either" "$before" "$(snapshot acme)"
check "the gh log holds exactly the allowed calls, each once" \
  "$(sort "$STUB/allowed")" "$(sort "$GH_CALLS")"
check "labels.existing: case-insensitive, only the three names, named as init names them" \
  '["ready"]' "$(jget "$out" 'd["labels"]["existing"]')"
check "environment.slug" '"owner/acme"' "$(jget "$out" 'd["environment"]["slug"]')"
check "a 404 means the environment does not exist" "false" "$(jget "$out" 'd["environment"]["exists"]')"
out=$(PATH="$STUB:$PATH" TENDER_NO_NETWORK='' GH_ENV=yes "$TENDER" init acme --propose --json 2>/dev/null)
check "a 200 means it exists" "true" "$(jget "$out" 'd["environment"]["exists"]')"
: > "$GH_CALLS"
out=$(PATH="$STUB:$PATH" TENDER_NO_NETWORK='' GH_ENV=down GH_LABELS_FAIL=1 "$TENDER" init acme --propose --json 2>/dev/null)
check "any other failure is null, not false" "null" "$(jget "$out" 'd["environment"]["exists"]')"
check "labels that could not be listed are null, not []" "null" "$(jget "$out" 'd["labels"]["existing"]')"
check "failures add no other gh calls" "" "$(grep -vxF -f "$STUB/allowed" "$GH_CALLS")"

echo "tender init --commit: commits exactly AGENTS.md, before the worktrees"
fresh_repo com
printf 'one\n' > "$SANDBOX/com/tracked.txt"
git -C "$SANDBOX/com" add tracked.txt && git -C "$SANDBOX/com" commit -q -m tracked
printf 'two\n' > "$SANDBOX/com/tracked.txt"           # unstaged change
printf 'staged\n' > "$SANDBOX/com/staged.txt"
git -C "$SANDBOX/com" add staged.txt                   # staged, unrelated
head_before=$(git -C "$SANDBOX/com" rev-parse HEAD)
out=$("$TENDER" init com --yes --boundary 'npm publish' --commit 2>&1)
check "exits 0" "0" "$?"
check "one new commit on top of the old HEAD" "$head_before" "$(git -C "$SANDBOX/com" rev-parse HEAD~1)"
check "its message" "Add AGENTS.md (tender init)" "$(git -C "$SANDBOX/com" log -1 --format=%s)"
check "it contains exactly AGENTS.md" "AGENTS.md" "$(git -C "$SANDBOX/com" show --name-only --format= HEAD)"
check "still on the same branch" "main" "$(git -C "$SANDBOX/com" symbolic-ref --short HEAD)"
check "the unrelated staged file stays staged" "staged.txt" "$(git -C "$SANDBOX/com" diff --cached --name-only)"
check "the unstaged change stays unstaged" "tracked.txt" "$(git -C "$SANDBOX/com" diff --name-only)"
for role in developer reviewer maintainer; do
  check "the $role worktree already contains AGENTS.md" "yes" \
    "$([ -f "$SANDBOX/com/.worktrees/com-$role/AGENTS.md" ] && echo yes || echo no)"
done
lacks "the closing text drops the commit-and-pull step" "Commit AGENTS.md, then update" "$out"
lacks "no pull needed: every worktree is younger than the commit" "pull $SANDBOX/com" "$out"
contains "and renumbers the steps after it" "2. Put the reviewer account's login" "$out"
out=$("$TENDER" init com --propose --json 2>/dev/null)
check "the proposal now says committed" "true" "$(jget "$out" 'd["agents_md"]["committed"]')"

echo "tender init --commit: an AGENTS.md already in HEAD is left alone, edits and all"
printf 'my edit\n' >> "$SANDBOX/com/AGENTS.md"
head_before=$(git -C "$SANDBOX/com" rev-parse HEAD)
"$TENDER" init com --yes --boundary 'npm publish' --commit >/dev/null 2>&1
check "exits nothing-to-do (3), not an error" "3" "$?"
check "no commit" "$head_before" "$(git -C "$SANDBOX/com" rev-parse HEAD)"
check "the edit stays an uncommitted edit" "AGENTS.md" "$(git -C "$SANDBOX/com" diff --name-only -- AGENTS.md)"
fresh_repo skip
head_before=$(git -C "$SANDBOX/skip" rev-parse HEAD)
"$TENDER" init skip --yes --no-agents-md --no-worktrees --commit >/dev/null 2>&1
check "--no-agents-md: exits 3" "3" "$?"
check "--no-agents-md: no commit" "$head_before" "$(git -C "$SANDBOX/skip" rev-parse HEAD)"

echo "tender init --commit: a refused commit is step 1 refused — and a rerun finishes it"
fresh_repo hook
refusing_hook hook
head_before=$(git -C "$SANDBOX/hook" rev-parse HEAD)
err=$("$TENDER" init hook --yes --boundary 'npm publish' --commit 2>&1 >/dev/null)
check "exits 21" "21" "$?"
contains "names step 1" "refused at step 1 (AGENTS.md)" "$err"
contains "gives git's reason" "hook says no" "$err"
check "AGENTS.md stays written" "yes" "$([ -f "$SANDBOX/hook/AGENTS.md" ] && echo yes || echo no)"
check "nothing committed" "$head_before" "$(git -C "$SANDBOX/hook" rev-parse HEAD)"
check "AGENTS.md is not left staged" "" "$(git -C "$SANDBOX/hook" diff --cached --name-only)"
check "later steps did not run: no worktrees" "no" "$([ -d "$SANDBOX/hook/.worktrees" ] && echo yes || echo no)"
out=$("$TENDER" init hook --propose --json 2>/dev/null)
check "the proposal: exists, not committed" "[true, false]" \
  "$(jget "$out" '[d["agents_md"]["exists"], d["agents_md"]["committed"]]')"
rm "$SANDBOX/hook/.git/hooks/pre-commit"
out=$("$TENDER" init hook --yes --boundary 'npm publish' --commit 2>&1)
check "the rerun, cause fixed: exits 0" "0" "$?"
check "the rerun commits the never-committed AGENTS.md" "AGENTS.md" \
  "$(git -C "$SANDBOX/hook" show --name-only --format= HEAD)"
check "on top of the old HEAD" "$head_before" "$(git -C "$SANDBOX/hook" rev-parse HEAD~1)"
for role in developer reviewer maintainer; do
  check "the $role worktree contains it" "yes" \
    "$([ -f "$SANDBOX/hook/.worktrees/hook-$role/AGENTS.md" ] && echo yes || echo no)"
done

echo "tender init --commit: worktrees from an earlier run still need the pull"
fresh_repo older
"$TENDER" init older --yes --boundary '' --no-agents-md >/dev/null 2>&1
out=$("$TENDER" init older --yes --boundary 'npm publish' --commit 2>&1)
check "exits 0" "0" "$?"
check "committed" "Add AGENTS.md (tender init)" "$(git -C "$SANDBOX/older" log -1 --format=%s)"
lacks "does not ask to commit what is committed" "Commit AGENTS.md, then update" "$out"
contains "keeps the pull step for the older worktrees" "2. Update the worktrees that existed before this run" "$out"
contains "names the pull" "git -C $SANDBOX/older/.worktrees/older-developer  pull $SANDBOX/older main" "$out"

echo "tender init --commit: a refused commit restores the index exactly"
# A deletion the user had staged: `git reset` would bring HEAD's AGENTS.md
# back into the index and silently unstage it.
fresh_repo staged-del
printf 'old\n' > "$SANDBOX/staged-del/AGENTS.md"
git -C "$SANDBOX/staged-del" add AGENTS.md && git -C "$SANDBOX/staged-del" commit -q -m old
git -C "$SANDBOX/staged-del" rm -q AGENTS.md
refusing_hook staged-del
"$TENDER" init staged-del --yes --boundary 'npm publish' --commit >/dev/null 2>&1
check "exits 21" "21" "$?"
check "the staged deletion is still staged" "$(printf 'D\tAGENTS.md')" \
  "$(git -C "$SANDBOX/staged-del" diff --cached --name-status)"
check "the new AGENTS.md stays written" "yes" "$([ -f "$SANDBOX/staged-del/AGENTS.md" ] && echo yes || echo no)"
# A version the user had staged, different from the one on disk.
fresh_repo staged-blob
printf 'v1\n' > "$SANDBOX/staged-blob/AGENTS.md"
git -C "$SANDBOX/staged-blob" add AGENTS.md
printf 'v2\n' > "$SANDBOX/staged-blob/AGENTS.md"
entry_before=$(git -C "$SANDBOX/staged-blob" ls-files -s AGENTS.md)
refusing_hook staged-blob
"$TENDER" init staged-blob --yes --boundary 'npm publish' --commit >/dev/null 2>&1
check "exits 21" "21" "$?"
check "the staged v1 is still the staged entry" "$entry_before" "$(git -C "$SANDBOX/staged-blob" ls-files -s AGENTS.md)"
check "v2 still on disk" "v2" "$(cat "$SANDBOX/staged-blob/AGENTS.md")"

echo "tender init without --commit: unchanged — writes, does not commit"
fresh_repo nocom
head_before=$(git -C "$SANDBOX/nocom" rev-parse HEAD)
out=$("$TENDER" init nocom --yes --boundary 'npm publish' 2>&1)
check "exits 0" "0" "$?"
check "no commit" "$head_before" "$(git -C "$SANDBOX/nocom" rev-parse HEAD)"
check "AGENTS.md untracked, as before" "?? AGENTS.md" "$(git -C "$SANDBOX/nocom" status --porcelain AGENTS.md)"
contains "still tells you to commit and pull" "2. Commit AGENTS.md, then update" "$out"
contains "keeps the later steps' numbers" "6. Start working:" "$out"

summary
