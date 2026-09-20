# Agents in this project

trunk: main
reviewer: example-reviewer

## Test commands

    pnpm lint
    pnpm test
    pnpm build

## Review tools

    .ts,.tsx  next-best-practices
    .css      web-design-guidelines

## Subagents

engineering-i18n-engineer
engineering-minimal-change-engineer

## Roles

developer reviewer integrator

## Production boundary

    git push origin main:production

Merging to `main` deploys to staging and is the integrator's alone. The
production branch is never pushed without an explicit instruction.

Enforced by a protected environment — see docs/setup.md. Without that, this
section is a promise rather than a boundary.

## Local notes

Database migrations run automatically on deploy and are not reversible. A PR
that adds one needs the reviewer to say so explicitly in the approval.
