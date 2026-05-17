# Claude Code Instructions

## Project Metadata

| Key | Value |
|-----|-------|
| GitHub owner/repo | `Diggs-Org/agent-workspace` |
| Main branch | `main` |
| Jira project key | `SCRUM-NNN` |
| Jira URL | `https://ddiggs.atlassian.net` |
| Python version | `3.12` |
| Node version | `22` |

> These facts are static — never run `git remote -v` or version discovery commands.

## Setup (run once after container creation)

```bash
npm install                                 # installs deps + ESLint
chmod +x .claude/hooks/*.sh                # make hooks executable
python3 scripts/index-codebase.py --full   # build initial codebase index
```

## Jira Workflow

@docs/jira-workflow.md

## Codebase Navigation (context efficiency)

**At session start, orient quickly:**
```bash
python3 scripts/index-codebase.py --brief   # file counts, symbols, stale files — <30 lines
```

**Find any symbol instantly (before reading any file):**
```bash
python3 scripts/query-index.py --symbol <name>              # fuzzy match by name
python3 scripts/query-index.py --kind function --file "scripts/*.py"
python3 scripts/query-index.py --exports --file "*.ts"
```

Before reading any source file, consult `.claude/codebase-index.json`.

1. **Hash matches** → use `symbols`, `imports`, `exports` from the index. Skip reading the file.
2. **File not in index** → run incremental pass then retry:
   ```bash
   python3 scripts/index-codebase.py
   ```

> Files are auto-reindexed when Claude reads them — no manual staleness checks needed.

## Linting

**Python:** `ruff check .`
**TypeScript/JS:** `npx eslint .` (uses `eslint.config.mjs`)
**TypeScript types:** `node_modules/.bin/tsc --noEmit` (requires `tsconfig.json`)

The lint hook is advisory — it reports errors as context but never blocks commits.
Type errors (return type mismatches, wrong argument types) are caught by `tsc --noEmit` pre-commit.

## Coverage

Runs automatically after PR creation and posts a markdown table to the PR comment thread.
Adjust the threshold in `.claude/hooks/post-pr-coverage.sh` (`COVERAGE_THRESHOLD`).
