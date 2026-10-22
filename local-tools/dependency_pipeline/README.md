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

Preview output defaults to `~/.local/state/asyncself/specs`. Set
`ASYNCSELF_SPEC_OUTPUT_ROOT` to use another location.

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
