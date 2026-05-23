# Claude Code Instructions

## Ticket Workflow

Two phrases drive the full end-to-end workflow:
- **"You have been assigned ticket [KEY]"** — fetches the ticket, explores the codebase, creates PLAN.md, opens a draft PR (Phase 1)
- **"A PR review has been performed"** — detects current state and runs the appropriate phase (implement / address comments / merge)

Use `/autonomous-ticket` to see the full skill definition.

## Codebase Navigation

Use `/session-start` at the beginning of each session to orient and learn the codebase index.

## Linting

Use `/lint` for linting commands. The lint hook runs automatically before commits.

## Setup

Use `/setup` to initialize the workspace after container creation.
