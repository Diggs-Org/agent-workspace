#!/usr/bin/env bash
# Appends a brief session summary to .claude/session-summaries.log on Stop.
set -euo pipefail

PROJECT_ROOT="/workspaces/agent-workspace"
SUMMARY_FILE="$PROJECT_ROOT/.claude/session-summaries.log"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cd "$PROJECT_ROOT"

CHANGED=$(git diff --name-only HEAD 2>/dev/null | head -20 || echo "(none)")
STAGED=$(git diff --cached --name-only 2>/dev/null | head -10 || echo "(none)")
COMMITS=$(git log --oneline -5 2>/dev/null || echo "(none)")

{
  echo "=== $TIMESTAMP ==="
  echo "Changed (unstaged): $CHANGED"
  echo "Staged: $STAGED"
  echo "Recent commits:"
  echo "$COMMITS"
  echo ""
} >> "$SUMMARY_FILE" 2>/dev/null || true

printf '{"continue": true, "systemMessage": "Session summary written to .claude/session-summaries.log"}'
