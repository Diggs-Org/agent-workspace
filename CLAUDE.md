# Claude Code Instructions

## Setup (run once after container creation)

```bash
npm install                                 # installs deps + ESLint
chmod +x .claude/hooks/*.sh                # make hooks executable
python3 scripts/index-codebase.py --full   # build initial codebase index
```

## Jira Workflow

@docs/jira-workflow.md

## Codebase Navigation (context efficiency)

Before reading any source file, consult `.claude/codebase-index.json`.

1. **Hash matches** → use `symbols`, `imports`, `exports` from the index. Skip reading the file.
2. **Hash mismatch** → re-index the file:
   ```bash
   python3 scripts/index-codebase.py --file <path>
   ```
3. **File not in index** → run incremental pass then retry:
   ```bash
   python3 scripts/index-codebase.py
   ```
4. **Check what's stale** (before a session):
   ```bash
   python3 scripts/index-codebase.py --check
   ```

## Linting

**Python:** `ruff check .`
**TypeScript/JS:** `npx eslint .` (uses `eslint.config.mjs`)

The lint hook is advisory — it reports errors as context but never blocks commits.

## Coverage

Runs automatically after PR creation and posts a markdown table to the PR comment thread.
Adjust the threshold in `.claude/hooks/post-pr-coverage.sh` (`COVERAGE_THRESHOLD`).
