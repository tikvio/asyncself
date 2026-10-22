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

## 4. Create a profile and external secrets file

```bash
cp local-config/profiles/github.env.example local-config/profiles/github.env
# Or:
# cp local-config/profiles/gitlab.env.example local-config/profiles/gitlab.env

mkdir -p "$HOME/.config/asyncself"
cp local-config/secrets.env.example "$HOME/.config/asyncself/secrets.env"
chmod 600 "$HOME/.config/asyncself/secrets.env"
```

Edit the copied profile. It is ignored by Git. Set the source clone, workspace root, repository URL,
target branch, Linear IDs, and required label. For GitLab, also set the HTTPS host origin and
`group/repository` path. Put tokens only in the external secrets file.

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

## 6. Validate and start

```bash
./start_asyncself.sh --profile github --check
./start_asyncself.sh --profile github
```

Use `gitlab` for that profile. `--check` is read-only with respect to provider state: it validates
files, identifiers, host/repository consistency, target-branch safety, tools, and required tokens.

The dashboard is served at `http://localhost:4000` unless `ASYNCSELF_PORT` changes it. Stop the
foreground launcher with `Ctrl-C`; it supervises and stops the child processes it started.

## 7. Create the first work graph

Ask Codex to use `.codex/skills/spec-planner` with your requirements. Review its graph, branches,
gates, and generated issue descriptions. Only after approval should it execute the Linear apply.
See [Workflow](WORKFLOW.md).
