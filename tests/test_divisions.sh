#!/usr/bin/env bash
# Checks that agents/ stopped presenting five files as if that were all of
# upstream, that the new marketing/design subagents are wired in correctly,
# and that the new content-site example neither invents a role nor skips the
# review flow. This is prose plus a handful of files, not code, so most
# assertions are substring checks against the shipped files themselves.
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh

NEW_AGENTS="marketing-seo-specialist marketing-content-creator marketing-social-media-strategist design-ui-designer design-ux-researcher"

echo "agents/: the five new files exist"
for a in $NEW_AGENTS; do
  if [ -f "agents/$a.md" ]; then
    check "agents/$a.md exists" "0" "0"
  else
    check "agents/$a.md exists" "0" "1"
  fi
done

echo "agents/: each new file carries the same provenance header shape as the original five"
for a in $NEW_AGENTS; do
  HEADER=$(head -6 "agents/$a.md")
  contains "$a: names the upstream source" "Source: " "$HEADER"
  contains "$a: names the upstream commit" "Upstream commit: 87f8301cad3823a9a34d762036ae923a0eff306f" "$HEADER"
  contains "$a: states frozen-on-purpose" "Frozen on purpose — see agents/README.md." "$HEADER"
done

echo "agents/: file count matches what the docs claim"
COUNT=$(find agents -maxdepth 1 -name '*.md' ! -name 'README.md' | wc -l | tr -d ' ')
check "ten agent files ship" "10" "$COUNT"

echo "agents/README.md: no longer claims five files are all there is"
README=$(cat agents/README.md)
lacks "drops the old 'all five are verbatim copies' framing" "All five are verbatim copies from" "$README"
contains "says it's a selection, not a mirror" "selection, not a mirror" "$README"
contains "names the real upstream scale" "19 divisions" "$README"
contains "explains why we don't mirror upstream" "goes stale" "$README"
contains "documents how to add another one" "Getting another one" "$README"

echo "agents/README.md: the legal/compliance omission is explained, not silent"
contains "says why there is no legal subagent" "did **not** add a legal/compliance subagent" "$README"

echo "docs/tools.md: no longer states the count as if it were the whole story"
TOOLS=$(cat docs/tools.md)
lacks "drops the old 'the five subagents' phrasing" "The five subagents in \`agents/\` — their file format is Claude Code's. See" "$TOOLS"
contains "points at agents/README.md for what upstream actually holds" "curated selection" "$TOOLS"

echo "docs/concept.md: roles-versus-subagents section reflects the real count"
CONCEPT=$(cat docs/concept.md)
contains "names the new domains" "SEO, content, social media, UI," "$CONCEPT"
contains "gives the upstream scale" "260+ agents" "$CONCEPT"
OLD_CONCEPT_CLAIM=$'The five\nsubagents under `agents/`'
lacks "drops the old five-only enumeration" "$OLD_CONCEPT_CLAIM" "$CONCEPT"

echo "NOTICE: count matches the shipped files, not the old number"
NOTICE_TXT=$(cat NOTICE)
contains "says ten files" "Ten files under \`agents/\` are verbatim copies" "$NOTICE_TXT"
lacks "drops the old 'five files' claim" "Five files under \`agents/\`" "$NOTICE_TXT"

echo "examples/content-site.AGENTS.md: exists and satisfies atk-lint's required sections"
EX="examples/content-site.AGENTS.md"
[ -f "$EX" ] && check "file exists" "0" "0" || check "file exists" "0" "1"
EXAMPLE=$(cat "$EX")
contains "has a trunk" "trunk: main" "$EXAMPLE"
contains "has a reviewer" "reviewer: example-reviewer" "$EXAMPLE"

echo "examples/content-site.AGENTS.md: only names subagents this repo actually ships"
for agent in $(awk '/^## / { inside = (tolower(substr($0,4)) == "subagents"); next } inside && NF { print }' "$EX"); do
  if [ -f "agents/$agent.md" ]; then
    check "names an existing subagent: $agent" "0" "0"
  else
    check "names an existing subagent: $agent" "0" "1"
  fi
done

echo "examples/content-site.AGENTS.md: does not rename the roles"
ROLES_LINE=$(awk '/^## / { inside = (tolower(substr($0,4)) == "roles"); next } inside && NF { print; exit }' "$EX")
check "Roles section is exactly the three standard roles" "developer reviewer maintainer" "$ROLES_LINE"
contains "states the anti-renaming rule explicitly" "Roles are permissions, not" "$EXAMPLE"

echo "examples/content-site.AGENTS.md: draws the social-media flow boundary honestly"
contains "says the flow covers what's in git" "content calendar, a drafted post, a campaign text" "$EXAMPLE"
contains "says the flow stops at the platform's own editor" "there is no PR there for this flow to route through" "$EXAMPLE"

echo "bin/atk-lint: accepts the repository with the new agents and the new example"
out=$(bin/atk-lint . 2>&1); check "repository including the new files is consistent" "0" "$?"
contains "confirms it actually checked something" "repository is consistent" "$out"

summary
