#!/usr/bin/env bash
# PostToolUse on mcp__github__create_branch.
# Posts a comment on the Jira issue linking to the new GitHub branch.
#
# GitHub for Jira (connected) automatically surfaces branches, commits, and PRs
# in the Jira Development panel — no manual remote link needed.
# This hook just posts a comment as a visible notification in the issue activity.
set -euo pipefail

STDIN_DATA=$(cat)

# ── Get branch name ───────────────────────────────────────────────────────────
BRANCH=$(echo "$STDIN_DATA" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    r = d.get('tool_response', {})
    print(r.get('name', r.get('ref', '')))
except Exception:
    pass
" 2>/dev/null || echo "")

if [ -z "$BRANCH" ]; then
    BRANCH=$(git -C /workspaces/puzzle rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
fi

ISSUE_KEY=$(echo "$BRANCH" | grep -oE '[A-Z]+-[0-9]+' | head -1 || echo "")

if [ -z "$ISSUE_KEY" ]; then
    printf '{"continue": true}'
    exit 0
fi

# ── Build branch URL from git remote ─────────────────────────────────────────
REMOTE_URL=$(git -C /workspaces/puzzle remote get-url origin 2>/dev/null || echo "")
REPO_HTTP=$(echo "$REMOTE_URL" | python3 -c "
import sys, re
url = sys.stdin.read().strip()
m = re.match(r'git@github\.com:(.+?)(?:\.git)?\$', url)
if m:
    print('https://github.com/' + m.group(1)); sys.exit()
m = re.match(r'(https://github\.com/[^/]+/[^/]+?)(?:\.git)?\$', url)
if m:
    print(m.group(1))
" 2>/dev/null || echo "")

BRANCH_URL="${REPO_HTTP}/tree/${BRANCH}"

# ── Post comment on Jira issue (Jira REST API v2 — plain text / wiki markup) ─
AUTH="$ATLASSIAN_BASIC_AUTH"
COMMENT_BODY="Branch created and linked via GitHub for Jira: [${BRANCH}|${BRANCH_URL}]"
COMMENT_JSON=$(python3 -c "import json, sys; print(json.dumps({'body': sys.argv[1]}))" "$COMMENT_BODY")

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Basic ${AUTH}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$COMMENT_JSON" \
    "${ATLASSIAN_URL}/rest/api/2/issue/${ISSUE_KEY}/comment" 2>/dev/null || echo "000")

printf '{"continue": true, "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "Jira %s comment: HTTP %s (branch visible in Development panel via GitHub for Jira)"}}\n' \
    "$ISSUE_KEY" "$HTTP_CODE"
