#!/usr/bin/env bash
# PreToolUse hook for Read — silently reindexes a file if its hash is stale.
set -euo pipefail

PROJECT_ROOT="/workspaces/puzzle"
INDEX_PATH="$PROJECT_ROOT/.claude/codebase-index.json"

# ── Extract file_path from stdin JSON ─────────────────────────────────────────
STDIN_DATA=$(cat 2>/dev/null || echo "{}")

FILE_PATH=$(echo "$STDIN_DATA" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('file_path', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")

if [ -z "$FILE_PATH" ]; then
    printf '{"continue": true}'
    exit 0
fi

# ── Fast exit: non-indexed extensions ─────────────────────────────────────────
EXT="${FILE_PATH##*.}"
case "$EXT" in
    py|ts|tsx|js|jsx) ;;
    *) printf '{"continue": true}'; exit 0 ;;
esac

# ── Fast exit: skip dirs ──────────────────────────────────────────────────────
case "$FILE_PATH" in
    */node_modules/*|*/__pycache__/*|*/.git/*|*/dist/*|*/build/*|\
    */.venv/*|*/venv/*|*/coverage/*|*/.nyc_output/*|\
    */.pytest_cache/*|*/.mypy_cache/*|*/.tox/*|*/.claude/*)
        printf '{"continue": true}'
        exit 0
        ;;
esac

# ── Skip if no index yet ──────────────────────────────────────────────────────
if [ ! -f "$INDEX_PATH" ]; then
    printf '{"continue": true}'
    exit 0
fi

# ── Hash check ────────────────────────────────────────────────────────────────
RESULT=$(python3 -c "
import sys, json, hashlib
from pathlib import Path

index_path = Path(sys.argv[1])
file_path  = Path(sys.argv[2])
project_root = Path(sys.argv[3])

try:
    rel = str(file_path.relative_to(project_root))
except ValueError:
    print('skip')
    sys.exit(0)

try:
    index = json.loads(index_path.read_text())
    stored = index.get('files', {}).get(rel, {}).get('hash', '')
    if not file_path.exists():
        print('skip')
        sys.exit(0)
    current = hashlib.sha256(file_path.read_bytes()).hexdigest()[:16]
    print('ok' if stored == current else 'stale:' + rel)
except Exception:
    print('skip')
" "$INDEX_PATH" "$FILE_PATH" "$PROJECT_ROOT" 2>/dev/null || echo "skip")

# ── Reindex if stale ──────────────────────────────────────────────────────────
case "$RESULT" in
    stale:*)
        REL="${RESULT#stale:}"
        python3 "$PROJECT_ROOT/scripts/index-codebase.py" --file "$FILE_PATH" \
            >/dev/null 2>&1 || true
        printf '{"continue": true, "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "Auto-reindexed: %s"}}' "$REL"
        ;;
    *)
        printf '{"continue": true}'
        ;;
esac
