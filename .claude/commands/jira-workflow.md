# Jira Workflow

> **Note:** Project-specific values (email, reviewer, URLs) come from `project.config` at the
> repo root. Always `source project.config` before using the values below.
> For autonomous ticket handling, use `/autonomous-ticket` instead of this manual workflow.

## Environment Variables

| Variable              | Source                                            |
| --------------------- | ------------------------------------------------- |
| `ATLASSIAN_URL`       | `project.config` → also set in devcontainer env  |
| `ATLASSIAN_EMAIL`     | Local shell env (the email Claude uses for Jira)  |
| `ATLASSIAN_API_TOKEN` | Local shell env (Jira API token)                  |
| `GITHUB_TOKEN`        | Local shell env                                   |
| `JIRA_ASSIGNEE_EMAIL` | `project.config`                                  |
| `JIRA_PROJECT_KEY`    | `project.config`                                  |
| `GITHUB_REVIEWER`     | `project.config`                                  |

## Custom Fields

When calling `jira_get_issue`, always include `customfield_10072` in the `fields` parameter:

```
assignee,issuetype,updated,summary,reporter,description,created,labels,priority,status,customfield_10072
```

| Field name          | Field ID            |
| ------------------- | ------------------- |
| Acceptance Criteria | `customfield_10072` |

The default field list and `*all` mode both omit this field — it must be requested explicitly.

## Manual Workflow (for interactive sessions)

When asked to "work a ticket" manually:

1. **Get assigned tickets** — use the Atlassian MCP to list tickets assigned to `${JIRA_ASSIGNEE_EMAIL}`
2. **Pick the highest-priority unresolved ticket** — fetch it via `jira_get_issue` with `fields` including `customfield_10072` so you have the acceptance criteria from the start
3. **Create branch** via `mcp__github__create_branch` using the naming convention:
   `PROJECT-123/short-description` (Jira key _must_ be the branch prefix)
   - PostToolUse hooks auto-run: Jira → **In Progress**, comment + remote link posted to Jira issue
4. **Submit a plan** — commit `PLAN.md` to the branch and open a draft PR titled `[PLAN] TICKET-KEY: Summary`. Wait for an approving review before implementing. See the Autonomous Mode section below.
5. **Implement changes**, committing as you go
6. **Verify everything is committed and pushed** before creating the PR:
   ```bash
   git status          # must show "nothing to commit, working tree clean"
   git push origin <branch>
   git status          # must show "Your branch is up to date with 'origin/<branch>'"
   ```
   Do not proceed to step 7 if there are uncommitted changes or unpushed commits.
7. **Evaluate changes against acceptance criteria** — review the `customfield_10072` field fetched in step 2. For each criterion listed, verify it is satisfied by the committed changes. If any criterion is not met, implement the missing changes, commit, push, and re-verify from step 6. Only proceed to step 8 once every acceptance criterion is satisfied.
8. **Create PR** via `mcp__github__create_pull_request` using the structure from `.github/pull_request_template.md` as the PR body
   - PostToolUse hooks auto-run: Jira → **In Review**, coverage report posted as PR comment
9. **Read the PR** via `mcp__github__pull_request_read` when addressing review comments
   - PostToolUse hook auto-fetches all inline review comments and PR comments into context
   - Make the requested changes, push them to the branch, then re-request a review:
     ```bash
     git push origin <branch>
     gh pr edit <number> --add-reviewer ${GITHUB_REVIEWER}
     ```
10. After the user approves, **squash merge** via `mcp__github__merge_pull_request` using the PR title and body from the pull request template as the merge commit message
    - PostToolUse hook auto-transitions Jira → **Done**

> Branch naming is critical: hooks extract the Jira key using `[A-Z]+-[0-9]+`.
> The branch must start with the Jira key (e.g. `PROJECT-123/...`).

## Autonomous Mode

The `/autonomous-ticket` skill handles this workflow automatically, including state detection
(determining the current phase from Jira + GitHub state) and executing the right phase.

State machine:
- **No branch** → Phase 1: create PLAN.md + open draft PR
- **Draft PR, no approval** → waiting for plan review (report status, end session)
- **Draft PR, approved** → Phase 2: implement + convert to non-draft
- **Non-draft PR, changes requested** → Phase 3: address all review comments
- **Non-draft PR, approved** → Phase 4: squash merge

## Hooks Reference

| Event        | Trigger                            | Script                           | Effect                                                  |
| ------------ | ---------------------------------- | -------------------------------- | ------------------------------------------------------- |
| PreToolUse   | `Bash` (`git commit`)              | `lint-before-commit.sh`          | Advisory ruff + eslint report                           |
| PostToolUse  | `mcp__github__create_branch`       | `jira-transition.sh in_progress` | Jira → In Progress                                      |
| PostToolUse  | `mcp__github__create_branch`       | `jira-link-branch.sh`            | Posts comment + remote link on Jira issue               |
| PostToolUse  | `mcp__github__create_pull_request` | `jira-transition.sh in_review`   | Jira → In Review                                        |
| PostToolUse  | `mcp__github__create_pull_request` | `post-pr-coverage.sh`            | Posts coverage report as PR comment                     |
| PostToolUse  | `mcp__github__pull_request_read`   | `fetch-pr-comments.sh`           | Injects all PR comments into context                    |
| PostToolUse  | `mcp__github__merge_pull_request`  | `jira-transition.sh done`        | Jira → Done                                             |
| Stop         | session end                        | `session-summary.sh`             | Appends diff summary to `.claude/session-summaries.log` |
| Notification | any                                | `notify.sh`                      | Desktop notify + `.claude/notifications.log`            |

## Jira Development Panel (full integration)

For branches, commits, and PRs to appear in Jira's native Development panel, install the **GitHub for Jira** app:

> Jira Settings → Apps → Find new apps → search "GitHub for Jira"

Once connected, any branch/commit/PR referencing a Jira issue key is automatically linked — no extra hook work needed for that panel.

## Transition Troubleshooting

If auto-transitions don't fire, verify transition names match your board's workflow:

```bash
source project.config
curl -s -u "$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN" \
  "$ATLASSIAN_URL/rest/api/3/issue/${JIRA_PROJECT_KEY}-1/transitions" | python3 -m json.tool
```

Adjust the `PATTERN` strings in `.claude/hooks/jira-transition.sh`.
