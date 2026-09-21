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
# The commits in here must not depend on whether the machine running the
# tests has a git identity configured.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e

# A fresh repo in the sandbox with one commit; $1 is its name.
fresh_repo() {
  git init -q -b main "$SANDBOX/$1"
  git -C "$SANDBOX/$1" commit -q --allow-empty -m init
}

# Field $2 (a Python expression over `d`) of the JSON in $1; "INVALID" if $1
# is not JSON at all — a real parser, not a pattern match. The eval runs only
# the expressions written in this file, never anything from tender's output.
jget() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("INVALID: %s" % e); sys.exit(0)
v = eval(sys.argv[1])
print(json.dumps(v) if not isinstance(v, str) else v, end="")
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

echo "tender init --propose --json: offline, it describes and changes nothing"
fresh_repo acme
touch "$SANDBOX/acme/package.json"
before=$(snapshot acme)
out=$("$TENDER" init acme --propose --json 2>/dev/null)
check "exits 0" "0" "$?"
check "is one valid JSON object" "dict" "$(jget "$out" 'type(d).__name__')"
after=$(snapshot acme)
check "no side effects: status, exclude, worktrees, HEAD, files all unchanged" "$before" "$after"
check "repo" "acme" "$(jget "$out" 'd["repo"]')"
check "dir is absolute" "$SANDBOX/acme" "$(jget "$out" 'd["dir"]')"
check "prerequisites name git gh tmux" '["gh", "git", "tmux"]' "$(jget "$out" 'sorted(d["prerequisites"])')"
check "prerequisite git is a boolean true" "true" "$(jget "$out" 'd["prerequisites"]["git"]')"
check "branch is what HEAD is on" "main" "$(jget "$out" 'd["branch"]')"
check "trunk as init would use it" "main" "$(jget "$out" 'd["trunk"]')"
check "stack is detect_stack() as a list" '["Node"]' "$(jget "$out" 'd["stack"]')"
check "tests are suggest_tests() for that stack" '["pnpm lint", "pnpm test", "pnpm build"]' "$(jget "$out" 'd["tests"]')"
check "agents_md.path" "$SANDBOX/acme/AGENTS.md" "$(jget "$out" 'd["agents_md"]["path"]')"
check "agents_md.exists false" "false" "$(jget "$out" 'd["agents_md"]["exists"]')"
contains "agents_md.content is the AGENTS.md text" "# Agents in this project" "$(jget "$out" 'd["agents_md"]["content"]')"
check "boundary_given false without --boundary" "false" "$(jget "$out" 'd["boundary_given"]')"
check "labels.names" '["ready", "needs-decision", "approved"]' "$(jget "$out" 'd["labels"]["names"]')"
check "labels.existing is null offline — never guessed" "null" "$(jget "$out" 'd["labels"]["existing"]')"
check "environment.name" "production" "$(jget "$out" 'd["environment"]["name"]')"
check "environment.slug null offline" "null" "$(jget "$out" 'd["environment"]["slug"]')"
check "environment.exists null offline" "null" "$(jget "$out" 'd["environment"]["exists"]')"
check "three worktrees, in role order" '["developer", "reviewer", "maintainer"]' "$(jget "$out" '[w["role"] for w in d["worktrees"]]')"
check "worktree path" "$SANDBOX/acme/.worktrees/acme-reviewer" "$(jget "$out" 'd["worktrees"][1]["path"]')"
check "worktree branch" "acme-reviewer" "$(jget "$out" 'd["worktrees"][1]["branch"]')"
check "worktree exists false" "false" "$(jget "$out" 'd["worktrees"][1]["exists"]')"

echo "tender init --propose --json: an unknown stack is an empty list"
fresh_repo bare
out=$("$TENDER" init bare --propose --json 2>/dev/null)
check "stack []" "[]" "$(jget "$out" 'd["stack"]')"

echo "tender init --propose --json: value flags are rendered by the core, quotes, backslashes and newlines included"
nasty=$'deploy "prod" \\ now\n\tsecond line \001 end'
out=$("$TENDER" init acme --propose --json --trunk release --reviewer octocat \
  --tests 'pnpm test -- --grep "a\b"' --tests $'two\nlines' --boundary "$nasty" 2>/dev/null)
check "still valid JSON" "dict" "$(jget "$out" 'type(d).__name__')"
check "trunk from --trunk" "release" "$(jget "$out" 'd["trunk"]')"
check "branch is still what HEAD is on" "main" "$(jget "$out" 'd["branch"]')"
check "tests from --tests, one element per flag, exactly" \
  '["pnpm test -- --grep \"a\\b\"", "two\nlines"]' "$(jget "$out" 'd["tests"]')"
check "boundary_given true" "true" "$(jget "$out" 'd["boundary_given"]')"
check "the boundary survives the round trip byte for byte" "yes" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if sys.argv[1] in d["agents_md"]["content"] else "no", end="")' "$nasty")"
check "--boundary '' counts as given" "true" \
  "$(jget "$("$TENDER" init acme --propose --json --boundary '' 2>/dev/null)" 'd["boundary_given"]')"

echo "tender init --propose --json: its AGENTS.md is byte-identical to the one init writes"
fresh_repo same
args=(--reviewer octocat --tests 'pnpm test' --tests 'say "hi" \ there' --boundary "$nasty")
out=$("$TENDER" init same --propose --json "${args[@]}" 2>/dev/null)
printf '%s' "$out" | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["agents_md"]["content"])' > "$SANDBOX/proposed.md"
"$TENDER" init same "${args[@]}" --yes --no-worktrees >/dev/null 2>&1
check "init wrote the file" "yes" "$([ -f "$SANDBOX/same/AGENTS.md" ] && echo yes || echo no)"
check "byte-identical (cmp)" "same" "$(cmp -s "$SANDBOX/proposed.md" "$SANDBOX/same/AGENTS.md" && echo same || echo differ)"
fresh_repo plain
out=$("$TENDER" init plain --propose --json 2>/dev/null)
printf '%s' "$out" | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["agents_md"]["content"])' > "$SANDBOX/proposed-plain.md"
TENDER_YES=1 "$TENDER" init plain --no-worktrees >/dev/null 2>&1
check "byte-identical with no flags at all (placeholders)" "same" \
  "$(cmp -s "$SANDBOX/proposed-plain.md" "$SANDBOX/plain/AGENTS.md" && echo same || echo differ)"

echo "tender init --propose --json: an existing AGENTS.md is reported, not re-rendered"
out=$("$TENDER" init same --propose --json 2>/dev/null)
check "exists true" "true" "$(jget "$out" 'd["agents_md"]["exists"]')"
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

echo "tender init --propose --json: with network, only read-only gh calls"
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$*" in
  "label list"*)
    [ -n "${GH_LABELS_FAIL:-}" ] && { echo "could not connect" >&2; exit 1; }
    printf 'ready\nbug\napproved-ish\n' ;;
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
export GH_CALLS="$STUB/calls"; : > "$GH_CALLS"
before=$(snapshot acme)
out=$(PATH="$STUB:$PATH" TENDER_NO_NETWORK= "$TENDER" init acme --propose --json 2>/dev/null)
check "exits 0 and is valid JSON" "dict" "$(jget "$out" 'type(d).__name__')"
check "no side effects with network either" "$before" "$(snapshot acme)"
calls=$(cat "$GH_CALLS")
contains "asked for the labels" "label list" "$calls"
contains "asked for the environment" "api repos/owner/acme/environments/production" "$calls"
for verb in create edit delete " -X" PUT POST PATCH; do
  lacks "no write call to gh ($verb)" "$verb" "$calls"
done
check "labels.existing: only the three names, only those that exist" '["ready"]' "$(jget "$out" 'd["labels"]["existing"]')"
check "environment.slug" "owner/acme" "$(jget "$out" 'd["environment"]["slug"]')"
check "a 404 means the environment does not exist" "false" "$(jget "$out" 'd["environment"]["exists"]')"
out=$(PATH="$STUB:$PATH" TENDER_NO_NETWORK= GH_ENV=yes "$TENDER" init acme --propose --json 2>/dev/null)
check "a 200 means it exists" "true" "$(jget "$out" 'd["environment"]["exists"]')"
out=$(PATH="$STUB:$PATH" TENDER_NO_NETWORK= GH_ENV=down GH_LABELS_FAIL=1 "$TENDER" init acme --propose --json 2>/dev/null)
check "any other failure is null, not false" "null" "$(jget "$out" 'd["environment"]["exists"]')"
check "labels that could not be listed are null, not []" "null" "$(jget "$out" 'd["labels"]["existing"]')"

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
contains "and renumbers the steps after it" "2. Put the reviewer account's login" "$out"

echo "tender init --commit: a refused commit is step 1 refused"
fresh_repo hook
printf '#!/bin/sh\necho "hook says no" >&2\nexit 1\n' > "$SANDBOX/hook/.git/hooks/pre-commit"
chmod +x "$SANDBOX/hook/.git/hooks/pre-commit"
head_before=$(git -C "$SANDBOX/hook" rev-parse HEAD)
err=$("$TENDER" init hook --yes --boundary 'npm publish' --commit 2>&1 >/dev/null)
check "exits 21" "21" "$?"
contains "names step 1" "refused at step 1 (AGENTS.md)" "$err"
contains "gives git's reason" "hook says no" "$err"
check "AGENTS.md stays written" "yes" "$([ -f "$SANDBOX/hook/AGENTS.md" ] && echo yes || echo no)"
check "nothing committed" "$head_before" "$(git -C "$SANDBOX/hook" rev-parse HEAD)"
check "AGENTS.md is not left staged" "" "$(git -C "$SANDBOX/hook" diff --cached --name-only)"
check "later steps did not run: no worktrees" "no" "$([ -d "$SANDBOX/hook/.worktrees" ] && echo yes || echo no)"

echo "tender init --commit: a no-op when this run did not write AGENTS.md"
head_before=$(git -C "$SANDBOX/com" rev-parse HEAD)
"$TENDER" init com --yes --boundary 'npm publish' --commit >/dev/null 2>&1
check "an existing AGENTS.md: exits nothing-to-do (3), not an error" "3" "$?"
check "no commit" "$head_before" "$(git -C "$SANDBOX/com" rev-parse HEAD)"
fresh_repo skip
head_before=$(git -C "$SANDBOX/skip" rev-parse HEAD)
"$TENDER" init skip --yes --no-agents-md --no-worktrees --commit >/dev/null 2>&1
check "--no-agents-md: exits 3" "3" "$?"
check "--no-agents-md: no commit" "$head_before" "$(git -C "$SANDBOX/skip" rev-parse HEAD)"

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
