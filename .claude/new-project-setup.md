# New Project Setup

Checklist for adapting this repo when starting a new project from this template.
**Start here:** run `scripts/setup-project.sh` — it handles most of the one-time configuration interactively.

---

## 1. Run Setup Script

```bash
bash scripts/setup-project.sh
```

This script:
- Fills in `project.config` (Jira project key, assignee email, GitHub reviewer, Atlassian URL)
- Replaces the `@GITHUB_REVIEWER_PLACEHOLDER` in `.github/CODEOWNERS` with your username
- Prints all the shell environment variables you need to set and where to get the tokens
- Prints a verification checklist

After running it, set the printed env vars in `~/.zshrc` or `~/.bashrc` and reopen your terminal.

---

## 2. Set Shell Environment Variables

Add to `~/.zshrc` (macOS) or `~/.bashrc` (Linux). These are injected into the devcontainer at startup via `containerEnv` in `devcontainer.json`.

| Variable               | Description                                                        |
| ---------------------- | ------------------------------------------------------------------ |
| `ATLASSIAN_EMAIL`      | Email Claude uses for Jira API calls (same as `JIRA_ASSIGNEE_EMAIL`) |
| `ATLASSIAN_URL`        | Your Atlassian instance URL                                        |
| `ATLASSIAN_API_TOKEN`  | API token for `ATLASSIAN_EMAIL` — from id.atlassian.com            |
| `ATLASSIAN_BASIC_AUTH` | `base64(ATLASSIAN_EMAIL:ATLASSIAN_API_TOKEN)` — see below          |
| `GITHUB_TOKEN`         | GitHub PAT with `repo`, `pull_requests`, `read:org` scopes         |
| `ANTHROPIC_API_KEY`    | Optional — needed if using Claude CLI locally outside VS Code       |

Generate `ATLASSIAN_BASIC_AUTH`:

```bash
echo -n "your-email@example.com:your-api-token" | base64
```

---

## 3. Create the Claude Jira User

Create a dedicated Jira account for Claude (e.g. `claude.yourname@gmail.com`):
1. Create the account via `https://id.atlassian.com`
2. Add it to your Jira project with **Edit** permissions
3. Generate an API token for that account at `https://id.atlassian.com/manage-profile/security/api-tokens`
4. Use that token for `ATLASSIAN_API_TOKEN`

Tickets assigned to this account will appear in Claude's inbox on devcontainer startup.

---

## 4. One-Time GitHub/Jira Integrations

**GitHub for Jira app** (required for Development panel in Jira tickets):
> Jira Settings → Apps → Find new apps → search "GitHub for Jira" → Connect your GitHub org

**GitHub Actions** (for `post-pr-coverage.sh` to post to PRs):
> GitHub → Settings → Actions → General → Allow all actions

---

## 5. Optional: Tooling Adjustments

The template assumes Python + TypeScript/JavaScript. If your project differs:

- **Linting**: `lint-before-commit.sh` runs `ruff` (Python) and `eslint` (JS/TS) when detected. Add or remove linters as needed.
- **Coverage**: `post-pr-coverage.sh` runs `pytest --cov` and `npm test --coverage` when test files are detected. Adjust for your test framework.
- **Codebase index**: `scripts/index-codebase.py` indexes `.py`, `.ts`, `.tsx`, `.js`, `.jsx`. Update `EXTENSIONS` in the script for other languages.
- **CLAUDE.md**: Add project-specific context — architecture overview, domain terminology, key invariants.
- **Jira custom fields**: If your board uses a custom Acceptance Criteria field with a different ID than `customfield_10072`, update `.claude/commands/jira-workflow.md`. Find the field ID with:
  ```bash
  source project.config
  curl -s -u "$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN" \
    "$ATLASSIAN_URL/rest/api/3/field" | python3 -m json.tool | grep -A2 "Acceptance"
  ```

---

## 6. Jira Workflow State Names

The transition hook (`jira-transition.sh`) uses fuzzy pattern matching. If your board uses
non-standard state names, verify transitions for a sample ticket:

```bash
source project.config
curl -s -u "$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN" \
  "$ATLASSIAN_URL/rest/api/3/issue/${JIRA_PROJECT_KEY}-1/transitions" | python3 -m json.tool
```

Adjust the `PATTERN` strings in `.claude/hooks/jira-transition.sh` to match your board's names.

---

## 7. Verification Checklist

After completing setup:

```bash
chmod +x scripts/*.sh .claude/hooks/*.sh
npm install
python3 scripts/index-codebase.py --full
```

Then confirm:

- [ ] No hardcoded paths remain: `grep -rn "agent-workspace" .claude/hooks/ .claude/settings.json` returns zero results
- [ ] `project.config` has real values (not placeholders)
- [ ] `.github/CODEOWNERS` has your GitHub username (not `GITHUB_REVIEWER_PLACEHOLDER`)
- [ ] Environment variables are set: `echo $ATLASSIAN_URL && echo $GITHUB_TOKEN`
- [ ] MCP servers connect: run `/session-start` — Jira and GitHub tools should appear
- [ ] Inbox check works: `bash scripts/check-inbox.sh` runs without errors
- [ ] Devcontainer startup works: reopen in VS Code, check terminal for `check-inbox:` output
- [ ] Assign a test Jira ticket to `${JIRA_ASSIGNEE_EMAIL}`, reopen devcontainer, run `/session-start` → Claude should pick up the ticket automatically
