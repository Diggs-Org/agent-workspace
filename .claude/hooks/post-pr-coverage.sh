#!/usr/bin/env bash
# PostToolUse on mcp__github__create_pull_request.
# Runs tests + coverage and posts a summary comment to the new PR.
# Never blocks — coverage info is for human review, not a gate.
set -euo pipefail

PROJECT_ROOT="/workspaces/puzzle"
cd "$PROJECT_ROOT"

# ── Parse PR info from stdin ──────────────────────────────────────────────────
STDIN_DATA=$(cat)

PR_NUMBER=$(echo "$STDIN_DATA" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    r = d.get('tool_response', {})
    print(r.get('number', r.get('id', '')))
except Exception:
    pass
" 2>/dev/null || echo "")

REPO=$(echo "$STDIN_DATA" | python3 -c "
import sys, json, re
try:
    d = json.load(sys.stdin)
    r = d.get('tool_response', {})
    for field in ['html_url', 'url']:
        url = r.get(field, '')
        m = re.search(r'github\.com/([^/]+/[^/]+)/pull', url)
        if m: print(m.group(1)); break
        m = re.search(r'api\.github\.com/repos/([^/]+/[^/]+)/pulls', url)
        if m: print(m.group(1)); break
except Exception:
    pass
" 2>/dev/null || echo "")

# Fallback: derive repo from git remote
if [ -z "$REPO" ]; then
    REPO=$(git remote get-url origin 2>/dev/null | python3 -c "
import sys, re
url = sys.stdin.read().strip()
m = re.search(r'github\.com[:/](.+?)(?:\.git)?$', url)
print(m.group(1) if m else '')
" 2>/dev/null || echo "")
fi

if [ -z "$PR_NUMBER" ] || [ -z "$REPO" ]; then
    printf '{"continue": true}'
    exit 0
fi

# ── Run coverage ──────────────────────────────────────────────────────────────
ROWS=""
DETAILS=""
HAS_RESULTS=false

# Python
HAS_PYTHON=false
if [ -f "pyproject.toml" ] || [ -f "pytest.ini" ] || [ -f "setup.py" ]; then
    HAS_PYTHON=true
elif find . -name "test_*.py" \
     -not -path "*/node_modules/*" -not -path "*/.venv/*" \
     -maxdepth 5 2>/dev/null | grep -q .; then
    HAS_PYTHON=true
fi

if [ "$HAS_PYTHON" = "true" ] && command -v python3 &>/dev/null; then
    HAS_RESULTS=true
    set +e
    PY_OUT=$(python3 -m pytest --tb=short --cov=. --cov-report=term-missing -q 2>&1)
    PY_EXIT=$?
    set -e
    PY_COV=$(echo "$PY_OUT" | grep -E "^TOTAL" | awk '{print $NF}' | tr -d '%' || echo "?")
    if [ $PY_EXIT -eq 0 ]; then
        ROWS="${ROWS}| Python | ✅ | ${PY_COV}% |\n"
    else
        ROWS="${ROWS}| Python | ❌ | ${PY_COV}% |\n"
    fi
    DETAILS="${DETAILS}\n<details>\n<summary>pytest output</summary>\n\n\`\`\`\n${PY_OUT}\n\`\`\`\n</details>\n"
fi

# Node.js
if [ -f "package.json" ] && command -v node &>/dev/null; then
    HAS_JS=$(node -e "
const p = require('./package.json');
const d = {...(p.dependencies||{}), ...(p.devDependencies||{})};
const s = (p.scripts||{}).test || '';
console.log((d.jest || d.vitest || /jest|vitest/.test(s)) ? 'yes' : 'no');
" 2>/dev/null || echo "no")

    if [ "$HAS_JS" = "yes" ]; then
        HAS_RESULTS=true
        set +e
        JS_OUT=$(npm test -- --coverage 2>&1)
        JS_EXIT=$?
        set -e
        JS_COV=$(echo "$JS_OUT" | grep -E "All files" | grep -oE "[0-9]+(\.[0-9]+)?" | head -1 || echo "?")
        if [ $JS_EXIT -eq 0 ]; then
            ROWS="${ROWS}| Node.js | ✅ | ${JS_COV}% |\n"
        else
            ROWS="${ROWS}| Node.js | ❌ | ${JS_COV}% |\n"
        fi
        DETAILS="${DETAILS}\n<details>\n<summary>jest/vitest output</summary>\n\n\`\`\`\n${JS_OUT}\n\`\`\`\n</details>\n"
    fi
fi

if [ "$HAS_RESULTS" = "false" ]; then
    printf '{"continue": true}'
    exit 0
fi

# ── Build comment body ────────────────────────────────────────────────────────
BODY=$(printf "## 🧪 Coverage Report\n\n| Language | Status | Coverage |\n|----------|--------|----------|\n%b\n%b\n\n---\n*Auto-posted by Claude Code. You can add notes above the horizontal rule before review.*" \
    "$ROWS" "$DETAILS")

# ── Post comment to PR ────────────────────────────────────────────────────────
BODY_JSON=$(echo "$BODY" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/vnd.github+json" \
    -d "{\"body\": ${BODY_JSON}}" \
    "https://api.github.com/repos/${REPO}/issues/${PR_NUMBER}/comments" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "201" ]; then
    printf '{"continue": true, "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "Coverage report posted to PR #%s"}}\n' "$PR_NUMBER"
else
    printf '{"continue": true, "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "Coverage ran but comment post returned HTTP %s"}}\n' "$HTTP_CODE"
fi
