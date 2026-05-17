# Lint

Run linters for the relevant language:

**Python (style):** `ruff check .`
**Python (types):** `pyright` — uses `pyrightconfig.json` at repo root (Pylance-compatible)
**TypeScript/JS:** `npx eslint .` (uses `eslint.config.mjs`)
**TypeScript types:** `node_modules/.bin/tsc --noEmit` (requires `tsconfig.json`)

The lint hook runs automatically before commits and is advisory — it reports errors as context but never blocks commits. Python type errors are caught by `pyright` and TypeScript type errors by `tsc --noEmit` pre-commit.
