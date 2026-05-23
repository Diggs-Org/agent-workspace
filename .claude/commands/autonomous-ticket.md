# Autonomous Ticket Worker

Handles an assigned Jira ticket end-to-end using state detected from Jira and GitHub.
Read `project.config` at the repo root first to get project-specific values.

## State Detection

Before doing anything, determine the current phase by checking existing state:

```
1. source project.config
2. Search GitHub for open PRs whose head branch contains the Jira key
3. Check the Jira ticket status
```

Then execute the matching phase below.

---

## Phase 1: New Ticket — Create Plan

**When:** No branch exists for this ticket yet.

1. Fetch the ticket via `jira_get_issue` with fields:
   `assignee,issuetype,updated,summary,reporter,description,created,labels,priority,status,customfield_10072`
   Read the summary, description, and acceptance criteria (`customfield_10072`).

2. **Explore the codebase** to understand relevant areas. Use 2–3 parallel Explore sub-agents to investigate different subsystems in parallel (this is the highest-value use of sub-agents in this workflow):
   - One agent: find existing code related to the ticket's domain
   - One agent: identify test patterns and how existing tests are structured
   - One agent: check for related utilities, schemas, or config that would be touched

3. **Create `PLAN.md`** with the following structure:
   ```markdown
   # Plan: [TICKET-KEY]: [Summary]

   ## What & Why
   [One paragraph: what needs to change and why, in terms of the acceptance criteria]

   ## Approach
   [Numbered steps describing the implementation. Be specific: file paths, function names,
   schema changes, API changes. Include sub-agent strategy if the implementation is large.]

   ## Files to Change
   - `path/to/file.py` — what changes and why
   - (list all files that will be touched)

   ## Acceptance Criteria Checklist
   - [ ] [Each criterion from customfield_10072, reworded as a verifiable statement]

   ## Out of Scope
   [Anything explicitly NOT being done in this ticket]
   ```

4. Create the implementation branch via `mcp__github__create_branch`:
   - Branch name: `TICKET-KEY/short-description` (Jira key MUST be the prefix)
   - The PostToolUse hook will automatically transition Jira → In Progress and post a comment

5. Commit `PLAN.md` to the branch and push.

6. Open a **draft PR** via `mcp__github__create_pull_request`:
   - Title: `[PLAN] TICKET-KEY: Summary`
   - Body: use `.github/pull_request_template.md` with a note at the top: "**This is a planning draft. Review PLAN.md and leave an Approving review to begin implementation.**"
   - Set `draft: true`
   - Note: the `in_review` Jira hook fires on PR creation — for draft PRs this is slightly premature,
     but keeps Jira status visible. Implementation won't start until the plan is approved.

7. Post a Jira comment summarizing the plan and linking to the draft PR.

8. Tell the user: "Plan is ready for review: [PR URL]. Approve the draft PR on GitHub to begin implementation."

---

## Phase 2: Plan Approved — Implement

**When:** A draft PR exists AND it has an approving review with no changes-requested reviews after the approval.

How to detect: use `mcp__github__pull_request_read` on the draft PR, then check the reviews list.

1. Check out the plan branch (it already exists).

2. Re-read `PLAN.md` and the acceptance criteria from Jira.

3. **Implement** the changes described in PLAN.md, following the jira-workflow.md workflow steps 5–7:
   - Commit as you go with descriptive commit messages
   - After each logical chunk, verify with `git status` and `git diff --cached`
   - Do NOT remove `PLAN.md` — it stays as implementation context

4. Before creating the PR, verify all acceptance criteria are met (jira-workflow.md step 7).

5. **Convert the draft PR to non-draft** by creating a new non-draft PR on the same branch
   (or use `gh pr ready <number>` if available):
   ```bash
   gh pr ready <pr-number>
   ```
   The PostToolUse `create_pull_request` hook transitions Jira → In Review and posts coverage.
   If using `gh pr ready` instead, manually transition: the hook only fires on `mcp__github__create_pull_request`.

6. Tell the user: "Implementation complete. PR is ready for code review: [PR URL]."

---

## Phase 3: Review Requested — Address Comments

**When:** A non-draft PR exists AND its latest review state is `CHANGES_REQUESTED`.

1. Read the PR via `mcp__github__pull_request_read` — the PostToolUse hook will inject all
   review comments, inline comments, and PR-level comments into context automatically.

2. For each review comment:
   - Understand what is being asked
   - Implement the change
   - If a comment is unclear, make your best interpretation and note it in a reply comment

3. Push all changes to the branch.

4. Re-request review from `${GITHUB_REVIEWER}`:
   ```bash
   gh pr edit <number> --add-reviewer ${GITHUB_REVIEWER}
   ```

5. Tell the user: "All review comments addressed. Re-requested review from @${GITHUB_REVIEWER}."

---

## Phase 4: PR Approved — Merge

**When:** A non-draft PR exists AND its latest review state is `APPROVED` with no unresolved
`CHANGES_REQUESTED` reviews after the approval.

1. Squash merge via `mcp__github__merge_pull_request`:
   - Merge method: `squash`
   - Commit message: PR title and body (from the pull request template)
   - The PostToolUse hook transitions Jira → Done automatically

2. Tell the user: "PR merged. Jira ticket closed. Work complete."

---

## Phase: Awaiting Plan Review

**When:** A draft PR exists AND no approving review yet.

Do not start implementing. Simply report the current state:
"Waiting for plan approval on [PR URL]. Leave an Approving review on GitHub to begin implementation."

---

## Phase: Awaiting Code Review

**When:** A non-draft PR exists AND no reviews yet (or latest review is `COMMENTED` only).

Report the current state:
"PR is open and awaiting code review: [PR URL]. @${GITHUB_REVIEWER} has been requested."

---

## Important Notes

- **Branch naming is critical**: all hooks extract the Jira key using `[A-Z]+-[0-9]+` regex.
  The branch MUST start with the Jira key (e.g. `PROJ-123/short-description`).
- **Never force-push** to a branch with an open PR.
- **Sub-agents**: use 2–3 parallel Explore sub-agents during Phase 1 codebase exploration only.
  Implementation (Phase 2) and review response (Phase 3) should be single linear sessions.
- **Same-session review wait**: if the user is online and will review the plan quickly,
  you may poll GitHub using `mcp__github__pull_request_read` every few minutes rather than
  ending the session. Check for an approving review before proceeding to Phase 2.
