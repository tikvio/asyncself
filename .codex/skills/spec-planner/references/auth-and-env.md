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
this skill is installed outside that checkout. Artifact placement variables are
also non-secret: `ASYNCSELF_SPEC_INSTANCE`, `ASYNCSELF_SPEC_PROJECT`,
`ASYNCSELF_SPEC_STORE_ROOT`, and `ASYNCSELF_SPEC_OUTPUT_MODE`. The legacy
`ASYNCSELF_SPEC_OUTPUT_ROOT` remains an exact project-output-root override. See
[configuration](configuration.md#generated-artifact-storage) for layout and
precedence.
