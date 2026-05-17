# Lint

Run linters for the relevant language:

**Python:** `ruff check .`
**TypeScript/JS:** `npx eslint .` (uses `eslint.config.mjs`)
**TypeScript types:** `node_modules/.bin/tsc --noEmit` (requires `tsconfig.json`)

The lint hook runs automatically before commits and is advisory — it reports errors as context but never blocks commits. Type errors are caught by `tsc --noEmit` pre-commit.
