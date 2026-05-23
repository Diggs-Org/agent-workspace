#!/usr/bin/env bash
# Interactive one-time setup for a new repo cloned from this template.
# Fills in project.config, registers the GitHub webhook, and prints env var instructions.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/project.config"
CODEOWNERS="$REPO_ROOT/.github/CODEOWNERS"
WEBHOOK_CONFIG="$REPO_ROOT/.claude/webhook-config.json"

mkdir -p "$REPO_ROOT/.claude"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Claude Code Template — New Project Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Collect values ────────────────────────────────────────────────────────────
read -rp "Jira project key (e.g. MYPROJ): " JIRA_PROJECT_KEY
read -rp "Jira email Claude uses (e.g. claude.you@gmail.com): " JIRA_ASSIGNEE_EMAIL
read -rp "Your GitHub username (for code review): " GITHUB_REVIEWER
read -rp "Atlassian URL (e.g. https://yourorg.atlassian.net): " ATLASSIAN_URL_INPUT

ATLASSIAN_URL_INPUT="${ATLASSIAN_URL_INPUT%/}"  # strip trailing slash

# ── Write project.config ──────────────────────────────────────────────────────
cat > "$CONFIG" <<EOF
# Project configuration for autonomous Claude Code workflow.
# Commit this file. Do NOT put secrets here — secrets go in local shell env vars.

# Jira project key (e.g. MYPROJ — tickets will be MYPROJ-1, MYPROJ-2, ...)
JIRA_PROJECT_KEY=${JIRA_PROJECT_KEY}

# Jira account email that Claude uses (tickets assigned to this email trigger Claude)
JIRA_ASSIGNEE_EMAIL=${JIRA_ASSIGNEE_EMAIL}

# GitHub username of the human reviewer (for CODEOWNERS and re-request-review)
GITHUB_REVIEWER=${GITHUB_REVIEWER}

# Your Atlassian instance URL (no trailing slash)
ATLASSIAN_URL=${ATLASSIAN_URL_INPUT}

# GitHub webhook ID (set by setup-project.sh — do not edit manually)
GITHUB_WEBHOOK_ID=
EOF

echo ""
echo "✓ Written project.config"

# ── Update CODEOWNERS ─────────────────────────────────────────────────────────
if grep -q "GITHUB_REVIEWER_PLACEHOLDER" "$CODEOWNERS" 2>/dev/null; then
  sed -i "s/@GITHUB_REVIEWER_PLACEHOLDER/@${GITHUB_REVIEWER}/g" "$CODEOWNERS"
  echo "✓ Updated .github/CODEOWNERS → @${GITHUB_REVIEWER}"
fi

# ── Generate webhook secret ───────────────────────────────────────────────────
WEBHOOK_SECRET=$(openssl rand -hex 20)
echo "✓ Generated GITHUB_WEBHOOK_SECRET"

# ── Register GitHub webhook ───────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Registering GitHub webhook"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "⚠️  GITHUB_TOKEN not set — skipping webhook registration."
  echo "   Set it and re-run this script, or register manually in GitHub → Settings → Webhooks."
  GITHUB_REPO_FULL=""
else
  # Detect repo from git remote
  REMOTE_URL=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")
  GITHUB_REPO_FULL=$(echo "$REMOTE_URL" | python3 -c "
import sys, re
url = sys.stdin.read().strip()
m = re.search(r'github\.com[:/](.+?)(?:\.git)?\$', url)
print(m.group(1) if m else '')
" 2>/dev/null || echo "")

  if [ -z "$GITHUB_REPO_FULL" ]; then
    echo "⚠️  Could not detect GitHub repo from git remote — skipping webhook registration."
    echo "   Register manually in GitHub → ${GITHUB_REPO_FULL} → Settings → Webhooks"
    echo "     URL:    https://<your-tunnel-url>/webhook/github"
    echo "     Events: Pull request reviews"
    echo "     Secret: ${WEBHOOK_SECRET}"
  else
    # Create a placeholder webhook (URL will be updated each devcontainer start)
    RESPONSE=$(curl -sf \
      -X POST \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      -d "{
        \"name\": \"web\",
        \"active\": true,
        \"events\": [\"pull_request_review\"],
        \"config\": {
          \"url\": \"https://placeholder.trycloudflare.com/webhook/github\",
          \"content_type\": \"json\",
          \"secret\": \"${WEBHOOK_SECRET}\"
        }
      }" \
      "https://api.github.com/repos/${GITHUB_REPO_FULL}/hooks" 2>/dev/null || echo "{}")

    WEBHOOK_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

    if [ -n "$WEBHOOK_ID" ]; then
      # Store webhook ID for future URL updates
      echo "{\"id\": ${WEBHOOK_ID}, \"repo\": \"${GITHUB_REPO_FULL}\"}" > "$WEBHOOK_CONFIG"
      # Also write ID back into project.config
      sed -i "s/^GITHUB_WEBHOOK_ID=$/GITHUB_WEBHOOK_ID=${WEBHOOK_ID}/" "$CONFIG"
      echo "✓ GitHub webhook registered (ID: ${WEBHOOK_ID}) for ${GITHUB_REPO_FULL}"
      echo "  URL will be updated automatically on each devcontainer start."
    else
      echo "⚠️  GitHub webhook registration failed."
      echo "   Response: $(echo "$RESPONSE" | head -c 200)"
      echo "   Register manually in GitHub → Settings → Webhooks with secret: ${WEBHOOK_SECRET}"
    fi
  fi
fi

# ── Print environment variable instructions ───────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Set these in your local shell environment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Add to ~/.zshrc or ~/.bashrc (never commit these):"
echo ""
echo "  export ATLASSIAN_EMAIL=\"${JIRA_ASSIGNEE_EMAIL}\""
echo "  export ATLASSIAN_URL=\"${ATLASSIAN_URL_INPUT}\""
echo "  export ATLASSIAN_API_TOKEN=\"<your-jira-api-token>\""
echo "  export ATLASSIAN_BASIC_AUTH=\"\$(echo -n '\${ATLASSIAN_EMAIL}:\${ATLASSIAN_API_TOKEN}' | base64)\""
echo "  export GITHUB_TOKEN=\"<your-github-pat>\""
echo "  export GITHUB_WEBHOOK_SECRET=\"${WEBHOOK_SECRET}\""
echo "  export ANTHROPIC_API_KEY=\"<your-anthropic-api-key>\"   # if using Claude CLI locally"
echo ""
echo "Get a Jira API token at: https://id.atlassian.com/manage-profile/security/api-tokens"
echo "Get a GitHub PAT at:     https://github.com/settings/tokens"
echo "  → Required scopes: repo, pull_requests, read:org"
echo ""

# ── Remaining one-time steps ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Remaining one-time steps"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. Create the Claude Jira user:"
echo "   - Create a Jira account at: ${JIRA_ASSIGNEE_EMAIL}"
echo "   - Grant it project Edit permissions in ${JIRA_PROJECT_KEY}"
echo "   - Generate an API token: https://id.atlassian.com/manage-profile/security/api-tokens"
echo ""
echo "2. Install GitHub for Jira (one-time per Jira org):"
echo "   Jira Settings → Apps → Find new apps → search 'GitHub for Jira'"
echo "   Connect your GitHub org to enable the Development panel in tickets."
echo ""
echo "3. Enable GitHub Actions for this repo:"
echo "   GitHub → Settings → Actions → General → Allow all actions"
echo ""
echo "4. Commit the updated files:"
echo "   git add project.config .github/CODEOWNERS && git commit -m 'Configure project settings'"
echo ""
echo "5. Reopen the devcontainer — start-session.sh runs automatically and:"
echo "   - Starts the cloudflared tunnel and updates the GitHub webhook URL"
echo "   - Starts the webhook server + Jira poller"
echo "   - Opens a tmux session 'claude-auto' with the claude CLI"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "After reopening the devcontainer:"
echo ""
echo "  curl http://localhost:3000/health           # webhook server running?"
echo "  curl http://localhost:3000/debug/jira-poll  # Jira connection working?"
echo "  tmux attach -t claude-auto                  # observe Claude's tmux session"
echo ""
