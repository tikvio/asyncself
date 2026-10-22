# Project configuration

Collect configuration from the current project, its public examples, or the
user. Do not assume the values from any previous project.

Required planning inputs:

- `Project Slug`: the Linear project identifier accepted by AsyncSelf.
- `Linear Labels`: the product label and, when used, an agent profile label.
- `Workflow`: the coding-agent workflow file.
- `Local Source Repo`: the repository agents use as their source checkout.
- `Workspace`: the parent directory for isolated agent workspaces.
- `SCM Provider`: `github` or `gitlab`.
- `SCM Project`: `your-org/your-repo` or `your-group/your-repo`.
- `Target Branch`: the final destination branch.
- `Branch Strategy`: `independent-branches` or `integration-branch`.
- `Forbidden Paths`: secrets, runtime data, unrelated repositories, and any
  other locations agents must not touch.

For public documentation and committed examples, use placeholders such as
`your-org/example-app`, `/path/to/source`, and `example-project`. Never commit a
real token, webhook secret, private `.env`, or runtime payload.

The planner writes generated artifacts to `ASYNCSELF_SPEC_OUTPUT_ROOT`. Its
default is `~/.local/state/asyncself/specs`, outside the checkout.
