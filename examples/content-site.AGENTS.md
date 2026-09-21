# Agents in this project

trunk: main
reviewer: example-reviewer
claim-timeout-days: 2

## Test commands

    pnpm build
    pnpm exec astro check
    pnpm exec linkinator ./dist --recurse --silent

~270 Markdown files means a renamed or removed page regularly leaves a
dangling internal link; `astro check` catches frontmatter/content-collection
schema violations, not that — `linkinator` walks the built site and does.

## Subagents

marketing-seo-specialist
marketing-content-creator

## Roles

developer reviewer maintainer

## Production boundary

    gh workflow run deploy.yml -f environment=production

Merging to trunk builds the site and regenerates `sitemap.xml`. Only this
line publishes the result — where it becomes reachable to visitors and to
whatever reads `robots.txt`.

Enforced by a protected environment — see docs/setup.md. Without that, this
section is a promise rather than a boundary.

## Local notes

A page draft is still an issue, a PR, and a review before it merges — the
three roles carry over from a code repository unchanged. There is no fourth
role for "writer": writing the page is what `developer` does here, the same
way it implements a function in a code repository. Roles are permissions, not
job titles.

The GitHub flow (issue → PR → review → merge) covers everything that lives in
this repository — a content calendar, a drafted post, a campaign text, all as
Markdown — but not a post typed directly into a social platform's own
editor: there is no PR there for this flow to route through.
