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

## Merging is stuck

For GitHub, inspect repository/base/head validation, required checks, the `gh` authentication scope,
and the real PR merged state. `Waiting Gatekeeper` is not proof of success. For GitLab, verify host,
project path, token scope, and MR watcher logs.

## Old and new variables conflict

Remove one side or make matching `ASYNCSELF_*` and `SYMPHONY_*` values identical. New installations
should keep only `ASYNCSELF_*`; legacy variables exist for compatibility.

## Do not repair by deleting state first

Runtime directories contain profile-scoped observations and locks. Stop the launcher, inspect the
failure, and back up relevant state before removing an exact file. Repeated restarts can hide the
event that caused a transition failure.
