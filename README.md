# agent-workspace

Template repository for autonomous Claude Code projects. Clone this as the starting point for new projects where Claude handles Jira tickets end-to-end: planning, implementation, PR review, and merge — with no manual session management after initial setup.

## How It Works

```
Assign Jira ticket to Claude's account
        ↓  (detected within 60s by Jira poller)
Claude creates PLAN.md and opens a draft PR
        ↓  (you review and approve the draft PR on GitHub)
        ↓  (GitHub webhook triggers automatically)
Claude implements the changes, opens a non-draft PR
        ↓  (you review the code on GitHub)
        ↓  (GitHub webhook triggers automatically)
Claude addresses all comments, re-requests review
        ↓  (you approve on GitHub)
        ↓  (GitHub webhook triggers automatically)
Claude squash-merges and closes the Jira ticket
```

State is tracked in Jira ticket status and GitHub PR state. A local webhook server catches GitHub events and a Jira polling loop detect new tickets — both automatically trigger Claude sessions via a background tmux session. **Your only interaction is reviewing on GitHub and Jira.**

---

## New Repo Setup

Complete these steps once after cloning.

### 1. Run the setup script

```bash
bash scripts/setup-project.sh
```

This prompts for your project values, writes `project.config`, updates `CODEOWNERS`, generates a `GITHUB_WEBHOOK_SECRET`, and registers the GitHub webhook automatically (if `GITHUB_TOKEN` is set).

### 2. Set shell environment variables

Add to `~/.zshrc` or `~/.bashrc`. These are injected into the devcontainer at startup.

```bash
export ATLASSIAN_EMAIL="claude.you@gmail.com"
export ATLASSIAN_URL="https://yourorg.atlassian.net"
export ATLASSIAN_API_TOKEN="<jira-api-token>"
export ATLASSIAN_BASIC_AUTH="$(echo -n "${ATLASSIAN_EMAIL}:${ATLASSIAN_API_TOKEN}" | base64)"
export GITHUB_TOKEN="<github-pat-with-repo-and-read-org-scopes>"
export GITHUB_WEBHOOK_SECRET="<generated-by-setup-project.sh>"
```

> The setup script prints the exact values — copy them directly.

### 3. Create the Claude Jira user

1. Create a Jira account at the email in `project.config` (e.g. `claude.you@gmail.com`)
2. Grant it **Edit** permissions on your Jira project
3. Generate an API token at https://id.atlassian.com/manage-profile/security/api-tokens

### 4. Enable GitHub Actions

GitHub → Settings → Actions → General → **Allow all actions**

### 5. Install GitHub for Jira

Jira Settings → Apps → Find new apps → search **"GitHub for Jira"** → connect your GitHub org.
This populates the Development panel in Jira tickets with branches, commits, and PRs automatically.

### 6. Reopen the devcontainer

On startup, `scripts/start-session.sh` runs automatically and:
- Installs dependencies and cloudflared (first time only, via `postCreateCommand`)
- Starts the cloudflared tunnel and updates the GitHub webhook URL
- Starts the webhook server and Jira poller
- Opens a tmux session `claude-auto` with the `claude` CLI

Watch the terminal output on startup to confirm everything came up cleanly.

---

## Running the Webhook Server

The webhook server starts automatically when the devcontainer opens. This section covers manual operation and troubleshooting.

### Start everything manually

```bash
bash scripts/start-session.sh
```

Run this if the devcontainer started but the server is not running (e.g. after a crash or manual stop). It is safe to re-run — it kills any existing instances first.

### Check server health

```bash
curl http://localhost:3000/health
# {"status":"ok","time":"..."}
```

### Test the Jira connection

```bash
curl http://localhost:3000/debug/jira-poll
# Returns any newly detected assigned tickets
```

### Check what Claude is currently doing

```bash
curl http://localhost:3000/debug/status
# {"claude_status":"idle","seen_tickets":[...],"recent_events":[...]}
```

### Watch the server log

```bash
tail -f .claude/webhook-server.log
```

Or attach to the tmux session where pane 1 shows the live log:

```bash
tmux attach -t claude-auto
# Pane 0: claude CLI (the automated worker)
# Pane 1: live webhook-server.log
# Detach with: Ctrl-b d
```

### Start the server manually (without the full startup script)

```bash
# Install dependencies if needed
pip install fastapi uvicorn httpx

# Start the server
uvicorn scripts.webhook_server:app --host 0.0.0.0 --port 3000 --reload
```

### Start the cloudflared tunnel manually

```bash
# Install if not present
bash scripts/install-cloudflared.sh

# Start the tunnel
cloudflared tunnel --url http://localhost:3000 --no-autoupdate

# The tunnel URL appears in the output — update the GitHub webhook:
# GitHub → repo → Settings → Webhooks → edit → change URL to:
#   https://<tunnel-url>/webhook/github
```

### Simulate a GitHub webhook event (for testing)

```bash
# Generate a valid HMAC signature
PAYLOAD='{"action":"submitted","review":{"state":"approved"},"pull_request":{"draft":true,"number":1,"title":"[PLAN] TEST-1: test","head":{"ref":"TEST-1/test"}}}'
SIG="sha256=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$GITHUB_WEBHOOK_SECRET" | awk '{print $2}')"

curl -X POST http://localhost:3000/webhook/github \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: pull_request_review" \
  -H "X-Hub-Signature-256: $SIG" \
  -d "$PAYLOAD"
# Expected: {"status":"triggered"}
```

---

## Key Files

| File | Purpose |
|------|---------|
| `project.config` | Non-secret project metadata (Jira key, emails, GitHub reviewer, webhook ID) |
| `scripts/setup-project.sh` | One-time setup wizard — run after cloning |
| `scripts/start-session.sh` | Startup orchestrator (tunnel + webhook server + tmux) |
| `scripts/webhook-server.py` | FastAPI webhook server + Jira polling thread |
| `scripts/install-cloudflared.sh` | Installs cloudflared for public tunnel |
| `scripts/check-inbox.sh` | Manual Jira inbox check (debug/verification tool) |
| `.claude/commands/autonomous-ticket.md` | `/autonomous-ticket` skill — state-machine ticket handler |
| `.claude/commands/jira-workflow.md` | `/jira-workflow` skill — manual workflow reference |
| `.claude/commands/session-start.md` | `/session-start` skill — session orientation + inbox check |
| `.claude/hooks/` | PostToolUse hooks: Jira transitions, PR comments, coverage |
| `.claude/webhook-config.json` | Stores GitHub webhook ID for auto URL updates (gitignored) |
| `.claude/status` | `idle` or `busy` — read by webhook server before triggering |
| `.claude/inbox.md` | Latest pending work, updated by webhook server on each event |
| `.claude/event-log.json` | Last 100 webhook events received |
| `.devcontainer/devcontainer.json` | Dev container config |

---

## Daily Usage

After initial setup, your workflow is:

```
Open devcontainer in VS Code
  → start-session.sh runs automatically
  → Jira poller starts (60s interval)
  → GitHub webhook listener starts
  → tmux session "claude-auto" opens with claude CLI

Assign a Jira ticket to Claude's account
  → detected within 60 seconds
  → Claude creates PLAN.md, opens draft PR
  → you get a GitHub notification

Review the draft PR on GitHub
  → leave an Approving review
  → webhook fires instantly
  → Claude starts implementing

Review the code PR on GitHub
  → request changes or approve
  → webhook fires instantly
  → Claude addresses comments or merges

Done. The Jira ticket is closed automatically.
```

To observe Claude working at any time:

```bash
tmux attach -t claude-auto   # Ctrl-b d to detach
```

---

## Troubleshooting

**Webhook server not starting**
```bash
tail -20 .claude/webhook-server.log
pip install fastapi uvicorn httpx  # if missing
```

**cloudflared tunnel not getting a URL**
```bash
cat /tmp/cloudflared-3000.log  # check for errors
bash scripts/install-cloudflared.sh  # reinstall if needed
```

**GitHub webhook URL outdated after devcontainer restart**
```bash
# start-session.sh auto-updates it — check if it ran:
curl http://localhost:3000/health
# If server is up but webhooks aren't reaching it, check GitHub → repo → Settings → Webhooks → Recent Deliveries
```

**Claude not responding to events**
```bash
cat .claude/status  # should be "idle" between phases
curl http://localhost:3000/debug/status  # check recent_events
tmux capture-pane -t claude-auto:0 -pq | tail -20  # see what claude is doing
```

**Jira polling not finding tickets**
```bash
curl http://localhost:3000/debug/jira-poll  # manual poll with response
# Check ATLASSIAN_EMAIL, ATLASSIAN_API_TOKEN, ATLASSIAN_URL are set
echo $ATLASSIAN_EMAIL
```

For detailed setup instructions and Jira workflow state configuration see [`.claude/new-project-setup.md`](.claude/new-project-setup.md).
