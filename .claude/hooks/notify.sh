#!/usr/bin/env bash
# Handles Notification hook events: desktop notify + log.
set -euo pipefail

PROJECT_ROOT="/workspaces/agent-workspace"
LOG_FILE="$PROJECT_ROOT/.claude/notifications.log"

INPUT=$(cat 2>/dev/null || echo "{}")
TITLE=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('title', 'Claude Code'))
except Exception:
    print('Claude Code')
" 2>/dev/null || echo "Claude Code")
MESSAGE=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('message', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")

# Desktop notification (Linux)
if command -v notify-send &>/dev/null; then
  notify-send "$TITLE" "$MESSAGE" 2>/dev/null || true
fi

# Log it
echo "[$(date -u +"%H:%M:%SZ")] $TITLE: $MESSAGE" >> "$LOG_FILE" 2>/dev/null || true

printf '{"continue": true}'
