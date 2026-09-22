#!/usr/bin/env bash
# `atk claims` / `atk claim-release` — the release-then-reclaim mechanism
# roles/developer.md and roles/reviewer.md describe as prose, exercised
# against a real (local, file-based) remote, the same way tests/test_state.sh
# exercises collect_state()'s "claim held" line: git ls-remote/fetch/cat-file/
# push are real git, only gh is stubbed.
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
ATK="$PWD/bin/atk"
make_sandbox
STUB=$(mktemp -d)
cleanup() { rm -rf "$SANDBOX" "$STUB"; }
trap cleanup EXIT

# A real bare remote — same setup as tests/test_state.sh, for the same
# reason: ls-remote/fetch/cat-file/push all have to be real git against a
# real ref store, not a stand-in.
git init -q --bare "$SANDBOX/demo-remote.git"
git -C "$SANDBOX/demo" remote add origin "$SANDBOX/demo-remote.git"
git -C "$SANDBOX/demo" push -q origin main

push_claim() {
  # $1: claim name (e.g. issue-42), $2: ISO-8601 UTC timestamp
  local sha
  sha=$(printf 'claim %s' "$2" | git -C "$SANDBOX/demo" hash-object -w --stdin)
  git -C "$SANDBOX/demo" push -q origin "${sha}:refs/claims/$1"
}

held_sha() {
  git -C "$SANDBOX/demo" ls-remote origin "refs/claims/$1" | cut -f1
}

FRESH=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OLD="2000-01-01T00:00:00Z"

cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
exit 0
STUBEOF
chmod +x "$STUB/gh"
export GH_CALLS="$STUB/calls"
: > "$GH_CALLS"
export PATH="$STUB:$PATH"

echo "atk claims: arguments"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claims 2>&1); check "no repo exits 1" "1" "$?"
contains "explains what's missing" "give a repo" "$out"

out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claims no-such-repo 2>&1)
check "unknown repo exits 1" "1" "$?"
contains "names the missing repo" "is not a git repository" "$out"

echo "atk claims: nothing claimed is an honest (none), not silence"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claims demo 2>&1)
check "exits 0" "0" "$?"
check "says none" "(none)" "$out"

out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claims demo --json 2>&1)
check "json form is an empty array, not a blank line" "[]" "$out"

echo "atk claims: default threshold (no AGENTS.md) is 2 days"
push_claim issue-1 "$FRESH"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claims demo 2>&1)
contains "lists the fresh claim" "issue-1" "$out"
contains "shows its timestamp" "$FRESH" "$out"
lacks "a fresh claim is not orphaned" "orphaned" "$out"
git -C "$SANDBOX/demo" push -q origin ":refs/claims/issue-1"

echo "atk claims: a claim past the default threshold is marked orphaned"
push_claim issue-2 "$OLD"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claims demo 2>&1)
contains "names it" "issue-2" "$out"
contains "marks it orphaned" "orphaned (threshold: 2 days)" "$out"
contains "reports its age in days" "d ago" "$out"

echo "atk claims: --json carries the same facts, machine-readable"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claims demo --json 2>&1)
check "starts an array" "[" "${out:0:1}"
contains "names the claim" '"name":"issue-2"' "$out"
contains "carries the ref" '"ref":"refs/claims/issue-2"' "$out"
contains "carries the timestamp" "\"claimed_at\":\"$OLD\"" "$out"
contains "flags it orphaned, as a JSON boolean" '"orphaned":true' "$out"
contains "carries the threshold" '"threshold_days":2' "$out"

echo "atk claims: a claim written as a commit is content, not a failed lookup"
# Claims written before blobs replaced `git commit-tree` are commits, and they
# still sit on remotes. The fetch succeeds; only the type is wrong. That must
# not read as "could not ask" (a network failure it isn't), and it must not
# fail the whole listing — a UI would discard every good row with it.
commit_sha=$(printf 'claim 2026-01-01T00:00:00Z' | git -C "$SANDBOX/demo" -c user.name=t -c user.email=t@e \
  commit-tree "$(git -C "$SANDBOX/demo" hash-object -w -t tree /dev/null)")
git -C "$SANDBOX/demo" push -q origin "${commit_sha}:refs/claims/issue-legacy"
out=$("$ATK" claims demo 2>&1); check "a legacy commit claim does not fail the listing" "0" "$?"
contains "names it as not a claim blob" "not a claim blob" "$out"
lacks "does not dress it up as a lookup failure" "could not ask" "$out"
out=$("$ATK" claims demo --json 2>&1)
contains "carries it in json as an error on that entry" '"error":"not a claim blob: a commit"' "$out"
git -C "$SANDBOX/demo" push -q origin ":refs/claims/issue-legacy"

echo "atk claims: AGENTS.md's claim-timeout-days changes the verdict, not just the number shown"
printf 'trunk: main\nreviewer: x\nclaim-timeout-days: 36500\n' > "$SANDBOX/demo/AGENTS.md"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claims demo 2>&1)
lacks "a 100-year threshold makes even this claim look fresh" "orphaned" "$out"
rm -f "$SANDBOX/demo/AGENTS.md"
git -C "$SANDBOX/demo" push -q origin ":refs/claims/issue-2"

echo "atk claims: an unreachable remote says so, and does not exit 0"
git -C "$SANDBOX/demo" remote set-url origin "$SANDBOX/does-not-exist.git"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claims demo 2>&1)
check "exits 1" "1" "$?"
contains "says it could not ask" "could not ask" "$out"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claims demo --json 2>&1)
contains "json form is an error object, not an empty array" '"error":"could not ask' "$out"
git -C "$SANDBOX/demo" remote set-url origin "$SANDBOX/demo-remote.git"

echo "atk claims: one unreachable ref does not take the rest of the listing down"
# Three refs, deliberately not just two: issue-4 is made to fail, and
# issue-49 sorts after it (git ls-remote's output is byte-sorted by refname,
# and "issue-4" is a prefix of "issue-49") — so if a mutation turned the
# per-ref "could not ask" into a fatal abort instead of a `continue`, issue-3
# (sorted before the failure) would still show up and hide that regression;
# issue-49 only appears if processing actually continued past the failure.
push_claim issue-3 "$FRESH"
push_claim issue-4 "$FRESH"
push_claim issue-49 "$FRESH"
REAL_GIT=$(command -v git)
cat > "$STUB/git" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"fetch -q origin refs/claims/issue-4"*)
    echo "fatal: simulated network failure" >&2
    exit 1
    ;;
esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$STUB/git"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claims demo 2>&1)
check "a partial failure still exits non-zero" "1" "$?"
contains "the reachable ref before the failure is still reported" "issue-3" "$out"
contains "the unreachable one says so instead of vanishing" "issue-4" "$out"
contains "names why" "could not ask" "$out"
contains "processing continues past the failed ref, not just stops there" "issue-49" "$out"
rm -f "$STUB/git"
git -C "$SANDBOX/demo" push -q origin ":refs/claims/issue-3" ":refs/claims/issue-4" ":refs/claims/issue-49"

echo "atk claim-release: arguments"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claim-release demo 2>&1)
check "missing claim exits 1" "1" "$?"
contains "shows usage" "usage: atk claim-release" "$out"

out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claim-release demo not-a-claim 2>&1)
check "a name that isn't issue-N/pr-N/N exits 1" "1" "$?"
contains "explains the accepted shapes" "issue-N" "$out"

out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claim-release demo 999 2>&1)
check "nothing held exits 1" "1" "$?"
contains "says there is nothing to release" "nothing to release" "$out"

echo "atk claim-release: refuses a claim younger than the threshold — this is the point, not a safety detail"
push_claim issue-5 "$FRESH"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claim-release demo 5 2>&1)
check "exits 1" "1" "$?"
contains "explains why" "younger than the" "$out"
expected_sha=$(printf 'claim %s' "$FRESH" | git -C "$SANDBOX/demo" hash-object -w --stdin)
check "the ref is untouched" "$expected_sha" "$(held_sha issue-5)"
: > "$GH_CALLS"
git -C "$SANDBOX/demo" push -q origin ":refs/claims/issue-5"

echo "atk claim-release: releases and reclaims an orphaned claim, bare-number form"
push_claim issue-6 "$OLD"
before=$(held_sha issue-6)
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claim-release demo 6 2>&1)
check "exits 0" "0" "$?"
contains "reports success" "released and reclaimed issue-6" "$out"
after=$(held_sha issue-6)
check "the ref now points somewhere new (reclaimed, not just released)" "yes" \
  "$([ "$before" != "$after" ] && [ -n "$after" ] && echo yes || echo no)"
git -C "$SANDBOX/demo" fetch -q origin refs/claims/issue-6 >/dev/null 2>&1
new_blob=$(git -C "$SANDBOX/demo" cat-file blob "$after")
contains "the new blob carries a fresh timestamp, not the old one" "claim " "$new_blob"
lacks "not the timestamp being taken over from" "$OLD" "$new_blob"
calls=$(cat "$GH_CALLS")
contains "comments on the issue, not a PR" "issue comment 6" "$calls"
contains "the comment names when the old claim was made" "Took over a claim from $OLD" "$calls"

echo "atk claims: after a takeover, the same claim reads as fresh, not orphaned"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claims demo 2>&1)
contains "still listed" "issue-6" "$out"
lacks "no longer orphaned" "orphaned" "$out"
git -C "$SANDBOX/demo" push -q origin ":refs/claims/issue-6"

echo "atk claim-release: explicit issue-N / pr-N forms, and the PR comment goes through gh pr comment"
push_claim issue-7 "$OLD"
: > "$GH_CALLS"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claim-release demo issue-7 2>&1)
check "explicit issue-N form works" "0" "$?"
contains "still comments as an issue" "issue comment 7" "$(cat "$GH_CALLS")"
git -C "$SANDBOX/demo" push -q origin ":refs/claims/issue-7"

push_claim pr-8 "$OLD"
: > "$GH_CALLS"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claim-release demo pr-8 2>&1)
check "pr-N form works" "0" "$?"
contains "comments on the PR, not the issue tracker" "pr comment 8" "$(cat "$GH_CALLS")"
lacks "never the issue comment command for a PR claim" "issue comment 8" "$(cat "$GH_CALLS")"
git -C "$SANDBOX/demo" push -q origin ":refs/claims/pr-8"

echo "atk claim-release: a comment gh cannot post does not undo an already-reclaimed ref"
push_claim issue-9 "$OLD"
before=$(held_sha issue-9)
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
echo "gh: authentication required" >&2
exit 1
STUBEOF
chmod +x "$STUB/gh"
out=$(ATK_PROJECTS_DIR="$SANDBOX" "$ATK" claim-release demo 9 2>&1)
check "still exits 0 — the ref state is what matters, the comment is best-effort" "0" "$?"
after=$(held_sha issue-9)
check "the ref was still reclaimed" "yes" "$([ "$before" != "$after" ] && echo yes || echo no)"
contains "warns that the comment did not land" "could not post the takeover comment" "$out"
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
exit 0
STUBEOF
chmod +x "$STUB/gh"
git -C "$SANDBOX/demo" push -q origin ":refs/claims/issue-9"

echo "source: the documented mechanism, checked against mutation"
CLAIMS_SRC=$(cat lib/claims.sh)
contains "release-then-reclaim uses the braced refspec (zsh eats an unbraced one)" \
  '"${sha}:${refname}"' "$CLAIMS_SRC"
contains "reads the hash via ls-remote before fetching it" \
  'ls-remote origin "$refname"' "$CLAIMS_SRC"
contains "fetches before cat-file can read the object" \
  'fetch -q origin "$refname"' "$CLAIMS_SRC"
# Not "the word --force never appears" — the comments above these two lines
# say it on purpose, explaining why. What must actually never happen is
# either push command carrying the flag.
# Match every push, not just `push origin`: the usual place for the flag is
# between the two (`push --force origin`), and a pattern requiring them
# adjacent would silently drop exactly the line it exists to inspect —
# leaving `lacks` below checking a list that no longer contains it.
PUSH_LINES=$(grep 'git -C "\$repo_dir" push' lib/claims.sh)
check "there are exactly the release push and the reclaim push" "2" \
  "$(printf '%s\n' "$PUSH_LINES" | grep -c .)"
lacks "neither push line itself passes --force" "--force" "$PUSH_LINES"

summary
