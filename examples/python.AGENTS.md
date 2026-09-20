# Agents in this project

trunk: main
reviewer: example-reviewer

## Test commands

    uv run pytest -q
    uv run ruff check .
    uv run mypy src

## Subagents

engineering-minimal-change-engineer
engineering-privacy-engineer

## Roles

developer reviewer integrator

## Production boundary

    uv publish

Tagging a release is the integrator's. Publishing to the package index needs an
explicit instruction and cannot be undone.

## Local notes

Delete this section rather than leaving it empty.
