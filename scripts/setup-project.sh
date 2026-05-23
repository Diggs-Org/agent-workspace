#!/usr/bin/env bash
# Interactive one-time setup for a new repo cloned from this template.
# Fills in project.config and prints instructions for secrets and shell env vars.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/project.config"
CODEOWNERS="$REPO_ROOT/.github/CODEOWNERS"

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
EOF

echo ""
echo "✓ Written project.config"

# ── Update CODEOWNERS ─────────────────────────────────────────────────────────
if grep -q "GITHUB_REVIEWER_PLACEHOLDER" "$CODEOWNERS" 2>/dev/null; then
  sed -i "s/@GITHUB_REVIEWER_PLACEHOLDER/@${GITHUB_REVIEWER}/g" "$CODEOWNERS"
  echo "✓ Updated .github/CODEOWNERS → @${GITHUB_REVIEWER}"
fi

# ── Generate ATLASSIAN_BASIC_AUTH helper ──────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Next: Set these in your local shell environment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Add to ~/.zshrc or ~/.bashrc (never commit these):"
echo ""
echo "  export ATLASSIAN_EMAIL=\"${JIRA_ASSIGNEE_EMAIL}\""
echo "  export ATLASSIAN_URL=\"${ATLASSIAN_URL_INPUT}\""
echo "  export ATLASSIAN_API_TOKEN=\"<your-jira-api-token>\""
echo "  export ATLASSIAN_BASIC_AUTH=\"\$(echo -n '\${ATLASSIAN_EMAIL}:\${ATLASSIAN_API_TOKEN}' | base64)\""
echo "  export GITHUB_TOKEN=\"<your-github-pat>\""
echo "  export ANTHROPIC_API_KEY=\"<your-anthropic-api-key>\"   # if using Claude CLI locally"
echo ""
echo "Get a Jira API token at: https://id.atlassian.com/manage-profile/security/api-tokens"
echo "Get a GitHub PAT at:     https://github.com/settings/tokens"
echo "  → Required scopes: repo, pull_requests, read:org"
echo ""

# ── Remaining manual steps ────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Remaining one-time steps"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. Create the Claude Jira user:"
echo "   - Create a Jira account at: ${JIRA_ASSIGNEE_EMAIL}"
echo "   - Grant it project Edit permissions in ${JIRA_PROJECT_KEY}"
echo "   - Generate an API token for that account at:"
echo "     https://id.atlassian.com/manage-profile/security/api-tokens"
echo ""
echo "2. Install GitHub for Jira (one-time per Jira org):"
echo "   Jira Settings → Apps → Find new apps → search 'GitHub for Jira'"
echo "   Connect your GitHub org to enable the Development panel in tickets."
echo ""
echo "3. Enable GitHub Actions for this repo:"
echo "   GitHub → Settings → Actions → General → Allow all actions"
echo ""
echo "4. Commit project.config:"
echo "   git add project.config .github/CODEOWNERS && git commit -m 'Configure project settings'"
echo ""
echo "5. Reopen the devcontainer — check-inbox.sh will run on startup."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "After setting env vars, run:"
echo ""
echo "  bash scripts/check-inbox.sh"
echo ""
echo "You should see a list of Jira tickets assigned to ${JIRA_ASSIGNEE_EMAIL}."
echo "Then open Claude Code and run /session-start."
echo ""
