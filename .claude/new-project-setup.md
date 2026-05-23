# New Project Setup

Checklist for adapting this repo when starting a new project from this template.

---

## 1. Hardcoded Workspace Paths

All hooks and `settings.json` hardcode the workspace path. Replace `/workspaces/agent-workspace` with `/workspaces/<your-project-name>` everywhere:

```bash
# Find all occurrences
grep -rn "workspaces/agent-workspace" .claude/

# Bulk replace (adjust the sed command for your project name)
find .claude -type f | xargs sed -i 's|/workspaces/agent-workspace|/workspaces/your-project-name|g'
```

Files that contain this path:

- `.claude/settings.json` — all `"command"` values (10 occurrences)
- `.claude/hooks/auto-reindex.sh` — `PROJECT_ROOT`
- `.claude/hooks/lint-before-commit.sh` — `PROJECT_ROOT`
- `.claude/hooks/session-summary.sh` — `PROJECT_ROOT`
- `.claude/hooks/notify.sh` — `PROJECT_ROOT`
- `.claude/hooks/post-pr-coverage.sh` — `PROJECT_ROOT`
- `.claude/hooks/jira-transition.sh` — `git -C` path
- `.claude/hooks/jira-link-branch.sh` — `git -C` paths (2 occurrences)

---

## 2. Jira Project Configuration

Update `.claude/commands/jira-workflow.md`:

| Item                               | Where                                  | What to change                                           |
| ---------------------------------- | -------------------------------------- | -------------------------------------------------------- |
| Jira project key                   | Step 3 example `PROJECT-123`           | Replace with your actual project key (e.g. `MYPROJ-123`) |
| Agent email                        | Step 1 `claude.danielsdiggs@gmail.com` | Email used by Claude for Jira API calls                  |
| Reviewer username                  | Step 9 `--add-reviewer DDiggs91`       | Your team's GitHub username                              |
| Atlassian URL                      | `## Environment Variables` table       | Your org's Atlassian URL                                 |
| Transition troubleshooting example | `PROJECT-1` in curl command            | Any real issue key from your project                     |

If your Jira board uses different workflow state names (e.g. `Backlog` instead of `To Do`), update the `PATTERN` strings in `.claude/hooks/jira-transition.sh`. Validate with:

```bash
curl -s -u "$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN" \
  "$ATLASSIAN_URL/rest/api/3/issue/<YOUR-ISSUE-KEY>/transitions" | python3 -m json.tool
```

If your project uses a custom Acceptance Criteria field with a different ID than `customfield_10072`, update `.claude/commands/jira-workflow.md` and the field list in steps 2 and 7. Find your field ID with:

```bash
# List all custom fields
curl -s -u "$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN" \
  "$ATLASSIAN_URL/rest/api/3/field" | python3 -m json.tool | grep -A2 "Acceptance"
```

---

## 3. Environment Variables

Set these in your devcontainer before the first session:

| Variable               | Description                                                     |
| ---------------------- | --------------------------------------------------------------- |
| `ATLASSIAN_URL`        | Your Atlassian instance (e.g. `https://your-org.atlassian.net`) |
| `ATLASSIAN_EMAIL`      | Email Claude uses for Jira API calls                            |
| `ATLASSIAN_API_TOKEN`  | Atlassian API token for that email                              |
| `ATLASSIAN_BASIC_AUTH` | `base64(email:api_token)` — used directly in hook `curl` calls  |
| `GITHUB_TOKEN`         | GitHub PAT with `repo` + `pull_requests` + `read:org` scopes    |

Generate `ATLASSIAN_BASIC_AUTH`:

```bash
echo -n "your-email@example.com:your-api-token" | base64
```

These are referenced in `.devcontainer/devcontainer.json` via `${localEnv:VARIABLE_NAME}` — set them in your local shell environment or `.env` file before opening the devcontainer.

---

## 4. GitHub & CODEOWNERS

In `.github/CODEOWNERS`, replace `@DDiggs91` with your team's GitHub username(s):

```
* @your-github-username
```

Update `.mcp.json` if your GitHub organization or MCP endpoint differs from the defaults.

---

## 5. Optional: Tooling Adjustments

The template assumes Python + TypeScript/JavaScript. If your project differs:

- **Linting**: `lint-before-commit.sh` runs `ruff` (Python) and `eslint` (JS/TS) when detected. Add or remove linters as needed.
- **Coverage**: `post-pr-coverage.sh` runs `pytest --cov` and `npm test --coverage` when test files are detected. Adjust for your test framework.
- **Codebase index**: `scripts/index-codebase.py` indexes `.py`, `.ts`, `.tsx`, `.js`, `.jsx`. Update `EXTENSIONS` in the script and the extension check in `auto-reindex.sh` for other languages.
- **CLAUDE.md**: Add project-specific context — architecture overview, domain terminology, key invariants.

---

## 6. Verification Checklist

After completing setup:

```bash
chmod +x .claude/hooks/*.sh
npm install
python3 scripts/index-codebase.py --full
```

Then confirm:

- [ ] `grep -rn "workspaces/agent-workspace" .claude/` returns zero results
- [ ] Environment variables are set (`echo $ATLASSIAN_URL`, `echo $GITHUB_TOKEN`)
- [ ] MCP servers connect (run `/session-start` — Jira and GitHub tools should appear)
- [ ] Create a test branch named `<YOUR-KEY>-1/setup-test` — Jira transition hook should fire
- [ ] Open a test PR — coverage hook and fetch-pr-comments hook should fire
