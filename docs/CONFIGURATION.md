# Configuration reference

AsyncSelf loads configuration in this order:

1. explicit `--profile`;
2. `ASYNCSELF_PROFILE` (or legacy `SYMPHONY_PROFILE`);
3. ignored `local-config/active-profile`;
4. the compatibility default, `gitlab`.

The selected `local-config/profiles/<profile>.env` is loaded, followed by the external shared secret
file. Non-secret profile settings are then reapplied so a secret file cannot silently change the
project boundary. If both `ASYNCSELF_*` and matching `SYMPHONY_*` variables are present with
different values, startup fails.

## Profile and workflow are separate

The profile describes one machine and provider: paths, repository, Linear identifiers, target
branch, component runtime, and the path in `ASYNCSELF_WORKFLOW`. The workflow describes what the
worker may do and contains the tracker slug, dispatch label, workspace hooks, Codex command,
Dashboard switches, and task instructions.

Copy the selected public workflow template outside the Git checkout and point the copied profile at
it. The example profiles use:

- `$HOME/.config/asyncself/workflows/github.md`
- `$HOME/.config/asyncself/workflows/gitlab.md`

Do not edit a committed workflow into a machine-specific file. Keep the profile and workflow Linear
project, required label, repository provider, and target branch consistent. Startup validation
rejects known mismatches, but it cannot infer the intent behind every free-form prompt instruction.

## Required project settings

| Setting | Purpose |
|---|---|
| `ASYNCSELF_LINEAR_PROJECT_SLUG` | Linear long project slug or accepted project identifier. |
| `ASYNCSELF_LINEAR_PROJECT_SLUG_ID` | Short slug ID; must agree with the long slug. |
| `ASYNCSELF_LINEAR_PROJECT_ID` | Linear project UUID; required by the GitHub dashboard profile. |
| `ASYNCSELF_GATEKEEPER_ACTIVE_LABEL` | Label that permits dispatch. |
| `ASYNCSELF_SOURCE_REPO` | Stable source clone used to create workspaces. |
| `ASYNCSELF_WORKSPACE_ROOT` | Parent directory for isolated issue workspaces. |
| `ASYNCSELF_REPOSITORY_URL` | HTTPS clone URL for the selected provider. |
| `ASYNCSELF_TARGET_BRANCH` | Explicit review/integration branch; `main` is rejected. |

GitHub additionally requires `ASYNCSELF_GITHUB_REPOSITORY=owner/repository` and `gh`. GitLab
requires `ASYNCSELF_GITLAB_HOST=https://gitlab.example.com` and
`ASYNCSELF_GITLAB_PROJECT=group/repository`. The host is configurable but must be an HTTPS origin,
and the repository URL must use it.

## Secrets

`ASYNCSELF_SHARED_ENV_FILE` should point to `$HOME/.config/asyncself/secrets.env`. Depending on the
profile and enabled components, it contains `LINEAR_API_KEY`, `GH_TOKEN`/`GITHUB_TOKEN`,
`GITLAB_TOKEN`, and webhook secrets. Use least-privilege, revocable credentials and mode `600`.

Never store tokens in a committed profile, workflow prompt, generated spec, webhook JSON, shell
history, screenshot, or issue description.

## Runtime and optional settings

Runtime state defaults to `local-config/runtime/<profile>` and is ignored. Each profile receives
separate locks, observations, queues, and webhook state. Useful optional settings include:

- `ASYNCSELF_PORT`
- `ASYNCSELF_RUNTIME_DIR`
- `ASYNCSELF_GITHUB_REQUIRED_CHECK`
- `ASYNCSELF_GATEKEEPER_POLL_SECONDS`
- `ASYNCSELF_MR_WATCHER_POLL_SECONDS`
- `ASYNCSELF_WEBHOOK_CONFIG`

The example profiles are the canonical list. Legacy `SYMPHONY_*` names remain accepted only for
existing installations and internal compatibility.

## Dashboard switches

Dashboard availability, read-only aggregation, and Linear writes are independent controls:

| Setting | Effect |
|---|---|
| `observability.dashboard_enabled` | Serves the Dashboard and active-worker view. |
| `observability.dashboard_aggregation_enabled` | Reads the configured Linear project and provider details for Project Issues. Defaults to `false` in the schema. |
| `observability.dashboard_aggregation_refresh_ms` | Project-wide read interval; minimum 10 seconds, example 60 seconds. |
| `dashboard.linear_actions_enabled` | Allows supported Dashboard actions to write Linear state. Defaults to `false`. |

`dashboard_enabled: true` alone does not load Project Issues. Manual refresh also respects the
aggregation switch. Keep Linear writes disabled until `--check` validates the exact GitHub project,
repository, target branch, and UUID; then enable them only if Dashboard `Merging` is desired.

## Codex worker selection

The `codex.command` in the external workflow is the effective worker command. Explicit values such
as `--config 'model="..."'` and `--config model_reasoning_effort=low` override matching settings in
the WSL/Linux user's `~/.codex/config.toml`. The worker uses the Codex CLI authentication of the
account running the launcher, not a Codex desktop session on the Windows host.

`--approve-for-me` may create separate automatic approval-review model calls in addition to the
main coding session. Token displays are cumulative across the agent's model/tool loop and include
cached input; treat account quota observations as environment-specific measurements, not fixed
per-issue costs.

## Spec-planner artifact storage

`spec-planner` creates local files before it writes any Linear issues: a DAG summary, Mermaid graph,
machine-readable plan, and one standalone spec per task. Storage is separate from the AsyncSelf
runtime profile because one Codex installation can plan for several AsyncSelf instances and business
projects. Set the storage rule once during installation or project initialization; normal planning
runs reuse it automatically.

Central storage is the default:

```text
~/.local/state/asyncself/specs/<instance>/<project>/<timestamp>-<requirement>/
```

Use `ASYNCSELF_SPEC_INSTANCE` and `ASYNCSELF_SPEC_PROJECT` to prevent output from different targets
from being mixed. `ASYNCSELF_SPEC_STORE_ROOT` moves the entire central store. Alternatively,
`ASYNCSELF_SPEC_OUTPUT_MODE=adjacent` creates a sibling `<project>.asyncself-specs/` directory beside
the `Local Source Repo`. Neither default writes generated artifacts into the AsyncSelf checkout or
the business Git repository.

The preview command also accepts `--instance`, `--project`, `--store-root`, and `--output-mode`.
`--out` selects the exact directory for one run. The legacy `ASYNCSELF_SPEC_OUTPUT_ROOT` remains an
exact project-output-root override. The command prints the resolved `artifacts:` path; keep that path
with the reviewed plan because `apply` consumes its `dag-plan.json`.
