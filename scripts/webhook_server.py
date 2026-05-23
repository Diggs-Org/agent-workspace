"""
Webhook server + Jira poller for autonomous Claude Code session triggering.

Listens for GitHub webhook events and polls Jira to detect when Claude needs to act:
  - Jira ticket assigned (new) → Phase 1 (plan)
  - GitHub draft PR approved   → Phase 2 (implement)
  - GitHub PR changes requested → Phase 3 (address review)
  - GitHub non-draft PR approved → Phase 4 (merge)

When an event fires, updates .claude/inbox.md and triggers /session-start in the
"claude-auto" tmux session if Claude is idle. Falls back to notify-send if tmux
session is not found.

Usage:
    uvicorn scripts.webhook_server:app --host 0.0.0.0 --port 3000
"""

import base64
import hashlib
import hmac
import json
import logging
import os
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from contextlib import asynccontextmanager

try:
    from fastapi import FastAPI, HTTPException, Request
    from fastapi.responses import JSONResponse
except ImportError:
    raise SystemExit("fastapi not installed — run: pip install fastapi uvicorn httpx")

# ── Configuration ─────────────────────────────────────────────────────────────

REPO_ROOT = Path(__file__).parent.parent
CONFIG_FILE = REPO_ROOT / "project.config"
INBOX_FILE = REPO_ROOT / ".claude" / "inbox.md"
STATUS_FILE = REPO_ROOT / ".claude" / "status"
EVENT_LOG = REPO_ROOT / ".claude" / "event-log.json"
SEEN_TICKETS = REPO_ROOT / ".claude" / "seen-tickets.json"
LOG_FILE = REPO_ROOT / ".claude" / "webhook-server.log"
TMUX_SESSION = "claude-auto"
JIRA_POLL_INTERVAL = 60  # seconds

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(),
    ],
)
log = logging.getLogger(__name__)


def load_config() -> dict[str, str]:
    """Load project.config and environment variables."""
    config: dict[str, str] = {}
    if CONFIG_FILE.exists():
        for line in CONFIG_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                config[key.strip()] = value.strip()
    # Environment variables take precedence
    for key in ["ATLASSIAN_EMAIL", "ATLASSIAN_API_TOKEN", "ATLASSIAN_URL",
                 "GITHUB_TOKEN", "GITHUB_WEBHOOK_SECRET"]:
        if os.environ.get(key):
            config[key] = os.environ[key]
    return config


# ── FastAPI app ───────────────────────────────────────────────────────────────


@asynccontextmanager
async def lifespan(app: FastAPI):
    t = threading.Thread(target=jira_poll_loop, daemon=True)
    t.start()
    log.info("Jira polling thread started (interval: %ds)", JIRA_POLL_INTERVAL)
    yield


app = FastAPI(title="Claude Webhook Server", lifespan=lifespan)


@app.get("/health")
def health():
    return {"status": "ok", "time": datetime.now(timezone.utc).isoformat()}


@app.get("/debug/status")
def debug_status():
    status = STATUS_FILE.read_text().strip() if STATUS_FILE.exists() else "unknown"
    seen = json.loads(SEEN_TICKETS.read_text()) if SEEN_TICKETS.exists() else []
    events = json.loads(EVENT_LOG.read_text()) if EVENT_LOG.exists() else []
    return {"claude_status": status, "seen_tickets": seen, "recent_events": events[-5:]}


@app.get("/debug/jira-poll")
def debug_jira_poll():
    """Manually trigger a Jira poll and return results."""
    config = load_config()
    result = poll_jira_once(config)
    return {"new_tickets": result}


@app.post("/webhook/github")
async def github_webhook(request: Request):
    config = load_config()
    secret = config.get("GITHUB_WEBHOOK_SECRET", "")

    body = await request.body()

    # Validate HMAC signature
    if secret:
        sig_header = request.headers.get("X-Hub-Signature-256", "")
        expected = "sha256=" + hmac.new(
            secret.encode(), body, hashlib.sha256
        ).hexdigest()
        if not hmac.compare_digest(sig_header, expected):
            log.warning("GitHub webhook: invalid signature — check GITHUB_WEBHOOK_SECRET")
            raise HTTPException(status_code=401, detail="Invalid signature")
    else:
        log.warning("GITHUB_WEBHOOK_SECRET not set — skipping signature validation")

    event_type = request.headers.get("X-GitHub-Event", "")
    payload = json.loads(body)

    if event_type != "pull_request_review":
        return JSONResponse({"status": "ignored", "event": event_type})

    action = payload.get("action", "")
    review = payload.get("review", {})
    pr = payload.get("pull_request", {})

    if action != "submitted":
        return JSONResponse({"status": "ignored", "action": action})

    review_state = review.get("state", "").lower()
    is_draft = pr.get("draft", False)
    pr_number = pr.get("number")
    pr_title = pr.get("title", "")
    branch = pr.get("head", {}).get("ref", "")
    reviewer = review.get("user", {}).get("login", "?")

    log.info("PR review event: state=%s draft=%s PR#%s", review_state, is_draft, pr_number)

    if review_state == "approved" and is_draft:
        trigger_session("plan_approved", {
            "pr_number": pr_number,
            "pr_title": pr_title,
            "branch": branch,
            "reviewer": reviewer,
            "phase": "Phase 2: Implement",
        })
    elif review_state == "changes_requested" and not is_draft:
        trigger_session("review_changes_requested", {
            "pr_number": pr_number,
            "pr_title": pr_title,
            "branch": branch,
            "reviewer": reviewer,
            "phase": "Phase 3: Address Review",
        })
    elif review_state == "approved" and not is_draft:
        trigger_session("pr_approved", {
            "pr_number": pr_number,
            "pr_title": pr_title,
            "branch": branch,
            "reviewer": reviewer,
            "phase": "Phase 4: Merge",
        })
    else:
        return JSONResponse({"status": "ignored", "review_state": review_state, "is_draft": is_draft})

    return JSONResponse({"status": "triggered"})


# ── Jira polling ──────────────────────────────────────────────────────────────

def jira_poll_loop():
    """Background thread: polls Jira every JIRA_POLL_INTERVAL seconds."""
    while True:
        try:
            config = load_config()
            poll_jira_once(config)
        except Exception as e:
            log.error("Jira poll error: %s", e)
        time.sleep(JIRA_POLL_INTERVAL)


def poll_jira_once(config: dict[str, str]) -> list[str]:
    """Query Jira for new tickets, trigger sessions for newly assigned ones."""
    required = ["ATLASSIAN_EMAIL", "ATLASSIAN_API_TOKEN", "ATLASSIAN_URL",
                 "JIRA_PROJECT_KEY", "JIRA_ASSIGNEE_EMAIL"]
    if not all(config.get(k) for k in required):
        log.debug("Jira poll skipped: config incomplete")
        return []

    jql = (
        f'project = {config["JIRA_PROJECT_KEY"]} '
        f'AND assignee = "{config["JIRA_ASSIGNEE_EMAIL"]}" '
        f'AND statusCategory = "To Do" '
        f'ORDER BY created ASC'
    )
    encoded_jql = urllib.parse.quote(jql)
    url = f'{config["ATLASSIAN_URL"]}/rest/api/3/search?jql={encoded_jql}&fields=summary,status&maxResults=20'

    credentials = f'{config["ATLASSIAN_EMAIL"]}:{config["ATLASSIAN_API_TOKEN"]}'
    auth = base64.b64encode(credentials.encode()).decode()

    req = urllib.request.Request(url, headers={
        "Authorization": f"Basic {auth}",
        "Accept": "application/json",
    })

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        log.warning("Jira API error: %s", e)
        return []

    current_keys = {issue["key"] for issue in data.get("issues", [])}
    seen = set(json.loads(SEEN_TICKETS.read_text()) if SEEN_TICKETS.exists() else [])

    new_tickets = list(current_keys - seen)
    for key in new_tickets:
        issue = next(i for i in data["issues"] if i["key"] == key)
        summary = (issue.get("fields") or {}).get("summary", "?")
        log.info("New Jira ticket detected: %s — %s", key, summary)
        trigger_session("jira_assigned", {
            "issue_key": key,
            "summary": summary,
            "phase": "Phase 1: Plan",
        })

    # Update seen tickets to all currently assigned (not just new ones)
    SEEN_TICKETS.write_text(json.dumps(sorted(current_keys)))
    return new_tickets


# ── Session triggering ────────────────────────────────────────────────────────

def trigger_session(event_type: str, context: dict[str, Any]):
    """Update inbox, log event, and send /session-start to Claude if idle."""
    now = datetime.now(timezone.utc).isoformat()
    log.info("Triggering session: event=%s context=%s", event_type, context)

    # 1. Log the event
    events = json.loads(EVENT_LOG.read_text()) if EVENT_LOG.exists() else []
    events.append({"time": now, "event": event_type, "context": context})
    EVENT_LOG.write_text(json.dumps(events[-100:], indent=2))  # keep last 100

    # 2. Update inbox.md
    update_inbox(event_type, context, now)

    # 3. Trigger Claude if idle
    claude_status = STATUS_FILE.read_text().strip() if STATUS_FILE.exists() else "idle"

    if claude_status == "busy":
        log.info("Claude is busy — event queued in inbox (will pick up when idle)")
        return

    # Try tmux first
    if send_to_tmux("/session-start"):
        log.info("Sent /session-start to tmux session '%s'", TMUX_SESSION)
        return

    # Fallback: desktop notification
    send_notification(event_type, context)


def send_to_tmux(command: str) -> bool:
    """Send a command to the claude-auto tmux session. Returns True if successful."""
    try:
        # Check if session exists
        result = subprocess.run(
            ["tmux", "has-session", "-t", TMUX_SESSION],
            capture_output=True, timeout=5
        )
        if result.returncode != 0:
            log.warning("tmux session '%s' not found", TMUX_SESSION)
            return False

        # Send the command
        subprocess.run(
            ["tmux", "send-keys", "-t", f"{TMUX_SESSION}:0", command, "Enter"],
            check=True, timeout=5
        )
        return True
    except (subprocess.SubprocessError, FileNotFoundError) as e:
        log.warning("tmux send-keys failed: %s", e)
        return False


def send_notification(event_type: str, context: dict[str, Any]):
    """Send a desktop notification as fallback."""
    phase = context.get("phase", event_type)
    title = "Claude Code — Action Needed"
    message = f"{phase} — run /session-start in Claude Code"
    try:
        subprocess.run(["notify-send", title, message], timeout=5)
        log.info("Desktop notification sent: %s", message)
    except (subprocess.SubprocessError, FileNotFoundError):
        log.warning("notify-send not available — event logged to inbox.md only")


def update_inbox(event_type: str, context: dict[str, Any], timestamp: str):
    """Write a concise inbox.md summarising the triggering event."""
    phase = context.get("phase", event_type)
    lines = [
        "# Claude Inbox",
        "",
        f"Last event: {timestamp}",
        f"Trigger: **{phase}**",
        "",
    ]

    if event_type == "jira_assigned":
        key = context.get("issue_key", "?")
        summary = context.get("summary", "?")
        atlassian_url = load_config().get("ATLASSIAN_URL", "")
        lines += [
            f"## New Ticket: [{key}]({atlassian_url}/browse/{key})",
            f"**{summary}**",
            "",
            "Run `/autonomous-ticket` to begin planning.",
        ]
    elif event_type == "plan_approved":
        lines += [
            f"## Plan Approved: PR #{context.get('pr_number')}",
            f"Branch: `{context.get('branch')}`",
            f"Approved by: @{context.get('reviewer')}",
            "",
            "Run `/autonomous-ticket` to begin implementation.",
        ]
    elif event_type == "review_changes_requested":
        lines += [
            f"## Changes Requested: PR #{context.get('pr_number')}",
            f"Branch: `{context.get('branch')}`",
            f"Reviewer: @{context.get('reviewer')}",
            "",
            "Run `/autonomous-ticket` to address review comments.",
        ]
    elif event_type == "pr_approved":
        lines += [
            f"## PR Approved — Ready to Merge: PR #{context.get('pr_number')}",
            f"Branch: `{context.get('branch')}`",
            f"Approved by: @{context.get('reviewer')}",
            "",
            "Run `/autonomous-ticket` to squash-merge.",
        ]

    INBOX_FILE.write_text("\n".join(lines) + "\n")
