# Agents in this project

trunk: development
reviewer: example-reviewer

## Test commands

    cargo test --manifest-path src-tauri/Cargo.toml --workspace --features test-fixtures
    pnpm exec svelte-check --tsconfig ./tsconfig.json

`--workspace` is not optional here: without it only one package is tested
(702 instead of 1278 tests) and the output still looks complete.

## Review tools

    .rs      rust-best-practices, tauri-v2
    .svelte  svelte-core-bestpractices

## Subagents

engineering-desktop-app-engineer
engineering-privacy-engineer
engineering-i18n-engineer

## Roles

developer reviewer maintainer

## Production boundary

    deploy-feed.yml -f channel=stable

Everything before it — merging, tagging, building, the canary feed — is the
maintainer's to do alone. The stable channel reaches every installed copy.

Enforced by a protected environment — see docs/setup.md. Without that, this
section is a promise rather than a boundary.

## Local notes

CI runs on a shared self-hosted runner. Before a merge that triggers a
deployment, require **zero queued or running jobs across the organisation** — a
momentary load average says nothing about the next ten minutes.

After any feed deployment, verify the published version: the deploy workflow can
race and publish an older commit.
