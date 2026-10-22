---
tracker:
  kind: linear
  provider:
    project_slug: "example-linear-project-1234abcd5678"
    api_key: $LINEAR_API_KEY
  required_labels:
    - example-project
  active_states:
    - Todo
    - In Progress
    - Rework
  terminal_states:
    - Canceled
    - Duplicate
    - Done
dashboard:
  # Dashboard writes are opt-in; this does not affect read-only aggregation.
  linear_actions_enabled: false
polling:
  interval_ms: 5000
workspace:
  root: $ASYNCSELF_WORKSPACE_ROOT
hooks:
  after_create: |
    test -n "${ASYNCSELF_SOURCE_REPO:-}" && test -n "${ASYNCSELF_REPOSITORY_URL:-}" && test -n "${ASYNCSELF_TARGET_BRANCH:-}"
    test "$ASYNCSELF_TARGET_BRANCH" != main
    git clone --no-hardlinks "$ASYNCSELF_SOURCE_REPO" .
    git remote set-url origin "$ASYNCSELF_REPOSITORY_URL"
    git fetch --prune origin "$ASYNCSELF_TARGET_BRANCH"
    git checkout -B "$ASYNCSELF_TARGET_BRANCH" "origin/$ASYNCSELF_TARGET_BRANCH"
    "$ASYNCSELF_ROOT/local-tools/prepare_workspace.sh"
  before_run: |
    "$ASYNCSELF_ROOT/local-tools/prepare_workspace.sh"
  timeout_ms: 300000
  before_remove: |
    true
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --approve-for-me --config 'model="gpt-5.6-sol"' --config model_reasoning_effort=low app-server
  approval_policy: on-request
  read_timeout_ms: 60000
observability:
  dashboard_enabled: true
  refresh_ms: 1000
server:
  host: 127.0.0.1
---

## GitHub profile template

Replace the example values below with the selected Linear project and GitHub repository.

- Linear project slug: `example-linear-project-1234abcd5678`.
- Required Linear label: `example-project`.
- Repository source: `$ASYNCSELF_SOURCE_REPO` from the selected local profile.
- GitHub remote: `https://github.com/example-org/example-repo.git`.
- Required base branch: `feature/asyncself/example-target`; never fall back to `main`.
- Use GitHub pull requests for code changes. If repo-local `commit`, `push`, `pull`, `land`, or `linear` skills are missing, use these fallbacks:
  - Pull: `git pull --ff-only origin "$ASYNCSELF_TARGET_BRANCH"`.
  - Branch: create a short issue branch such as `asyncself/{{ issue.identifier | downcase }}-short-title`.
  - Commit: make a focused commit with the issue identifier in the message.
  - Push: `git push -u origin <branch>`.
  - Pull request: use the GitHub CLI (`gh`) with the existing `GH_TOKEN` or `GITHUB_TOKEN`; never print the token. Create the PR from the issue branch to `feature/asyncself/example-target`, include the real issue identifier in the title and `Fixes {{ issue.identifier }}` in the body, link it in Linear, and move the issue to `In Review`.
- Use `In Review` as the review waiting state. If inherited text says `Human Review`, treat that as `In Review` for this sandbox.
- Human review and an explicit human merge decision are mandatory. Passing checks or becoming mergeable must never move an issue out of `In Review` automatically.
- Three merge entry points are supported after human review:
  1. A human merges the PR in GitHub while the issue remains `In Review`; the native Linear GitHub integration reconciles the issue to `Done`.
  2. A human merges the PR from Linear Diffs while the issue remains `In Review`; GitHub performs the merge and the native integration reconciles the issue to `Done`.
  3. A human moves the Linear issue from `In Review` to `Merging`; Gatekeeper's deterministic GitHub merge handler validates and merges the PR without launching a Codex worker.
- A formal GitHub approving review is not required for this single-account profile (`required approvals = 0`). The human decision is represented by a direct human merge or by the human-owned `In Review -> Merging` transition.
- `Needs Info` means waiting for a person to provide missing information and must not launch an agent.
- `Waiting` means waiting for dependency gates and must not launch an agent.
- `Merging` is not an active Symphony state and must never dispatch or retain a Codex worker.
- `Todo -> In Progress -> In Review -> Merging -> Done` is the Gatekeeper-merge path. Direct human merges use `Todo -> In Progress -> In Review -> Done` after native GitHub/Linear reconciliation.
- `Rework` means reviewer-requested changes and should continue on the existing branch when possible.
- Do not modify the other platform workflow during issue work.

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Follow-up context:

- This is follow-up attempt #{{ attempt }}. It may be a normal continuation or a retry after a failure.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the work item remains in an active state unless you are blocked by missing required access.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Do not ask a human to perform follow-up actions.
2. Only stop early for a true external blocker (missing required tools, auth, permissions, or secrets). If blocked, record it in the workpad and move the issue according to the workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Prerequisite: Linear MCP or `linear_graphql` tool is available

The agent should be able to talk to Linear, either via a configured Linear MCP server or injected `linear_graphql` tool. If neither is present, treat that as blocked access: record it in the workpad and move the issue according to the workflow instead of asking a user to configure Linear.

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep ticket metadata current (state, checklist, acceptance criteria, links).
- Treat a single persistent Linear comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate "done"/summary comments.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution,
  file a separate Linear issue instead of expanding scope. The follow-up issue
  must include a clear title, description, and acceptance criteria, be placed in
  `Backlog`, be assigned to the same project as the current issue, link the
  current issue as `related`, and use `blockedBy` when the follow-up depends on
  the current issue.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.

## Related skills

- `linear`: interact with Linear.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: keep the issue branch updated with `origin/$SYMPHONY_TARGET_BRANCH` before handoff; refuse `main`.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> queued; immediately transition to `In Progress` before active work.
  - Special case: if a PR is already attached, treat as feedback/rework loop (run full PR feedback sweep, address or explicitly push back, revalidate, return to `In Review`).
- `In Progress` -> implementation actively underway.
- `In Review` -> PR is attached and validated; complete the handoff and stop the current agent. Checks becoming green or the PR becoming mergeable are not authorization to advance the issue.
- `Merging` -> non-active state owned by Gatekeeper's deterministic GitHub merge handler; no Codex worker may process it.
- `Rework` -> reviewer requested changes; planning + implementation required.
- `Done` -> terminal state; no further action required.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to move it to `Todo`.
   - `Todo` -> immediately move to `In Progress`, then ensure bootstrap workpad comment exists (create if missing), then start execution flow.
     - If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `In Progress` -> continue execution flow from current scratchpad comment.
   - `In Review` -> finish the current handoff and return immediately; do not poll or keep the agent session alive.
   - `Merging` -> do nothing and shut down; Gatekeeper owns this state.
   - `Rework` -> run rework flow.
   - `Done` -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If the issue is `Merging` and its linked PR is already `MERGED`, verify the repository, target branch, and merge SHA, then move or confirm the issue as `Done`; never create a replacement branch or attempt a second merge.
   - Otherwise, if a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh issue branch from `origin/$SYMPHONY_TARGET_BRANCH` and restart execution flow as a new attempt.
5. For `Todo` tickets, do startup sequencing in this exact order:
   - `update_issue(..., state: "In Progress")`
   - find/create `## Codex Workpad` bootstrap comment
   - only then begin analysis/planning/implementation work.
6. Add a short comment if state and issue content are inconsistent, then proceed with the safest flow.

## Step 1: Start/continue execution (Todo or In Progress)

1.  Find or create a single persistent scratchpad comment for the issue:
    - Search existing comments for a marker header: `## Codex Workpad`.
    - Ignore resolved comments while searching; only active/unresolved comments are eligible to be reused as the live workpad.
    - If found, reuse that comment; do not create a new workpad comment.
    - If not found, create one workpad comment and use it for all updates.
    - Persist the workpad comment ID and only write progress updates to that ID.
2.  If arriving from `Todo`, do not delay on additional status transitions: the issue should already be `In Progress` before this step begins.
3.  Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
4.  Start work by writing/updating a hierarchical plan in the workpad comment.
5.  Ensure the workpad includes a compact environment stamp at the top as a code fence line:
    - Format: `<host>:<abs-workdir>@<short-sha>`
    - Example: `devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
    - Do not include metadata already inferable from Linear issue fields (`issue ID`, `status`, `branch`, `PR link`).
6.  Add explicit acceptance criteria and TODOs in checklist form in the same comment.
    - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
    - If changes touch app files or app behavior, add explicit app-specific flow checks to `Acceptance Criteria` in the workpad (for example: launch path, changed interaction path, and expected result path).
    - If the ticket description/comment context includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes (no optional downgrade).
7.  Run a principal-style self-review of the plan and refine it in the comment.
8.  Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section (command/output, screenshot, or deterministic UI behavior).
9.  Run the `pull` skill to sync with latest `origin/$SYMPHONY_TARGET_BRANCH` before any code edits, then create/use an issue-specific branch and record the result in the workpad `Notes`.
    - Include a `pull skill evidence` note with:
      - merge source(s),
      - result (`clean` or `conflicts resolved`),
      - resulting `HEAD` short SHA.
10. Compact context and proceed to execution.

## PR feedback sweep protocol (required)

When a ticket has an attached PR, run this protocol before moving to `In Review`:

1. Identify the PR number from issue links/attachments.
2. Gather feedback from all channels:
   - Top-level PR comments from GitHub. If the GitHub CLI is unavailable, use the GitHub REST API.
   - Inline PR discussions from GitHub.
   - Review summaries/states from GitHub.
3. Treat every actionable reviewer comment (human or bot), including inline review comments, as blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback reply is posted on that thread.
4. Update the workpad plan/checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until there are no outstanding actionable comments.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first (alternate remote/auth mode, then continue publish/review flow).
- Do not move to `In Review` for GitHub access/auth until all fallback strategies have been attempted and documented in the workpad.
- If a non-GitHub required tool is missing, or required non-GitHub auth is unavailable, move the ticket to `In Review` with a short blocker brief in the workpad that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Keep the brief concise and action-oriented; do not add extra top-level comments outside the workpad.

## Step 2: Execution phase (Todo -> In Progress -> In Review)

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is already recorded in the workpad before implementation continues.
2.  If current issue state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3.  Load the existing workpad comment and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
4.  Implement against the hierarchical TODOs and keep the comment current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
    - Never leave completed work unchecked in the plan.
    - For tickets that started as `Todo` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work.
5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before commit/push.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
    - If app-touching, run `launch-app` validation and capture/upload media via `github-pr-media` before handoff.
6.  Re-check all acceptance criteria and close any gaps.
7.  Before every `git push` attempt, run the required validation for your scope and confirm it passes; if it fails, address issues and rerun until green, then commit and push changes.
8.  Attach PR URL to the issue (prefer attachment; use the workpad comment only if attachment is unavailable).
    - Ensure the GitHub PR has label `symphony` (add it if missing).
9.  Merge latest `origin/$SYMPHONY_TARGET_BRANCH` into the issue branch, resolve conflicts, and rerun checks.
10. Update the workpad comment with final checklist status and validation notes.
    - Mark completed plan/acceptance/validation checklist items as checked.
    - Add final handoff notes (commit + validation summary) in the same workpad comment.
    - Do not include PR URL in the workpad comment; keep PR linkage on the issue via attachment/link fields.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary comment.
11. Before moving to `In Review`, poll PR feedback and checks:
    - Read the PR `Manual QA Plan` comment (when present) and use it to sharpen UI/runtime test coverage for the current change.
    - Run the full PR feedback sweep protocol.
    - Confirm PR checks are passing (green) after the latest changes.
    - Confirm every required ticket-provided validation/test-plan item is explicitly marked complete in the workpad.
    - Repeat this check-address-verify loop until no outstanding comments remain and checks are fully passing.
    - Re-open and refresh the workpad before state transition so `Plan`, `Acceptance Criteria`, and `Validation` exactly match completed work.
12. Only then move issue to `In Review`.
    - Exception: if blocked by missing required non-GitHub tools/auth per the blocked-access escape hatch, move to `In Review` with the blocker brief and explicit unblock actions.
13. For `Todo` tickets that already had a PR attached at kickoff:
    - Ensure all existing PR feedback was reviewed and resolved, including inline review comments (code changes or explicit, justified pushback response).
    - Ensure branch was pushed with any required updates.
    - Then move to `In Review`.

## Step 3: In Review and merge handling

1. After moving the issue to `In Review`, do not code, poll, or change ticket content; finish the current turn so Symphony can terminate the worker.
2. Remain in `In Review` even when all checks are green and GitHub reports the PR mergeable. Agents and automation must never move the issue to `Merging` merely because technical checks passed.
3. A later `Rework` transition launches a fresh worker to handle review feedback on the existing branch.
4. Wait for one explicit human decision outside the agent session:
   - The human merges in GitHub. Do not race the merge; let the native Linear GitHub integration reconcile the issue to `Done`.
   - The human merges from Linear Diffs. Do not race the merge; let GitHub perform it and the native integration reconcile the issue to `Done`.
   - The human moves the Linear issue from `In Review` to `Merging`, authorizing Gatekeeper's deterministic GitHub merge handler.
5. Agents must never execute merge work in `Merging`. Gatekeeper validates the unique linked PR, repository, target branch, required `build` check, mergeability, unresolved review threads, issue identifier, and head SHA before squash-merging.
6. After merge is confirmed, Gatekeeper reconciles the issue to `Done`; the native Linear GitHub integration may perform the same idempotent reconciliation.

## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching.
2. Re-read the full issue body and all human comments; explicitly identify what will be done differently this attempt.
3. Close the existing PR tied to the issue.
4. Remove the existing `## Codex Workpad` comment from the issue.
5. Create a fresh issue branch from `origin/$SYMPHONY_TARGET_BRANCH`.
6. Start over from the normal kickoff flow:
   - If current issue state is `Todo`, move it to `In Progress`; otherwise keep the current state.
   - Create a new bootstrap `## Codex Workpad` comment.
   - Build a fresh plan/checklist and execute end-to-end.

## Completion bar before In Review

- Step 1/2 checklist is fully complete and accurately reflected in the single workpad comment.
- Acceptance criteria and required ticket-provided validation items are complete.
- Validation/tests are green for the latest commit.
- PR feedback sweep is complete and no actionable comments remain.
- PR checks are green, branch is pushed, and PR is linked on the issue.
- Required PR metadata is present (`symphony` label).
- If app-touching, runtime validation/media requirements from `App runtime validation (required)` are complete.

## Guardrails

- If the branch PR is already closed/merged, do not reuse that branch or prior implementation state for continuation.
- For closed/merged branch PRs, create a new issue branch from `origin/$SYMPHONY_TARGET_BRANCH` and restart from reproduction/planning as if starting fresh.
- If issue state is `Backlog`, do not modify it; wait for human to move to `Todo`.
- Do not edit the issue body/description for planning or progress tracking.
- Use exactly one persistent workpad comment (`## Codex Workpad`) per issue.
- If comment editing is unavailable in-session, use the update script. Only report blocked if both MCP editing and script-based editing are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate Backlog issue rather
  than expanding current scope, and include a clear
  title/description/acceptance criteria, same-project assignment, a `related`
  link to the current issue, and `blockedBy` when the follow-up depends on the
  current issue.
- Do not move to `In Review` unless the `Completion bar before In Review` is satisfied.
- In `In Review`, do not make changes, do not merge, do not move the issue to `Merging`, and do not keep the agent alive; return immediately after handoff.
- Do not enable GitHub auto-merge, and do not let any agent compete with a direct human or Gatekeeper merge.
- If state is terminal (`Done`), do nothing and shut down.
- Keep issue text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing blocker, impact, and next unblock action.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
