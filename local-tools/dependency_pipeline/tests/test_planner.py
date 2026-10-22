from pathlib import Path
import tempfile
import unittest

from symphony_dependency_pipeline.planner import (
    SpecError,
    parse_spec,
    render_preview,
    topological_sort,
    write_preview,
)


class PlannerTest(unittest.TestCase):
    def test_parse_github_spec_and_topological_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec_path = Path(tmp) / "spec.md"
            spec_path.write_text(
                """# Example feature

Project Slug: example-project
Active Label: example-app
Agent Profile Label: ai:base
Linear Labels: example-app, ai:base
Workflow: /path/to/WORKFLOW.md
Local Source Repo: /path/to/source
Workspace: /path/to/workspaces
SCM Provider: github
SCM Project: your-org/example-app
Forbidden Paths: /path/to/private-config
Branch Strategy: integration-branch
Target Branch: main
Integration Branch: feature/asyncself/example-feature
Final Merge: feature/asyncself/example-feature -> main

## Tasks

### T1 Shared model
Depends on: none
Base Branch: feature/asyncself/example-feature
Start Gate:
- [x] fields confirmed

### T2 API adapter
Depends on: T1
Base Branch: feature/asyncself/example-feature
Start Gate:
- [ ] contract confirmed
"""
            )
            spec = parse_spec(spec_path)

        self.assertEqual(spec.scm_provider, "github")
        self.assertEqual(spec.scm_project, "your-org/example-app")
        self.assertEqual(spec.topo_order, ("T1", "T2"))
        self.assertEqual(spec.tasks[0].review, "pull-request")
        self.assertEqual(spec.tasks[0].merging_action, "land-pr")
        preview = render_preview(spec)
        self.assertIn("- SCM Provider: `github`", preview)
        self.assertIn("feature/asyncself/{issue-key}-shared-model", preview)
        self.assertIn('T2["T2 API adapter [human input]"]', preview)

    def test_legacy_gitlab_project_field_remains_supported(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec_path = Path(tmp) / "spec.md"
            spec_path.write_text(
                """# GitLab example

Project Slug: example-project
GitLab Project: your-group/example-app
Target Branch: main

## Tasks

### T1 Implementation
Depends on: none
Base Branch: main
Delivery: mr
Start Gate:
- [x] ready
"""
            )
            spec = parse_spec(spec_path)

        self.assertEqual(spec.scm_provider, "gitlab")
        self.assertEqual(spec.scm_project, "your-group/example-app")
        self.assertEqual(spec.tasks[0].review, "merge-request")
        self.assertEqual(spec.tasks[0].merging_action, "land-mr")

    def test_write_preview_emits_plan_graph_and_node_specs(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec_path = Path(tmp) / "spec.md"
            spec_path.write_text(
                """# Documentation update

Project Slug: example-project
SCM Provider: github
SCM Project: your-org/example-app
Target Branch: main

## Tasks

### T1 Update docs
Depends on: none
Base Branch: main
Delivery: branch-diff
No Merge Reason: documentation preview only
Start Gate:
- [x] scope confirmed
Acceptance:
- Documentation matches the public behavior.
"""
            )
            spec = parse_spec(spec_path)
            preview_path, plan_path = write_preview(spec, Path(tmp) / "out")

            self.assertTrue(plan_path.exists())
            self.assertTrue((Path(tmp) / "out" / "preview-graph.md").exists())
            self.assertTrue((Path(tmp) / "out" / "specs" / "T1-update-docs.md").exists())
            self.assertIn("## Task table", preview_path.read_text())

    def test_cycle_detection(self):
        class Task:
            def __init__(self, node_id, depends_on):
                self.node_id = node_id
                self.depends_on = depends_on

        with self.assertRaises(SpecError):
            topological_sort([Task("T1", ("T2",)), Task("T2", ("T1",))])

    def test_integration_review_tasks_must_start_from_integration_branch(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec_path = Path(tmp) / "spec.md"
            spec_path.write_text(
                """# Invalid integration spec

Branch Strategy: integration-branch
Target Branch: main
Integration Branch: feature/asyncself/integration

## Tasks

### T1 Wrong base
Depends on: none
Base Branch: main
Delivery: pr
Start Gate:
- [x] ready
"""
            )

            with self.assertRaisesRegex(SpecError, "Base Branch must be the Integration Branch"):
                parse_spec(spec_path)


if __name__ == "__main__":
    unittest.main()
