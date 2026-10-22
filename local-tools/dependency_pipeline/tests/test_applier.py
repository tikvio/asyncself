import json
from pathlib import Path
import tempfile
import unittest

from symphony_dependency_pipeline.applier import apply_plan, render_description
from symphony_dependency_pipeline.linear_client import CreatedIssue


class FakeLinearClient:
    def __init__(self):
        self.created = []
        self.description_updates = []
        self.relations = []

    def project(self, project_slug):
        self.project_slug = project_slug
        return {"team_id": "team-1", "project_id": "project-1"}

    def state_id(self, team_id, state_name):
        return f"state-{state_name.lower().replace(' ', '-')}"

    def ensure_workflow_state(self, team_id, state_name):
        return self.state_id(team_id, state_name)

    def label_id(self, team_id, label_name):
        return f"label-{label_name}"

    def create_issue(self, *, team_id, project_id, title, description, state_id=None, label_ids=None):
        issue = CreatedIssue(id=f"issue-{len(self.created) + 1}", identifier=f"EX-{len(self.created) + 1}")
        self.created.append(
            {
                "title": title,
                "description": description,
                "state_id": state_id,
                "label_ids": list(label_ids or []),
                "issue": issue,
            }
        )
        return issue

    def update_issue_description(self, issue_id, description):
        self.description_updates.append((issue_id, description))

    def create_blocked_by(self, blocked_issue_id, blocker_issue_id):
        self.relations.append((blocked_issue_id, blocker_issue_id))


class ApplierTest(unittest.TestCase):
    def test_render_description_supports_pull_requests(self):
        task = {
            "depends_on": ["T1"],
            "start_gate": ["- [ ] API contract confirmed"],
            "base_branch": "main",
            "delivery": "pr",
            "review": "pull-request",
            "review_url": None,
            "merging_action": "land-pr",
            "body": "",
        }
        created = {"T1": CreatedIssue(id="issue-1", identifier="EX-1")}

        description = render_description(task, created, "feature/asyncself/EX-2-api", {"target_branch": "main"})

        self.assertIn("- [ ] dep:EX-1 dependency completed", description)
        self.assertIn("- [ ] human: API contract confirmed", description)
        self.assertIn("Review Target Branch: main", description)
        self.assertIn("Review: pull-request", description)
        self.assertIn("Merging Action: land-pr", description)

    def test_apply_plan_defaults_to_dry_run(self):
        plan = {
            "project_slug": "example-project",
            "linear_labels": ["example-app", "ai:base"],
            "topo_order": ["T1"],
            "tasks": [
                {
                    "node_id": "T1",
                    "title": "Implement feature",
                    "depends_on": [],
                    "labels": ["example-app", "ai:base"],
                    "delivery": "pr",
                    "start_gate": ["- [x] ready"],
                    "initial": "auto",
                }
            ],
        }

        with tempfile.TemporaryDirectory() as tmp:
            plan_path = Path(tmp) / "dag-plan.json"
            plan_path.write_text(json.dumps(plan))
            results = apply_plan(plan_path, None)

        self.assertEqual(results[0].action, "would-create")
        self.assertIn("labels=example-app,ai:base", results[0].details)


if __name__ == "__main__":
    unittest.main()
