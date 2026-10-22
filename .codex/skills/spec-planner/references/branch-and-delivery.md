# Branch and delivery model

## Independent branches

Use `Branch Strategy: independent-branches` when tasks can land separately.
Each PR or MR normally starts from the target branch and targets that same
branch. Express ordering through DAG dependencies when later work truly needs
an earlier merged result.

## Integration branch

Use `Branch Strategy: integration-branch` when several task branches must be
combined and reviewed as a unit. Set `Integration Branch`, make every PR/MR node
use it as `Base Branch`, and describe the final integration-to-target merge in
`Final Merge`.

## Provider contracts

For GitHub:

- `Delivery: pr`
- `Review: pull-request`
- `Merging Action: land-pr`

For GitLab:

- `Delivery: mr`
- `Review: merge-request`
- `Merging Action: land-mr`

The planner supplies these defaults from `SCM Provider`, but explicit values
are clearer for unusual plans.

Use `Delivery: branch-diff` or `Delivery: no-code` only with an explicit
`No Merge Reason`, `Mark Done Reason`, or exception note. Such nodes normally
use `Merging Action: mark-done`.

The generated branch template is
`feature/asyncself/{issue-key}-{task-slug}`. A task's review target resolves to
the integration branch, then its base branch, then the target branch.
