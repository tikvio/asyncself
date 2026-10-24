# Workflow and Gatekeeper

AsyncSelf separates decisions from queue maintenance. Humans define and approve work; deterministic
rules decide which already-approved task is ready to run.

## From specification to tasks

The spec planner first produces `dag-preview.md`, `preview-graph.md`, `dag-plan.json`, and one spec
per node. Previewing and dry-running do not create Linear issues. Live creation requires an explicit
approval followed by `apply --execute`.

Each created issue contains acceptance criteria, delivery instructions, and a Start Gate. Two gate
types matter:

- `dep:` represents another task. Gatekeeper checks it only when the referenced issue reaches
  `Done`.
- `human:` represents a decision or supplied information. A human checks it in the issue
  description. Comments are useful context but do not count as authorization.

An issue with unresolved human gates starts or remains in `Needs Info`. An issue with unresolved
dependencies starts or remains in `Waiting`. A fully satisfied task receives the configured active
label and moves to `Todo`.

To answer a `Needs Info` issue, record the decision in a comment when an audit trail is useful, then
edit or click the matching checkbox in the issue description so it becomes `- [x] human: ...`.
Gatekeeper reads the structured Start Gate, not free-form comments. With dependencies still open,
the issue moves to `Waiting`; with every dependency complete, it can move to `Todo`.

## Coding loop

1. The core polls the configured Linear project for eligible issues.
2. It creates one isolated workspace per claimed issue and launches a Codex app-server worker.
3. Several ready issues can run concurrently, bounded by workflow configuration.
4. The worker implements and validates its scoped task, pushes a branch, and opens a PR/MR.
5. The worker moves the issue to `In Review` and stops before merge authorization.
6. A reviewer either sends it to `Rework`, merges manually, or moves it to `Merging`.

The transition from `In Review` to `Merging` is never inferred from mergeability or passing checks.
It is the human authorization boundary.

## GitHub merge paths

- **AsyncSelf dashboard:** select `Merging`. The deterministic merger confirms the expected
  repository and non-`main` base, checks the PR head and required check, then squash-merges.
- **GitHub:** merge the PR in GitHub. Linear's native integration reconciles the issue state.
- **Linear Diffs:** approve and merge there; the native GitHub integration reconciles `Done`.

These three entry points reduce to two underlying writes:

1. the Dashboard changes the Linear issue to `Merging`, which authorizes Gatekeeper to call GitHub;
2. GitHub or Linear Diffs directly merges the GitHub pull request, after which Linear reconciles it.

Choose one path for a pull request. Do not click Dashboard `Merging` and then manually merge the
same PR merely to make the queue move; `Merging` is an authorization signal, not a progress button.

The dashboard may show `Waiting Gatekeeper` while a requested merge is being processed. This does
not mean it merged. `PR merged` appears only after GitHub returns the real merged state.

## GitLab merge paths

The GitLab profile works with a configured compatible HTTPS GitLab host. The MR watcher reconciles
manual merges and processes the Linear `Merging` path. The core scheduling and Gatekeeper dependency
rules remain available, but the dashboard has fewer MR inspection and control features than the
GitHub profile.

## Closing the DAG

When an issue reaches `Done`, Gatekeeper finds successors, checks their matching `dep:` entries,
and reevaluates them. A successor stays `Waiting` while any dependency remains. When all dependency
and human gates are satisfied, Gatekeeper adds the active label before moving it to `Todo`. That
ordering prevents an issue from becoming dispatchable with an incomplete routing boundary.

Failures are retried by the supervised auxiliary process, and profile-scoped state prevents one
profile from consuming another profile's locks or observations. Inspect unexpected transitions
before deleting runtime state or restarting repeatedly.
