# Agents in this project

trunk: main
reviewer: example-reviewer

## Test commands

    pnpm build
    pnpm exec astro check

## Review tools

    .astro,.ts  web-design-guidelines

## Subagents

engineering-i18n-engineer

## Roles

developer reviewer maintainer

## Production boundary

    docker compose -f docker-compose.prod.yml up -d

The maintainer builds and pushes the image. Restarting the production stack
needs an explicit instruction.

Enforced by a protected environment — see docs/setup.md. Without that, this
section is a promise rather than a boundary.

## Local notes

Server endpoints must read `process.env`, not `import.meta.env` — the latter is
inlined at build time and silently becomes dead code.
