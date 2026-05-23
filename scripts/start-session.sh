#!/usr/bin/env bash
# Startup orchestrator for autonomous Claude Code sessions.
# Run automatically by postStartCommand when the devcontainer starts.
#
# What this does:
#   1. Starts a cloudflared tunnel to expose the webhook server publicly
#   2. Updates the GitHub webhook URL via the API (idempotent)
#   3. Starts the webhook server (FastAPI + Jira poller)
#   4. Creates a tmux session "claude-auto" with the claude CLI
#
# The user can observe Claude's work by running: tmux attach -t claude-auto
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/project.config"
WEBHOOK_CONFIG="$REPO_ROOT/.claude/webhook-config.json"
LOG_DIR="$REPO_ROOT/.claude"
WEBHOOK_PORT=3000
TMUX_SESSION="claude-auto"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[start-session]${NC} $*"; }
warn()  { echo -e "${YELLOW}[start-session]${NC} $*"; }
error() { echo -e "${RED}[start-session]${NC} $*"; }

# ── Load config ───────────────────────────────────────────────────────────────
if [ ! -f "$CONFIG" ]; then
  warn "project.config not found — run scripts/setup-project.sh first."
  exit 0
fi
# shellcheck source=/dev/null
source "$CONFIG"

if [ -z "${JIRA_PROJECT_KEY:-}" ] || [ "${JIRA_PROJECT_KEY}" = "PROJ" ]; then
  warn "project.config has placeholder values — run scripts/setup-project.sh first."
  exit 0
fi

mkdir -p "$LOG_DIR"

# Reset status — a prior busy state may be stale after a container restart
echo "idle" > "$LOG_DIR/status"

# ── 1. Start cloudflared tunnel ───────────────────────────────────────────────
if ! command -v cloudflared &>/dev/null; then
  warn "cloudflared not installed — webhook triggering disabled."
  warn "Install with: bash scripts/install-cloudflared.sh"
  PUBLIC_URL=""
else
  info "Starting cloudflared tunnel on port ${WEBHOOK_PORT}..."
  CF_LOG="/tmp/cloudflared-${WEBHOOK_PORT}.log"
  pkill -f "cloudflared tunnel --url http://localhost:${WEBHOOK_PORT}" 2>/dev/null || true
  cloudflared tunnel --url "http://localhost:${WEBHOOK_PORT}" --no-autoupdate \
    > "$CF_LOG" 2>&1 &
  CF_PID=$!

  # Wait up to 30s for the tunnel URL to appear
  PUBLIC_URL=""
  for i in $(seq 1 30); do
    sleep 1
    PUBLIC_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1 || true)
    if [ -n "$PUBLIC_URL" ]; then break; fi
  done

  if [ -z "$PUBLIC_URL" ]; then
    warn "cloudflared tunnel failed to start within 30s — webhook triggering disabled."
    warn "Check $CF_LOG for details."
    kill "$CF_PID" 2>/dev/null || true
  else
    info "Tunnel URL: ${PUBLIC_URL}"
  fi
fi

# ── 2. Update GitHub webhook URL ──────────────────────────────────────────────
if [ -n "${PUBLIC_URL:-}" ] && [ -n "${GITHUB_TOKEN:-}" ] && [ -f "$WEBHOOK_CONFIG" ]; then
  WEBHOOK_ID=$(python3 -c "import json; print(json.load(open('$WEBHOOK_CONFIG')).get('id',''))" 2>/dev/null || echo "")
  REPO_FULL=$(python3 -c "import json; print(json.load(open('$WEBHOOK_CONFIG')).get('repo',''))" 2>/dev/null || echo "")

  if [ -n "$WEBHOOK_ID" ] && [ -n "$REPO_FULL" ]; then
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
      -X PATCH \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      -d "{\"config\":{\"url\":\"${PUBLIC_URL}/webhook/github\",\"content_type\":\"json\",\"secret\":\"${GITHUB_WEBHOOK_SECRET:-}\"}}" \
      "https://api.github.com/repos/${REPO_FULL}/hooks/${WEBHOOK_ID}" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "200" ]; then
      info "GitHub webhook URL updated → ${PUBLIC_URL}/webhook/github"
    else
      warn "GitHub webhook update returned HTTP ${HTTP_CODE} — webhooks may use old URL"
    fi
  else
    warn "webhook-config.json missing or incomplete — GitHub webhook URL not updated."
    warn "Run scripts/setup-project.sh to register the webhook."
  fi
elif [ -z "${PUBLIC_URL:-}" ]; then
  : # already warned above
elif [ -z "${GITHUB_TOKEN:-}" ]; then
  warn "GITHUB_TOKEN not set — cannot update GitHub webhook URL"
fi

# ── 3. Start webhook server ───────────────────────────────────────────────────
info "Starting webhook server on port ${WEBHOOK_PORT}..."

# Kill any existing instance
pkill -f "uvicorn scripts.webhook_server:app" 2>/dev/null || true
sleep 1

cd "$REPO_ROOT"
nohup python3 -m uvicorn scripts.webhook_server:app \
  --host 0.0.0.0 \
  --port "$WEBHOOK_PORT" \
  --log-level warning \
  >> "$LOG_DIR/webhook-server.log" 2>&1 &
WEBHOOK_PID=$!

# Wait for it to be ready
for i in $(seq 1 10); do
  sleep 1
  if curl -sf "http://localhost:${WEBHOOK_PORT}/health" &>/dev/null; then
    info "Webhook server ready (PID ${WEBHOOK_PID})"
    break
  fi
done

if ! curl -sf "http://localhost:${WEBHOOK_PORT}/health" &>/dev/null; then
  warn "Webhook server did not start — check .claude/webhook-server.log"
fi

# ── 4. Create tmux session with claude CLI ────────────────────────────────────
if ! command -v tmux &>/dev/null; then
  warn "tmux not installed — install with: sudo apt-get install -y tmux"
  warn "Claude will not be auto-triggered; you must run /session-start manually."
else
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    info "tmux session '${TMUX_SESSION}' already running."
  else
    info "Creating tmux session '${TMUX_SESSION}' with claude CLI..."
    tmux new-session -d -s "$TMUX_SESSION" -x 220 -y 50 -c "$REPO_ROOT"

    # Pane 0: claude CLI (the automated worker)
    tmux send-keys -t "${TMUX_SESSION}:0" "claude" Enter

    # Pane 1: webhook server log viewer
    tmux split-window -t "$TMUX_SESSION" -v -c "$REPO_ROOT"
    tmux send-keys -t "${TMUX_SESSION}:0.1" "tail -f .claude/webhook-server.log" Enter

    # Focus back to claude pane
    tmux select-pane -t "${TMUX_SESSION}:0.0"

    info "tmux session '${TMUX_SESSION}' created."
    info "Observe with: tmux attach -t ${TMUX_SESSION}"
  fi
fi

# ── 5. Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Claude autonomous session ready${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
[ -n "${PUBLIC_URL:-}" ] && echo "  Webhook URL:  ${PUBLIC_URL}/webhook/github"
echo "  Webhook port: http://localhost:${WEBHOOK_PORT}"
echo "  Logs:         .claude/webhook-server.log"
command -v tmux &>/dev/null && echo "  Observe:      tmux attach -t ${TMUX_SESSION}"
echo ""
echo "  Jira polling: every ${JIRA_POLL_INTERVAL:-60}s for new tickets assigned to ${JIRA_ASSIGNEE_EMAIL}"
echo ""
