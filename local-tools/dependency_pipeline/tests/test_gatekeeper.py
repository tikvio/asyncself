from dataclasses import replace
import unittest

from symphony_dependency_pipeline.gatekeeper import DependencyGatekeeper, GatekeeperConfig
from symphony_dependency_pipeline.linear_client import LinearIssue


class FakeClient:
    def __init__(self, issues, successors=None):
        self.issues = dict(issues)
        self.successors = successors or {}
        self.description_updates = []
        self.state_updates = []
        self.label_updates = []

    def fetch_issue(self, issue_ref):
        return self.issues[issue_ref]

    def fetch_successors(self, issue_ref):
        return self.successors.get(issue_ref, [])

    def update_issue_description(self, issue_id, description):
        self.description_updates.append((issue_id, description))
        issue = self.issues[issue_id]
        self.issues[issue_id] = replace(issue, description=description)

    def update_issue_state(self, issue_id, state_id):
        self.state_updates.append((issue_id, state_id))

    def set_issue_labels(self, issue_id, label_ids):
        self.label_updates.append((issue_id, label_ids))


def issue(
    issue_id,
    identifier,
    state,
    description,
    blocked_by=(),
    labels=(),
    label_ids=(),
    previously_completed=False,
):
    return LinearIssue(
        id=issue_id,
        identifier=identifier,
        title=identifier,
        description=description,
        state=state,
        labels=tuple(labels),
        label_ids=tuple(label_ids),
        blocked_by=tuple(blocked_by),
        previously_completed=previously_completed,
    )


def gatekeeper(client):
    return DependencyGatekeeper(
        client,
        GatekeeperConfig(todo_state_id="todo-state", waiting_state_id="waiting-state", active_label_id="label-active"),
    )


class DependencyGatekeeperTest(unittest.TestCase):
    def test_done_marks_needs_info_successor_without_promoting(self):
        parent = issue("p1", "SYM-21", "Done", "")
        successor = issue(
            "s1",
            "SYM-22",
            "Needs Info",
            "## Start Gate\n- [ ] dep:SYM-21 dependency completed\n- [ ] human: design confirmed\n",
        )
        client = FakeClient({"p1": parent, "s1": successor}, {"p1": [successor]})

        result = gatekeeper(client).handle_done("p1")

        self.assertTrue(client.description_updates)
        self.assertIn("- [x] dep:SYM-21 dependency completed", client.description_updates[0][1])
        self.assertFalse(client.state_updates)
        self.assertTrue(any("Needs Info" in action for action in result.actions))

    def test_done_promotes_waiting_successor_when_ready(self):
        parent = issue("p1", "SYM-21", "Done", "")
        successor = issue(
            "s1",
            "SYM-22",
            "Waiting",
            "## Start Gate\n- [ ] dep:SYM-21 dependency completed\n- [x] human: design confirmed\n",
            blocked_by=({"identifier": "SYM-21", "state": "Done", "id": "p1"},),
            label_ids=("existing-label",),
        )
        client = FakeClient({"p1": parent, "s1": successor}, {"p1": [successor]})

        gatekeeper(client).handle_done("p1")

        self.assertIn(("s1", "todo-state"), client.state_updates)
        self.assertIn(("s1", ["existing-label", "label-active"]), client.label_updates)

    def test_needs_info_updated_moves_to_waiting_when_human_items_complete(self):
        item = issue(
            "s1",
            "SYM-22",
            "Needs Info",
            "## Start Gate\n- [ ] dep:SYM-21 dependency completed\n- [x] human: design confirmed\n",
            blocked_by=({"identifier": "SYM-21", "state": "Todo", "id": "p1"},),
        )
        client = FakeClient({"s1": item})

        gatekeeper(client).handle_needs_info_updated("s1")

        self.assertIn(("s1", "waiting-state"), client.state_updates)

    def test_needs_info_updated_does_not_resurrect_previously_completed_issue(self):
        item = issue(
            "s1",
            "SYM-22",
            "Needs Info",
            "## Start Gate\n- [x] dep:SYM-21 dependency completed\n- [x] human: design confirmed\n",
            blocked_by=({"identifier": "SYM-21", "state": "Done", "id": "p1"},),
            previously_completed=True,
        )
        client = FakeClient({"s1": item})

        result = gatekeeper(client).handle_needs_info_updated("s1")

        self.assertFalse(client.state_updates)
        self.assertIn("SYM-22 was previously Done; skip automatic Needs Info -> Waiting", result.actions)

    def test_entered_waiting_repairs_missed_done_and_promotes(self):
        item = issue(
            "s1",
            "SYM-22",
            "Waiting",
            "## Start Gate\n- [ ] dep:SYM-21 dependency completed\n- [x] human: design confirmed\n",
            blocked_by=({"identifier": "SYM-21", "state": "Done", "id": "p1"},),
        )
        client = FakeClient({"s1": item})

        result = gatekeeper(client).handle_entered_waiting("s1")

        self.assertIn(("s1", "todo-state"), client.state_updates)
        self.assertIn("- [x] dep:SYM-21 dependency completed", client.description_updates[0][1])
        self.assertIn("moved SYM-22 to Todo", result.actions)

    def test_stale_done_event_is_ignored(self):
        item = issue("p1", "SYM-21", "In Progress", "")
        client = FakeClient({"p1": item}, {"p1": []})

        result = gatekeeper(client).handle_done("p1")

        self.assertFalse(client.state_updates)
        self.assertIn("SYM-21 is no longer Done; ignore stale event", result.actions)

    def test_stale_waiting_event_is_ignored(self):
        item = issue("s1", "SYM-22", "Needs Info", "## Start Gate\n- [x] human: ok\n")
        client = FakeClient({"s1": item})

        result = gatekeeper(client).handle_entered_waiting("s1")

        self.assertFalse(client.state_updates)
        self.assertIn("ignore stale Waiting event", result.actions[0])

    def test_entered_waiting_does_not_resurrect_previously_completed_issue(self):
        item = issue(
            "s1",
            "SYM-22",
            "Waiting",
            "## Start Gate\n- [x] dep:SYM-21 dependency completed\n- [x] human: design confirmed\n",
            blocked_by=({"identifier": "SYM-21", "state": "Done", "id": "p1"},),
            previously_completed=True,
        )
        client = FakeClient({"s1": item})

        result = gatekeeper(client).handle_entered_waiting("s1")

        self.assertFalse(client.state_updates)
        self.assertFalse(client.label_updates)
        self.assertIn("SYM-22 was previously Done; skip automatic Waiting -> Todo", result.actions)

    def test_done_needs_info_and_waiting_flow_promotes_when_ready(self):
        parent = issue("p1", "SYM-21", "Done", "")
        successor = issue(
            "s1",
            "SYM-22",
            "Needs Info",
            "## Start Gate\n- [ ] dep:SYM-21 dependency completed\n- [ ] human: backend contract confirmed\n",
            blocked_by=({"identifier": "SYM-21", "state": "Done", "id": "p1"},),
            label_ids=("existing-label",),
        )
        client = FakeClient({"p1": parent, "s1": successor}, {"p1": [successor]})
        keeper = gatekeeper(client)

        done_result = keeper.handle_done("p1")

        self.assertIn("- [x] dep:SYM-21 dependency completed", client.issues["s1"].description)
        self.assertFalse(client.state_updates)
        self.assertTrue(any("Needs Info" in action for action in done_result.actions))

        client.issues["s1"] = replace(
            client.issues["s1"],
            description="## Start Gate\n- [x] dep:SYM-21 dependency completed\n- [x] human: backend contract confirmed\n",
        )
        needs_info_result = keeper.handle_needs_info_updated("s1")

        self.assertIn(("s1", "waiting-state"), client.state_updates)
        self.assertIn("moved SYM-22 to Waiting", needs_info_result.actions)

        client.issues["s1"] = replace(client.issues["s1"], state="Waiting")
        waiting_result = keeper.handle_entered_waiting("s1")

        self.assertIn(("s1", "todo-state"), client.state_updates)
        self.assertIn(("s1", ["existing-label", "label-active"]), client.label_updates)
        self.assertIn("moved SYM-22 to Todo", waiting_result.actions)


if __name__ == "__main__":
    unittest.main()
