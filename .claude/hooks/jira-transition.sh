#!/usr/bin/env bash
# Transitions the Jira ticket embedded in the current branch name.
# Usage: jira-transition.sh <in_progress|in_review|done>
set -euo pipefail

TARGET_STATE="${1:-}"
if [ -z "$TARGET_STATE" ]; then
  printf '{"continue": true}'
  exit 0
fi

# Primary: extract issue key from current branch (e.g. PROJECT-123/short-description)
BRANCH=$(git -C /workspaces/puzzle rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
ISSUE_KEY=$(echo "$BRANCH" | grep -oE '[A-Z]+-[0-9]+' | head -1)

# Fallback: parse stdin (PostToolUse tool_response may contain branch name)
if [ -z "$ISSUE_KEY" ]; then
  STDIN_DATA=$(cat 2>/dev/null || echo "{}")
  ISSUE_KEY=$(echo "$STDIN_DATA" | python3 -c "
import sys, json, re
try:
    d = json.load(sys.stdin)
    # look in tool_response or tool_input for a branch field
    for v in [d.get('tool_response', {}), d.get('tool_input', {})]:
        for key in ['name', 'branch', 'head', 'ref']:
            val = v.get(key, '') if isinstance(v, dict) else ''
            m = re.search(r'[A-Z]+-[0-9]+', str(val))
            if m:
                print(m.group(0))
                sys.exit(0)
except Exception:
    pass
" 2>/dev/null || echo "")
fi

if [ -z "$ISSUE_KEY" ]; then
  printf '{"continue": true, "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "No Jira issue key found in branch name — skipping transition."}}'
  exit 0
fi

AUTH=$(printf '%s:%s' "$ATLASSIAN_EMAIL" "$ATLASSIAN_API_TOKEN" | base64 -w 0)
TRANSITIONS_URL="${ATLASSIAN_URL}/rest/api/3/issue/${ISSUE_KEY}/transitions"

# Fetch available transitions
TRANSITIONS=$(curl -sf \
  -H "Authorization: Basic ${AUTH}" \
  -H "Accept: application/json" \
  "${TRANSITIONS_URL}" 2>/dev/null || echo '{"transitions":[]}')

# Fuzzy-match transition name to target state
case "$TARGET_STATE" in
  in_progress)
    PATTERN='In Progress|Start|Begin Work'
    ;;
  in_review)
    PATTERN='In Review|Review|Code Review|PR Open'
    ;;
  done)
    PATTERN='Done|Closed|Complete|Resolved'
    ;;
  *)
    printf '{"continue": true}'
    exit 0
    ;;
esac

TRANSITION_ID=$(echo "$TRANSITIONS" | python3 -c "
import sys, json, re
try:
    data = json.load(sys.stdin)
    pattern = sys.argv[1]
    for t in data.get('transitions', []):
        if re.search(pattern, t.get('name', ''), re.IGNORECASE):
            print(t['id'])
            break
except Exception:
    pass
" "$PATTERN" 2>/dev/null || echo "")

if [ -z "$TRANSITION_ID" ]; then
  AVAILABLE=$(echo "$TRANSITIONS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(', '.join(t.get('name','') for t in data.get('transitions',[])))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")
  printf '{"continue": true, "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "Could not match Jira transition \"%s\" for %s. Available: %s"}}\n' \
    "$TARGET_STATE" "$ISSUE_KEY" "$AVAILABLE"
  exit 0
fi

# Execute the transition
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  -H "Authorization: Basic ${AUTH}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d "{\"transition\":{\"id\":\"${TRANSITION_ID}\"}}" \
  "${TRANSITIONS_URL}" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "204" ]; then
  printf '{"continue": true, "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "Jira: %s → %s ✓"}}\n' \
    "$ISSUE_KEY" "$TARGET_STATE"
else
  printf '{"continue": true, "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "Jira transition for %s to %s returned HTTP %s — check token scopes."}}\n' \
    "$ISSUE_KEY" "$TARGET_STATE" "$HTTP_CODE"
fi
