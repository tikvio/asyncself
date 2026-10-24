# Markdown spec format

Use this shape as the planner input. Replace every example with reviewed project
values before a private live apply; retain placeholders in public examples.

```markdown
# Example feature

Project Slug: example-project
Linear Labels: example-app, ai:base
Workflow: /path/to/WORKFLOW.md
Local Source Repo: /path/to/source
Workspace: /path/to/workspaces
SCM Provider: github
SCM Project: your-org/example-app
Forbidden Paths: /path/to/secrets, /path/to/unrelated-project
Branch Strategy: integration-branch
Target Branch: main
Integration Branch: feature/asyncself/example-feature
Final Merge: feature/asyncself/example-feature -> main

## Tasks

### T1 Define the shared model
Depends on: none
Base Branch: feature/asyncself/example-feature
Delivery: pr
Start Gate:
- [x] field names and compatibility policy confirmed

Acceptance:
- The model has unit tests for valid and invalid input.

### T2 Add the API adapter
Depends on: T1
Base Branch: feature/asyncself/example-feature
Delivery: pr
Start Gate:
- [ ] human: response schema and error codes approved

Acceptance:
- The adapter uses the shared model.
- Integration tests cover success and failure responses.
```

Task headings must begin with a stable node ID such as `T1`. `Depends on`
accepts comma-separated node IDs or `none`. A cycle, unknown dependency, or
invalid integration-branch base is rejected before preview files are written.

Optional task fields include `Labels`, `Review`, `Review URL`, `Merging Action`,
`Initial`, and `Slug`. Text not consumed as a field or Start Gate becomes the
task body and is carried into the generated Linear description.

## Preview archive

The Markdown file above is the source input. `preview` turns it into an
auditable package containing the graph, plan JSON, summary, and standalone task
specs. By default, runs are separated by AsyncSelf instance and business
project:

```text
~/.local/state/asyncself/specs/
  <instance>/
    <project>/
      <timestamp>-<requirement>/
        dag-preview.md
        preview-graph.md
        dag-plan.json
        specs/
```

The source spec may be kept with that review package or in another location the
user chose. Do not silently place generated artifacts inside the AsyncSelf
checkout or a business Git repository.
