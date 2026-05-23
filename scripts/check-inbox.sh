#!/usr/bin/env bash
# Queries Jira for tickets assigned to the Claude user and writes .claude/inbox.md.
# Run automatically by postStartCommand when the devcontainer starts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/project.config"
INBOX="$REPO_ROOT/.claude/inbox.md"

# ── Load project config ───────────────────────────────────────────────────────
if [ ! -f "$CONFIG" ]; then
  echo "check-inbox: project.config not found — run scripts/setup-project.sh first."
  exit 0
fi
# shellcheck source=/dev/null
source "$CONFIG"

# ── Validate credentials ──────────────────────────────────────────────────────
if [ -z "${ATLASSIAN_EMAIL:-}" ] || [ -z "${ATLASSIAN_API_TOKEN:-}" ]; then
  echo "check-inbox: ATLASSIAN_EMAIL or ATLASSIAN_API_TOKEN not set — skipping."
  echo "  Set these in your shell environment (see scripts/setup-project.sh)."
  exit 0
fi

if [ -z "${JIRA_ASSIGNEE_EMAIL:-}" ] || [ -z "${JIRA_PROJECT_KEY:-}" ] || [ -z "${ATLASSIAN_URL:-}" ]; then
  echo "check-inbox: project.config incomplete — run scripts/setup-project.sh."
  exit 0
fi

# ── Query Jira ────────────────────────────────────────────────────────────────
JQL="project = ${JIRA_PROJECT_KEY} AND assignee = \"${JIRA_ASSIGNEE_EMAIL}\" AND statusCategory != Done ORDER BY priority ASC, created ASC"
JQL_ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$JQL")

RESPONSE=$(curl -sf \
  -u "${ATLASSIAN_EMAIL}:${ATLASSIAN_API_TOKEN}" \
  -H "Accept: application/json" \
  "${ATLASSIAN_URL}/rest/api/3/search?jql=${JQL_ENCODED}&fields=summary,status,priority&maxResults=20" \
  2>/dev/null || echo '{"error":"connection_failed"}')

if ! python3 -c "import sys,json; d=json.loads(sys.argv[1]); exit(0 if 'issues' in d else 1)" "$RESPONSE" 2>/dev/null; then
  echo "check-inbox: Jira API request failed — check credentials and ATLASSIAN_URL."
  exit 0
fi

# ── Write inbox.md ────────────────────────────────────────────────────────────
python3 -c "
import sys, json
from datetime import datetime, timezone

data = json.loads(sys.argv[1])
atlassian_url, project_key, assignee_email, inbox_path = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
issues = data.get('issues', [])
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

lines = [
    '# Claude Inbox', '',
    f'Last updated: {now}  ',
    f'Project: {project_key}  ',
    f'Assignee: {assignee_email}', '',
]

if not issues:
    lines.append('No assigned tickets found. Nothing to work on yet.')
else:
    lines.append(f'## Assigned Tickets ({len(issues)} open)')
    lines.append('')
    for issue in issues:
        key = issue.get('key', '?')
        fields = issue.get('fields', {})
        summary = fields.get('summary', '(no summary)')
        status = (fields.get('status') or {}).get('name', '?')
        priority = (fields.get('priority') or {}).get('name', '?')
        url = f'{atlassian_url}/browse/{key}'
        lines.append(f'### [{key}]({url}): {summary}')
        lines.append(f'**Status:** {status}  **Priority:** {priority}')
        lines.append('')

with open(inbox_path, 'w') as f:
    f.write('\n'.join(lines) + '\n')
" "$RESPONSE" "$ATLASSIAN_URL" "$JIRA_PROJECT_KEY" "$JIRA_ASSIGNEE_EMAIL" "$INBOX"

# ── Print summary to terminal ─────────────────────────────────────────────────
TICKET_COUNT=$(python3 -c "import sys,json; print(len(json.loads(sys.argv[1]).get('issues',[])))" "$RESPONSE")

if [ "$TICKET_COUNT" = "0" ]; then
  echo "check-inbox: No assigned tickets in ${JIRA_PROJECT_KEY}."
else
  echo "check-inbox: Found ${TICKET_COUNT} assigned ticket(s) — run /session-start to begin."
  python3 -c "
import sys, json
data = json.loads(sys.argv[1])
for issue in data.get('issues', []):
    key = issue.get('key', '?')
    summary = (issue.get('fields') or {}).get('summary', '?')
    print(f'  {key}: {summary}')
" "$RESPONSE"
fi
