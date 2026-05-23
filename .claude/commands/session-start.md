# Session Start

Run this at the start of every session to orient and pick up any pending work.

## Step 0: Check Inbox and Ticket State

Read `.claude/inbox.md` if it exists — it was populated by `scripts/check-inbox.sh` when the
devcontainer started. If the file is missing or more than 1 hour old, query Jira directly:

```bash
source project.config
# Then use jira_search MCP tool:
# assignee = "${JIRA_ASSIGNEE_EMAIL}" AND project = "${JIRA_PROJECT_KEY}" AND statusCategory != Done
```

**If there are assigned tickets**, run `/autonomous-ticket` with the highest-priority one
(lowest-number status, then highest priority). That skill handles full state detection
(plan → implement → address-review → merge) automatically.

**If there are no assigned tickets**, skip to Step 1 for a general orientation.

---

## Step 1: Index the Codebase

```bash
python3 scripts/index-codebase.py --brief   # file counts, symbols, stale files — <30 lines
```

## Finding symbols

Before reading any source file, query the codebase index:

```bash
python3 scripts/query-index.py --symbol <name>              # fuzzy match by name
python3 scripts/query-index.py --kind function --file "scripts/*.py"
python3 scripts/query-index.py --exports --file "*.ts"
```

1. **Hash matches** → use `symbols`, `imports`, `exports` from the index. Skip reading the file.
2. **File not in index** → run incremental pass then retry:
   ```bash
   python3 scripts/index-codebase.py
   ```

> Files are auto-reindexed when Claude reads them — no manual staleness checks needed.
