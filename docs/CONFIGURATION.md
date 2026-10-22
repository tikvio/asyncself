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
