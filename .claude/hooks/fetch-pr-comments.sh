#!/usr/bin/env bash
# PostToolUse on mcp__github__pull_request_read.
# Fetches review comments and PR-level comments via GitHub REST API
# and injects them into Claude's context so they're visible without extra tool calls.
set -euo pipefail

STDIN_DATA=$(cat)

# ── Parse PR info from tool_response ─────────────────────────────────────────
PR_INFO=$(echo "$STDIN_DATA" | python3 -c "
import sys, json, re

try:
    d = json.load(sys.stdin)
    r = d.get('tool_response', {})

    number = str(r.get('number', ''))

    # Extract owner/repo from URL fields
    repo = ''
    for field in ['html_url', 'url']:
        url = r.get(field, '')
        m = re.search(r'github\.com/([^/]+/[^/]+)/pull', url)
        if m: repo = m.group(1); break
        m = re.search(r'api\.github\.com/repos/([^/]+/[^/]+)/pulls', url)
        if m: repo = m.group(1); break

    # Also try head.repo.full_name
    if not repo:
        repo = (r.get('head', {}) or {}).get('repo', {}).get('full_name', '')

    print(f'{number}|{repo}')
except Exception:
    print('|')
" 2>/dev/null || echo "|")

PR_NUMBER="${PR_INFO%%|*}"
REPO="${PR_INFO#*|}"

if [ -z "$PR_NUMBER" ] || [ -z "$REPO" ]; then
    printf '{"continue": true}'
    exit 0
fi

AUTH_HEADER="Authorization: Bearer ${GITHUB_TOKEN}"
ACCEPT="Accept: application/vnd.github+json"
BASE="https://api.github.com/repos/${REPO}"

# ── Fetch review comments (inline, line-specific) ─────────────────────────────
REVIEW_COMMENTS=$(curl -sf \
    -H "$AUTH_HEADER" -H "$ACCEPT" \
    "${BASE}/pulls/${PR_NUMBER}/comments?per_page=50" 2>/dev/null || echo "[]")

# ── Fetch PR-level issue comments ────────────────────────────────────────────
ISSUE_COMMENTS=$(curl -sf \
    -H "$AUTH_HEADER" -H "$ACCEPT" \
    "${BASE}/issues/${PR_NUMBER}/comments?per_page=50" 2>/dev/null || echo "[]")

# ── Fetch submitted reviews (approve/request changes + body) ─────────────────
REVIEWS=$(curl -sf \
    -H "$AUTH_HEADER" -H "$ACCEPT" \
    "${BASE}/pulls/${PR_NUMBER}/reviews?per_page=20" 2>/dev/null || echo "[]")

# ── Format into readable context ─────────────────────────────────────────────
CONTEXT=$(python3 -c "
import sys, json

review_comments = json.loads(sys.argv[1])
issue_comments  = json.loads(sys.argv[2])
reviews         = json.loads(sys.argv[3])

parts = []

if reviews:
    parts.append('### Reviews')
    for r in reviews:
        state = r.get('state', '')
        user  = r.get('user', {}).get('login', '?')
        body  = (r.get('body') or '').strip()
        icon  = {'APPROVED': '✅', 'CHANGES_REQUESTED': '❌', 'COMMENTED': '💬'}.get(state, '❓')
        line  = f'{icon} **{user}** ({state})'
        if body:
            line += f': {body}'
        parts.append(line)

if review_comments:
    parts.append('\n### Inline Review Comments')
    for c in review_comments:
        user = c.get('user', {}).get('login', '?')
        path = c.get('path', '?')
        line = c.get('line') or c.get('original_line', '?')
        body = (c.get('body') or '').strip()
        parts.append(f'- **{user}** on \`{path}:{line}\`: {body}')

if issue_comments:
    parts.append('\n### PR Comments')
    for c in issue_comments:
        user = c.get('user', {}).get('login', '?')
        body = (c.get('body') or '').strip()
        parts.append(f'- **{user}**: {body}')

if not parts:
    print('No comments yet.')
else:
    print('\n'.join(parts))
" "$REVIEW_COMMENTS" "$ISSUE_COMMENTS" "$REVIEWS" 2>/dev/null || echo "Could not parse comments.")

# ── Return as additionalContext ───────────────────────────────────────────────
CONTEXT_JSON=$(echo "$CONTEXT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")

printf '{"continue": true, "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": %s}}\n' "$CONTEXT_JSON"
