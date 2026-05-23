# Session Start

Run this at the start of every session to orient and learn the codebase.

## Step 1: Index the Codebase

```bash
python3 scripts/index-codebase.py --check   # print changed/stale files without rewriting
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
