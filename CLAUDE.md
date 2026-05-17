# Puzzle Service — Claude Code Instructions

## Setup (run once after container creation)

```bash
npm install                                 # installs deps + ESLint
chmod +x .claude/hooks/*.sh                # make hooks executable
python3 scripts/index-codebase.py --full   # build initial codebase index
```

## Jira Ticket Workflow

When asked to "work a ticket":

1. **Get assigned tickets** — use the Atlassian MCP to list tickets assigned to `claude.danielsdiggs@gmail.com`
2. **Pick the highest-priority unresolved ticket**
3. **Create branch** via `mcp__github__create_branch` using the naming convention:
   `PROJECT-123/short-description` (Jira key *must* be the branch prefix)
   - PostToolUse hooks auto-run: Jira → **In Progress**, comment + remote link posted to Jira issue
4. **Implement changes**, committing as you go
5. **Create PR** via `mcp__github__create_pull_request`
   - PostToolUse hooks auto-run: Jira → **In Review**, coverage report posted as PR comment
6. **Read the PR** via `mcp__github__pull_request_read` when addressing review comments
   - PostToolUse hook auto-fetches all inline review comments and PR comments into context
7. After the user approves and merges via `mcp__github__merge_pull_request`:
   - PostToolUse hook auto-transitions Jira → **Done**

> Branch naming is critical: hooks extract the Jira key using `[A-Z]+-[0-9]+`.
> The branch must start with the Jira key (e.g. `PROJECT-123/...`).

### Jira Development Panel (full integration)

For branches, commits, and PRs to appear in Jira's native Development panel, install the **GitHub for Jira** app:
> Jira Settings → Apps → Find new apps → search "GitHub for Jira"

Once connected, any branch/commit/PR referencing a Jira issue key is automatically linked — no extra hook work needed for that panel.

## Codebase Navigation (context efficiency)

Before reading any source file, consult `.claude/codebase-index.json`.

1. **Hash matches** → use `symbols`, `imports`, `exports` from the index. Skip reading the file.
2. **Hash mismatch** → re-index the file:
   ```bash
   python3 scripts/index-codebase.py --file <path>
   ```
3. **File not in index** → run incremental pass then retry:
   ```bash
   python3 scripts/index-codebase.py
   ```
4. **Check what's stale** (before a session):
   ```bash
   python3 scripts/index-codebase.py --check
   ```

## Hooks Reference

| Event | Trigger | Script | Effect |
|-------|---------|--------|--------|
| PreToolUse | `Bash` (`git commit`) | `lint-before-commit.sh` | Advisory ruff + eslint report |
| PostToolUse | `mcp__github__create_branch` | `jira-transition.sh in_progress` | Jira → In Progress |
| PostToolUse | `mcp__github__create_branch` | `jira-link-branch.sh` | Posts comment + remote link on Jira issue |
| PostToolUse | `mcp__github__create_pull_request` | `jira-transition.sh in_review` | Jira → In Review |
| PostToolUse | `mcp__github__create_pull_request` | `post-pr-coverage.sh` | Posts coverage report as PR comment |
| PostToolUse | `mcp__github__pull_request_read` | `fetch-pr-comments.sh` | Injects all PR comments into context |
| PostToolUse | `mcp__github__merge_pull_request` | `jira-transition.sh done` | Jira → Done |
| Stop | session end | `session-summary.sh` | Appends diff summary to `.claude/session-summaries.log` |
| Notification | any | `notify.sh` | Desktop notify + `.claude/notifications.log` |

## Linting

**Python:** `ruff check .`
**TypeScript/JS:** `npx eslint .` (uses `eslint.config.mjs`)

The lint hook is advisory — it reports errors as context but never blocks commits.

## Coverage

Runs automatically after PR creation and posts a markdown table to the PR comment thread.
Adjust the threshold in `.claude/hooks/post-pr-coverage.sh` (`COVERAGE_THRESHOLD`).

## Jira Transition Troubleshooting

If auto-transitions don't fire, verify transition names match your board's workflow:

```bash
curl -s -u "$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN" \
  "$ATLASSIAN_URL/rest/api/3/issue/PROJECT-1/transitions" | python3 -m json.tool
```

Adjust the `PATTERN` strings in `.claude/hooks/jira-transition.sh`.

## Environment Variables

| Variable | Value |
|----------|-------|
| `ATLASSIAN_URL` | `https://ddiggs.atlassian.net` |
| `ATLASSIAN_EMAIL` | `claude.danielsdiggs@gmail.com` |
| `ATLASSIAN_API_TOKEN` | set in devcontainer |
| `GITHUB_TOKEN` | set in devcontainer |
