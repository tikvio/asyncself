# Setup

This guide configures one AsyncSelf checkout for one Linear project and either GitHub or GitLab.
Run it in Linux, WSL2, or macOS. WSL2 is the recommended Windows environment.

## 1. Prepare the target repository

Create a normal source clone for the project that workers will modify and a separate empty parent
directory for generated workspaces. Use a dedicated, non-`main` target branch and push it to the
remote before starting AsyncSelf.

```bash
mkdir -p "$HOME/code/asyncself-sources" "$HOME/code/asyncself-workspaces"
git clone https://github.com/your-org/example-app.git \
  "$HOME/code/asyncself-sources/example-app"
cd "$HOME/code/asyncself-sources/example-app"
git switch -c feature/asyncself/review-target
git push -u origin feature/asyncself/review-target
```

Do not point the workspace root at the source clone, the AsyncSelf checkout, a secret directory, or
another business repository.

## 2. Configure Linear

Create or select a Linear project and configure these workflow states:

- `Todo`
- `In Progress`
- `In Review`
- `Rework`
- `Merging`
- `Done`
- `Waiting`
- `Needs Info`

Create one required label for tasks AsyncSelf is allowed to dispatch. Keep unrelated Linear issues
unlabelled. Copy the project's long slug, short slug ID, and UUID into the selected profile.

Connect Linear to GitHub or GitLab using the provider integration. For GitHub, allow Linear to link
pull requests and reconcile merged PRs. AsyncSelf still verifies merge state independently before
the dashboard calls a PR merged.

## 3. Install local dependencies

Install `git`, `bash`, `python3`, `flock`, `mise`, and Codex CLI. GitHub users also need `gh`.

```bash
cd asyncself/elixir
mise trust
mise install
mise exec -- mix setup
cd ..
```

Authenticate Codex on the host. Authenticate `gh` or prepare a GitLab token with only the project
permissions the selected workflow needs.

## 4. Create a profile, external workflow, and secrets file

```bash
cp local-config/profiles/github.env.example local-config/profiles/github.env
mkdir -p "$HOME/.config/asyncself/workflows"
cp elixir/WORKFLOW.github.md "$HOME/.config/asyncself/workflows/github.md"
cp local-config/secrets.env.example "$HOME/.config/asyncself/secrets.env"
chmod 600 "$HOME/.config/asyncself/secrets.env" \
  "$HOME/.config/asyncself/workflows/github.md"
```

For GitLab, copy `gitlab.env.example` and `elixir/WORKFLOW.md` instead, saving the latter as
`$HOME/.config/asyncself/workflows/gitlab.md`.

The ignored profile selects the machine paths and provider boundary. The external workflow is the
actual Linear and agent contract. Edit both:

- profile: source clone, workspace root, repository URL, target branch, Linear long slug, short
  slug ID, UUID where required, and dispatch label;
- workflow front matter: the same Linear project slug and required label;
- workflow prompt: every `example-*` project, label, and target-branch value;
- Codex command: the model and reasoning effort you intend the worker account to use.

The profile and workflow project slug, required label, and non-`main` target branch must agree.
Check for forgotten placeholders without printing credentials:

```bash
grep -nE 'example-|your-' "$HOME/.config/asyncself/workflows/github.md"
```

Put tokens only in the external secrets file. The command-line `--config` values in the workflow's
`codex.command` override matching defaults in `~/.codex/config.toml` for AsyncSelf workers.

The templates enable read-only project aggregation so Project Issues can load. The GitHub workflow
keeps Dashboard writes off by default:

```yaml
dashboard:
  linear_actions_enabled: false
observability:
  dashboard_enabled: true
  refresh_ms: 1000
  dashboard_aggregation_enabled: true
  dashboard_aggregation_refresh_ms: 60000
```

After `--check` succeeds, change `linear_actions_enabled` to `true` only if the Dashboard should be
allowed to move a GitHub-profile issue from `In Review` to `Merging`. This is separate from
read-only aggregation; clicking **Refresh project data** cannot override a disabled aggregation
switch.

If webhook shadow/hybrid mode is required, copy the corresponding `*.webhook.json.example` to the
same name without `.example`. Polling is the simpler baseline and does not require exposing a local
HTTP receiver.

## 5. Install repository skills in the target project

The coding workflow may use the repository skills under `.codex/skills`. Copy only the skills your
target project needs and review them as code before use. The `spec-planner` skill is normally used
from the AsyncSelf checkout because its wrapper locates the deterministic planner in
`local-tools/dependency_pipeline`.

When the skill is installed elsewhere, set `ASYNCSELF_HOME` to this checkout so the wrapper can
find that pipeline.

The planner produces a local review package before it creates any Linear issues. Configure its
storage once during installation or project initialization. For one Codex installation serving
several targets, set `ASYNCSELF_SPEC_INSTANCE` and `ASYNCSELF_SPEC_PROJECT`; output then defaults to
`~/.local/state/asyncself/specs/<instance>/<project>/...`. Set `ASYNCSELF_SPEC_STORE_ROOT` to move
that central archive, or use `ASYNCSELF_SPEC_OUTPUT_MODE=adjacent` to create a sibling
`<project>.asyncself-specs/` directory beside the business repository. See
[Configuration](CONFIGURATION.md#spec-planner-artifact-storage).

## 6. Validate and start

```bash
./start_asyncself.sh --profile github --check
./start_asyncself.sh --profile github
```

Use `gitlab` for that profile. `--check` is read-only with respect to provider state: it validates
files, identifiers, host/repository consistency, target-branch safety, tools, and required tokens.

The dashboard is served at `http://localhost:4000` unless `ASYNCSELF_PORT` changes it. Stop the
foreground launcher with `Ctrl-C`; it supervises and stops the child processes it started.

## 7. Optional: run as a systemd user service

First run the foreground launcher and complete `--check`. If that works, Linux and WSL2 users can
supervise it with a user service. Replace both `%h/code/asyncself` paths if the checkout is elsewhere:

```ini
# ~/.config/systemd/user/asyncself.service
[Unit]
Description=AsyncSelf GitHub profile
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/code/asyncself
Environment=HOME=%h
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=%h/code/asyncself/start_asyncself.sh --profile github
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now asyncself.service
systemctl --user status asyncself.service
journalctl --user -u asyncself.service -f
```

Use `gitlab` in `ExecStart` for that profile. On WSL2, enabling the user service does not itself
start the Linux distribution after a Windows reboot; WSL must start before its systemd user manager
can launch AsyncSelf.

## 8. Create the first work graph

Ask Codex to use `.codex/skills/spec-planner` with your requirements. Review its graph, branches,
gates, generated issue descriptions, and `dag-plan.json`. Only after approval should it execute the
Linear apply. See [Workflow](WORKFLOW.md).
