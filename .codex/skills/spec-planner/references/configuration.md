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

## Generated artifact storage

The planner creates a persistent review package before any Linear write. Each
run contains:

- `dag-preview.md`;
- `preview-graph.md`;
- `dag-plan.json`;
- one standalone task document per node under `specs/`.

Choose the location once when installing the skill or initializing the project.
Normal planning runs then use that configured rule automatically. Never put
credentials in these files.

### Central mode (default)

The default layout is:

```text
~/.local/state/asyncself/specs/<instance>/<project>/<timestamp>-<requirement>/
```

Configure its namespaces with:

- `ASYNCSELF_SPEC_INSTANCE`, or `--instance` for one command;
- `ASYNCSELF_SPEC_PROJECT`, or `--project` for one command.

The project namespace is inferred from `SCM Project`, then `Project Slug`, then
`Local Source Repo` when it is not explicitly configured. The instance
namespace defaults to `default`. Set `ASYNCSELF_SPEC_STORE_ROOT`, or
`--store-root`, to move the whole central store while preserving the namespace
layout.

Central mode is the recommended choice when one Codex installation manages
several AsyncSelf instances or projects.

### Project-adjacent mode

Set `ASYNCSELF_SPEC_OUTPUT_MODE=adjacent`, or pass `--output-mode adjacent`, to
store each run beside `Local Source Repo`:

```text
/path/to/<project>.asyncself-specs/<timestamp>-<requirement>/
```

This is a sibling directory, not a directory inside the business repository.
Pass `--store-root /exact/project/spec-store` to choose another project store
in adjacent mode.

### Override precedence

For `preview`, placement is resolved in this order:

1. `--out` selects the exact directory for this one run;
2. legacy `ASYNCSELF_SPEC_OUTPUT_ROOT` selects an exact project output root and
   receives the generated run directory beneath it;
3. CLI placement flags;
4. `ASYNCSELF_SPEC_*` placement variables;
5. the central default above.

`ASYNCSELF_HOME` only tells a user-installed skill where the AsyncSelf checkout
and bundled pipeline live. It does not select the artifact location.
