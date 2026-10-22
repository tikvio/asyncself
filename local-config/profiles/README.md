# AsyncSelf platform profiles

Copy the matching `*.env.example` to `*.env` on each computer and fill only
that machine's paths and project values. Keep tokens in a separate ignored
file and point `ASYNCSELF_SHARED_ENV_FILE` at it when shared credentials are
intentional. Never commit `*.env`, `active-profile`, `runtime/`, SQLite files,
locks, or webhook secrets.

The selected profile controls the complete component matrix:

- `gitlab`: the Symphony-derived core, Gatekeeper, GitLab MR watcher, and optional
  Linear/GitLab webhook receiver.
- `github`: the Symphony-derived core, Gatekeeper, and optional Linear-only webhook
  receiver. There is deliberately no separate GitHub PR watcher; Gatekeeper
  performs the deterministic merge only after a human moves an issue to
  `Merging`.

Use `./start_asyncself.sh --profile <name> --check` before starting services.
The GitLab example uses GitLab.com, but `ASYNCSELF_GITLAB_HOST` may select another
compatible HTTPS GitLab host.
