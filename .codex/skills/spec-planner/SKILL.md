---
name: spec-planner
description: Turn requirements, notes, or Markdown specs into a reviewed AsyncSelf task DAG and Linear issue creation plan. Use when the user wants to clarify architecture, split implementation work, model dependencies, preview Linear issues, or create those issues only after explicit approval.
---

# Spec Planner

Turn an unstructured request into an executable AsyncSelf plan without hiding
architecture, branch, or dependency decisions from the user.

## Operating rules

1. Treat the user's current repository and product context as authoritative.
   Never substitute example values for confirmed real project settings during a
   private planning session, and never place secrets in specs or output files.
2. Resolve material ambiguity before generating a final DAG. In particular,
   confirm the architecture boundary, target repository, Linear project,
   required labels, branch strategy, and PR/MR delivery model.
3. Keep tasks independently reviewable. Each node needs a concrete outcome,
   explicit dependencies, acceptance criteria, and a Start Gate.
4. Generate a preview first. Present the graph, task table, branch plan, labels,
   and initial Linear states for review.
5. Never run `apply --execute` without explicit user approval of the current
   preview. A request to plan, preview, revise, or dry-run is not approval to
   create Linear issues.
6. Match the user's language in discussion and task prose. The deterministic
   pipeline's structural headings remain English for portability.

## Workflow

### 1. Classify the input

Decide whether the request is ready to split or still needs product/design
clarification. If key behavior is underspecified, propose the smallest set of
decisions needed before task decomposition.

### 2. Load the relevant guidance

- Read [configuration](references/configuration.md) for project settings and
  path safety.
- Read [gates](references/gates.md) when defining Start Gates and initial
  states.
- Read [branch and delivery](references/branch-and-delivery.md) before choosing
  independent or integration branches and PR/MR behavior.
- Read [spec format](references/spec-format.md) before writing the input spec.
- Read [authentication](references/auth-and-env.md) before any live Linear
  operation.

### 3. Draft and validate

Write the source spec outside the repository unless the user asks to keep it in
the project. Then run:

```bash
python .codex/skills/spec-planner/scripts/asyncself-pipeline preview SPEC.md --out OUTPUT_DIR
```

When the skill is installed in a user skill directory, the wrapper locates the
AsyncSelf checkout through `ASYNCSELF_HOME`. Review `dag-preview.md`,
`preview-graph.md`, `dag-plan.json`, and every file under `specs/`.

### 4. Review with the user

Summarize the important decisions, not just filenames. Call out:

- the DAG and why each dependency exists;
- nodes starting in `Needs Info` or `Waiting`;
- target, base, integration, and review target branches;
- labels and delivery actions;
- any forbidden paths or deliberate no-merge nodes.

Revise the source spec and regenerate the preview until approved.

### 5. Apply only after approval

First perform a dry run:

```bash
python .codex/skills/spec-planner/scripts/asyncself-pipeline apply OUTPUT_DIR/dag-plan.json
```

After the user explicitly approves creation of the reviewed plan, run:

```bash
python .codex/skills/spec-planner/scripts/asyncself-pipeline apply OUTPUT_DIR/dag-plan.json --execute
```

Report the created Linear identifiers and any failure. Do not retry a partial
live apply blindly; inspect which nodes were created before taking further
action.
