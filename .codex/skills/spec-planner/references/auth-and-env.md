# Authentication and environment

Live Linear commands read an API key from an environment variable. The default
name is `LINEAR_API_KEY`; select another with `--api-key-env NAME`.

Before a live command, check only whether the chosen variable exists. Never
print its value, copy it into a spec, write it to `dag-plan.json`, or include it
in logs or chat output.

Safe commands that do not require credentials:

- `preview`
- `apply` without `--execute`

Commands that access Linear and therefore require credentials:

- `apply --execute`
- `ensure-states`
- `gatekeeper`

`ASYNCSELF_HOME` is not a secret. Set it to the AsyncSelf repository root when
this skill is installed outside that checkout. `ASYNCSELF_SPEC_OUTPUT_ROOT`
selects the generated-artifact directory.
