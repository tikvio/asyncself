# Troubleshooting

## Start with the configuration check

```bash
./start_asyncself.sh --profile github --check
# or
./start_asyncself.sh --profile gitlab --check
```

It reports missing paths, mismatched Linear slugs, forbidden `main` targets, absent tools/tokens,
and provider/repository mismatches without starting the service.

## An issue never leaves Needs Info

Open the issue description and check every required `human:` Start Gate item. A comment does not
change a human gate. Then wait for the next Gatekeeper poll or inspect its logs.

## An issue never leaves Waiting

Verify every referenced dependency is actually `Done`, not merely merged or in `Merging`. Confirm
the `dep:` identifier in the description matches the predecessor and that Gatekeeper has the correct
project slug ID and active label.

## A ready issue is not claimed

Check that it is in `Todo`, has the required label, belongs to the configured project, and is not
already claimed. Also inspect concurrency limits and the core log under `elixir/log/`.

## Project Issues is empty and Refresh does nothing

`dashboard_enabled: true` is not enough. In the selected external workflow, enable project-wide
reads explicitly:

```yaml
observability:
  dashboard_enabled: true
  dashboard_aggregation_enabled: true
  dashboard_aggregation_refresh_ms: 60000
```

Restart AsyncSelf after changing the workflow. Manual refresh respects this opt-in switch and cannot
override `dashboard_aggregation_enabled: false`. If the list is still empty, inspect the Linear data
source status, project slug/UUID, token scope, and DashboardStore logs.

## The Dashboard has no Merging action

The write control is intentionally separate from read-only aggregation. It is available only for a
supported GitHub action scope when the issue is in `In Review` and the external workflow contains:

```yaml
dashboard:
  linear_actions_enabled: true
```

Run `--check` first. Enabling this permits the Dashboard to write the Linear `Merging` state; it
does not merge a PR inside the web request.

## Merging is stuck

For GitHub, inspect repository/base/head validation, required checks, the `gh` authentication scope,
and the real PR merged state. `Waiting Gatekeeper` is not proof of success. For GitLab, verify host,
project path, token scope, and MR watcher logs.

## Old and new variables conflict

Remove one side or make matching `ASYNCSELF_*` and `SYMPHONY_*` values identical. New installations
should keep only `ASYNCSELF_*`; legacy variables exist for compatibility.

## AsyncSelf uses a different Codex model than expected

Inspect the external workflow's `codex.command`. Its explicit `--config model=...` and
`model_reasoning_effort=...` values override the launcher user's `~/.codex/config.toml`. Under WSL,
the worker uses the WSL Codex CLI login, not the Windows Codex desktop account.

## systemd briefly reports exit status 143 during restart

The current launcher can report the old instance's normal SIGTERM as exit status 143 while
`systemctl --user restart` replaces it. Check the new instance instead of treating that one line as
the final result:

```bash
systemctl --user show asyncself.service \
  -p ActiveState -p SubState -p Result -p ExecMainStatus -p NRestarts
```

An active/running service with `Result=success` and `ExecMainStatus=0` is healthy. Persistent restart
loops, a nonzero current status, or a missing process require investigation.

## Do not repair by deleting state first

Runtime directories contain profile-scoped observations and locks. Stop the launcher, inspect the
failure, and back up relevant state before removing an exact file. Repeated restarts can hide the
event that caused a transition failure.
