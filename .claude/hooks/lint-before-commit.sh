#!/usr/bin/env bash
# Advisory lint check before git commits. Reports errors but does not block.
set -euo pipefail

PROJECT_ROOT="/workspaces/puzzle"
REPORT=""
HAS_ERRORS=false

cd "$PROJECT_ROOT"

# Read stdin (PreToolUse provides tool_input JSON)
STDIN_DATA=$(cat 2>/dev/null || echo "{}")
CMD=$(echo "$STDIN_DATA" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")

# Only run for git commit commands
if ! echo "$CMD" | grep -qE '^git commit'; then
  printf '{"continue": true}'
  exit 0
fi

# ── Python: ruff ─────────────────────────────────────────────────────────────
if command -v ruff &>/dev/null && \
   find . -name "*.py" -not -path "*/node_modules/*" -not -path "*/.venv/*" \
   -maxdepth 5 2>/dev/null | grep -q .; then
  set +e
  RUFF_OUT=$(ruff check . 2>&1)
  RUFF_EXIT=$?
  set -e
  if [ $RUFF_EXIT -ne 0 ]; then
    HAS_ERRORS=true
    REPORT="${REPORT}ruff:\n${RUFF_OUT}\n\n"
  fi
fi

# ── TypeScript/JS: eslint ─────────────────────────────────────────────────────
if [ -f "package.json" ] && command -v node &>/dev/null; then
  HAS_ESLINT=$(node -e "
    const p = require('./package.json');
    const d = {...(p.dependencies||{}), ...(p.devDependencies||{})};
    console.log(d.eslint ? 'yes' : 'no');
  " 2>/dev/null || echo "no")

  if [ "$HAS_ESLINT" = "yes" ] && [ -f "node_modules/.bin/eslint" ]; then
    set +e
    ESLINT_OUT=$(node_modules/.bin/eslint . --ext .ts,.tsx,.js,.jsx 2>&1)
    ESLINT_EXIT=$?
    set -e
    if [ $ESLINT_EXIT -ne 0 ]; then
      HAS_ERRORS=true
      REPORT="${REPORT}eslint:\n${ESLINT_OUT}\n\n"
    fi
  fi
fi

# ── TypeScript: tsc --noEmit ──────────────────────────────────────────────────
if [ -f "tsconfig.json" ] && [ -f "node_modules/.bin/tsc" ]; then
  set +e
  TSC_OUT=$(node_modules/.bin/tsc --noEmit 2>&1)
  TSC_EXIT=$?
  set -e
  if [ $TSC_EXIT -ne 0 ]; then
    HAS_ERRORS=true
    REPORT="${REPORT}tsc --noEmit:\n${TSC_OUT}\n\n"
  fi
fi

# ── Advisory output (never blocks) ───────────────────────────────────────────
if [ "$HAS_ERRORS" = "true" ]; then
  CONTEXT=$(printf "Lint warnings (advisory — commit allowed):\n%b" "$REPORT")
  printf '{"continue": true, "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "%s"}}' \
    "$(echo "$CONTEXT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read())[1:-1])")"
else
  printf '{"continue": true}'
fi
