# AsyncSelf dependency pipeline

This package contains the deterministic parts of AsyncSelf's planning and
dependency workflow. It can:

- parse a Markdown specification into a validated task DAG;
- generate a human-reviewable preview, JSON plan, graph, and per-node specs;
- create Linear issues in topological order after explicit approval;
- maintain dependency states and process Gatekeeper events.

It is bundled under `local-tools` so a public checkout has no dependency on a
machine-specific external repository.

## CLI

From the repository root:

```bash
python3 local-tools/dependency_pipeline/scripts/asyncself-pipeline preview path/to/spec.md
python3 local-tools/dependency_pipeline/scripts/asyncself-pipeline apply path/to/dag-plan.json
```

`apply` is a dry run unless `--execute` is passed. Live Linear operations read
the token named by `--api-key-env` (default: `LINEAR_API_KEY`) and never store it
in the generated plan.

Every preview is a persistent review package containing `dag-preview.md`,
`preview-graph.md`, `dag-plan.json`, and one file per task under `specs/`. The
command prints its resolved `artifacts:` path.

The default central layout separates one Codex installation's output by
AsyncSelf instance and business project:

```text
~/.local/state/asyncself/specs/<instance>/<project>/<timestamp>-<requirement>/
```

Set the namespaces with environment variables:

```bash
export ASYNCSELF_SPEC_INSTANCE="personal"
export ASYNCSELF_SPEC_PROJECT="example-app"
python3 local-tools/dependency_pipeline/scripts/asyncself-pipeline preview path/to/spec.md
```

Or set them for one command:

```bash
python3 local-tools/dependency_pipeline/scripts/asyncself-pipeline preview path/to/spec.md \
  --instance personal --project example-app
```

`ASYNCSELF_SPEC_STORE_ROOT` or `--store-root` moves the central store while
preserving the instance/project hierarchy. To keep generated plans beside the
business repository instead, use:

```bash
python3 local-tools/dependency_pipeline/scripts/asyncself-pipeline preview path/to/spec.md \
  --output-mode adjacent
```

Adjacent mode derives a sibling `<project>.asyncself-specs/` directory from the
spec's `Local Source Repo`; it does not write inside that Git repository. Use
`--out` only when selecting the exact directory for one run. The legacy
`ASYNCSELF_SPEC_OUTPUT_ROOT` remains supported as an exact project output root.

## Codex skill

Codex discovers `.codex/skills/spec-planner` when this repository is the active
project. Ask it to use `$spec-planner` to turn a requirement into a reviewed
task DAG.

To use the skill while working in other repositories, install that directory as
a user skill and point it back to this checkout:

```bash
cp -R .codex/skills/spec-planner ~/.codex/skills/spec-planner
export ASYNCSELF_HOME=/path/to/asyncself
```

The skill generates and reviews a preview before any Linear write. Creating
issues still requires an explicit approval followed by `apply --execute`.

## Tests

```bash
cd local-tools/dependency_pipeline
python3 -m unittest discover -s tests -p 'test_*.py'
```
