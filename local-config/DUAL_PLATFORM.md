# AsyncSelf GitLab/GitHub dual-platform setup

The program supports two independent profiles. Selecting one does not delete
or rewrite the other platform's workflow or configuration.

## First-time setup on another computer

1. Copy `profiles/gitlab.env.example` to `profiles/gitlab.env` and/or copy
   `profiles/github.env.example` to `profiles/github.env`.
2. Create `$HOME/.config/asyncself/workflows/`. From the repository root, copy
   `elixir/WORKFLOW.md` to `gitlab.md` and/or `elixir/WORKFLOW.github.md` to
   `github.md`, then replace every example project, label, branch, and Codex
   model value.
3. Copy `secrets.env.example` to `$HOME/.config/asyncself/secrets.env`, set its
   permissions to `600`, and point `ASYNCSELF_SHARED_ENV_FILE` to it.
4. Adjust local source/workspace paths in the copied profile. Keep its Linear
   project, label, provider repository, and target branch consistent with the
   external workflow. No source-code edit is required.
5. For GitHub, install `gh`, authenticate it non-interactively with
   `GH_TOKEN`/`GITHUB_TOKEN`, and verify access to the configured repository.
6. Run a read-only check before starting:

```bash
./start_asyncself.sh --profile gitlab --check
./start_asyncself.sh --profile github --check
```

## Select the local default

Write exactly `gitlab` or `github` to the ignored file
`local-config/active-profile`. Explicit `--profile` still overrides that
default. Each computer may choose either profile independently.

```bash
printf '%s\n' github > local-config/active-profile
./start_asyncself.sh
```

Selection precedence is `--profile`, `ASYNCSELF_PROFILE`, `active-profile`,
then the legacy GitLab default. Matching `SYMPHONY_*` settings remain supported;
conflicting old and new values fail safely.

## Component matrix

| Profile | AsyncSelf core | Gatekeeper | GitLab MR watcher | Local receiver |
|---|---:|---:|---:|---|
| GitLab | yes | yes | yes | optional Linear + GitLab |
| GitHub | yes | yes | no | optional Linear only |

GitHub PR recognition and ordinary issue-state transitions are handled by
Linear's native GitHub integration. There is no separate GitHub PR watcher.
Gatekeeper remains on both platforms because it owns dependency, `Waiting`,
and `Needs Info` logic; in the GitHub profile it also performs the deterministic
merge authorized by a human-owned `In Review -> Merging` transition. Runtime
state and locks are profile-scoped.

`--aux-only` starts only the selected profile's auxiliary stack. In GitHub
mode that means Gatekeeper plus the optional Linear-only receiver; it never
starts the GitLab MR watcher.

## Merge behavior

All three GitHub paths remain valid:

- a human moves the Linear issue from `In Review` to `Merging`, then the
  deterministic Gatekeeper handler validates and squash-merges it without a
  Codex worker;
- a human merges through GitHub after the same branch rules pass, then Linear
  moves the issue to `Done` directly;
- a human merges through Linear Diffs, then the native integration reconciles
  `Done`.

Mergeability alone never moves an issue out of `In Review`.

Configure an explicit non-`main` target branch in each local profile. Neither
workflow may silently fall back to `main`.

The GitLab profile accepts a compatible HTTPS GitLab host through
`ASYNCSELF_GITLAB_HOST`; it is not tied to GitLab.com or a particular regional
deployment. GitLab has fewer dashboard MR details and actions than GitHub.

## Rollback

Stop the current instance, set `active-profile` to `gitlab`, run the GitLab
`--check`, then start again. This does not delete either Linear project,
repository, profile, or runtime history.
