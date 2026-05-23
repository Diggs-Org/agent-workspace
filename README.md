# agent-workspace

Template repository for autonomous Claude Code projects. Clone this as the starting point for new projects where Claude handles Jira tickets end-to-end: planning, implementation, PR review, and merge.

## How It Works

1. A Jira ticket is assigned to Claude's account → devcontainer startup detects it
2. Run `/session-start` → Claude reads the inbox, creates an implementation plan, and opens a draft PR
3. You review the plan on GitHub and leave an Approving review
4. Next `/session-start` → Claude detects the approval, implements the changes, converts the PR to non-draft
5. You review the code → Claude addresses all comments, re-requests review
6. You approve → Claude squash-merges and closes the Jira ticket

State is tracked in Jira ticket status and GitHub PR state — each session picks up exactly where the last one left off.

## New Repo Setup

After cloning this template, complete these steps once:

**1. Run the setup script**
```bash
bash scripts/setup-project.sh
```
This fills in `project.config`, updates `CODEOWNERS`, and prints all the credentials you need to gather.

**2. Set shell environment variables**
Add to `~/.zshrc` or `~/.bashrc` (these are injected into the devcontainer):
```bash
export ATLASSIAN_EMAIL="claude.you@gmail.com"
export ATLASSIAN_URL="https://yourorg.atlassian.net"
export ATLASSIAN_API_TOKEN="<jira-api-token>"
export ATLASSIAN_BASIC_AUTH="$(echo -n "${ATLASSIAN_EMAIL}:${ATLASSIAN_API_TOKEN}" | base64)"
export GITHUB_TOKEN="<github-pat>"
```

**3. Create the Claude Jira user**
- Create a Jira account for Claude (e.g. `claude.you@gmail.com`)
- Grant it Edit permissions on the project
- Generate an API token at `https://id.atlassian.com/manage-profile/security/api-tokens`

**4. Enable GitHub Actions**
GitHub → Settings → Actions → General → Allow all actions

**5. Install GitHub for Jira**
Jira Settings → Apps → Find new apps → search "GitHub for Jira" → connect your GitHub org

**6. Reopen the devcontainer**
The startup script will query Jira and print any assigned tickets.

**7. Open Claude Code and run `/session-start`**
Claude reads the inbox and begins working on the highest-priority ticket.

For detailed setup instructions see [`.claude/new-project-setup.md`](.claude/new-project-setup.md).

## Key Files

| File | Purpose |
|------|---------|
| `project.config` | Non-secret project metadata (Jira key, emails, GitHub reviewer) |
| `scripts/setup-project.sh` | One-time setup wizard |
| `scripts/check-inbox.sh` | Queries Jira for assigned tickets (runs on devcontainer start) |
| `.claude/commands/autonomous-ticket.md` | Autonomous ticket workflow skill (`/autonomous-ticket`) |
| `.claude/commands/jira-workflow.md` | Manual workflow reference (`/jira-workflow`) |
| `.claude/hooks/` | PostToolUse hooks for Jira transitions, PR comments, coverage |
| `.devcontainer/devcontainer.json` | Dev container config with `postStartCommand` |

## Daily Usage

```
Open devcontainer in VS Code
  → check-inbox.sh runs automatically, finds assigned tickets
  → Open Claude Code
  → Run /session-start
  → Claude works on the highest-priority ticket to the next review checkpoint
  → Review on GitHub
  → Next /session-start continues from where it left off
```
