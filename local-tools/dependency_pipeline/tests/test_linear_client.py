from unittest import TestCase
from unittest.mock import Mock

from symphony_dependency_pipeline.linear_client import LinearClient


class CaptureLinearClient(LinearClient):
    def __init__(self):
        super().__init__(api_key="test")
        self.query = None
        self.variables = None

    def graphql(self, query, variables=None):
        self.query = query
        self.variables = variables
        return {"team": {"states": {"nodes": [{"id": "state-1", "name": "Todo"}]}}}


class FakeLinearClient(LinearClient):
    def __init__(self):
        super().__init__(api_key="test")
        self.variables = None

    def state_id(self, team_id: str, state_name: str) -> str:
        raise RuntimeError("missing")

    def graphql(self, query, variables=None):
        self.variables = variables
        return {
            "workflowStateCreate": {
                "success": True,
                "workflowState": {"id": "state-1", "name": "Needs Info"},
            }
        }


class WorkflowOrderClient(LinearClient):
    def __init__(self):
        super().__init__(api_key="test")
        self.calls = []

    def graphql(self, query, variables=None):
        self.calls.append((query, variables))
        if "AsyncSelfWorkflowStates" in query:
            return {
                "team": {
                    "states": {
                        "nodes": [
                            {"id": "todo", "name": "Todo", "type": "unstarted", "position": 1000},
                            {"id": "waiting", "name": "Waiting", "type": "unstarted", "position": 2000},
                            {"id": "needs-info", "name": "Needs Info", "type": "unstarted", "position": 3000},
                            {"id": "rework", "name": "Rework", "type": "unstarted", "position": 4000},
                            {"id": "in-progress", "name": "In Progress", "type": "started", "position": 5000},
                            {"id": "in-review", "name": "In Review", "type": "started", "position": 1002},
                            {"id": "merging", "name": "Merging", "type": "started", "position": 3000.09},
                            {"id": "done", "name": "Done", "type": "completed", "position": 6000},
                        ]
                    }
                }
            }
        return {"workflowStateUpdate": {"success": True}}


class LinearClientTests(TestCase):
    def test_state_id_query_uses_string_team_id_variable(self):
        client = CaptureLinearClient()

        state_id = client.state_id("team-1", "Todo")

        self.assertEqual(state_id, "state-1")
        self.assertIn("query AsyncSelfState($teamId: String!", client.query)
        self.assertEqual(client.variables["teamId"], "team-1")

    def test_ensure_workflow_state_sends_required_color(self):
        client = FakeLinearClient()

        state_id = client.ensure_workflow_state("team-1", "Needs Info")

        self.assertEqual(state_id, "state-1")
        self.assertEqual(client.variables["input"]["color"], "#F2C94C")

    def test_sync_workflow_state_order_moves_dependency_queue_before_todo(self):
        client = WorkflowOrderClient()

        changed = client.sync_workflow_state_order(
            "team-1",
            ("Need Info", "Waiting", "Todo", "Rework", "In Progress", "In Review", "Merging"),
        )

        self.assertEqual([state.name for state in changed], ["Needs Info", "Waiting", "Rework", "In Review", "Merging"])
        update_calls = [variables for query, variables in client.calls if "AsyncSelfUpdateWorkflowState" in query]
        self.assertEqual(
            update_calls,
            [
                {"stateId": "needs-info", "input": {"position": 800.0}},
                {"stateId": "waiting", "input": {"position": 900.0}},
                {"stateId": "rework", "input": {"position": 3000.0}},
                {"stateId": "in-review", "input": {"position": 5100.0}},
                {"stateId": "merging", "input": {"position": 5200.0}},
            ],
        )

    def test_fetch_issue_paginates_history_and_blockers(self):
        client = LinearClient(api_key="test")
        node = {
            "id": "i1", "identifier": "SYM-1", "title": "one", "description": "", "url": None,
            "state": {"name": "Waiting"}, "labels": {"nodes": []},
            "history": {"nodes": [], "pageInfo": {"hasNextPage": True, "endCursor": "h1"}},
            "inverseRelations": {"nodes": [], "pageInfo": {"hasNextPage": True, "endCursor": "b1"}},
        }
        client.graphql = Mock(side_effect=[
            {"issue": node},
            {"issue": {"history": {"nodes": [{"fromState": {"name": "Done"},
                                                 "toState": {"name": "Needs Info"}}],
                                    "pageInfo": {"hasNextPage": False}}}},
            {"issue": {"inverseRelations": {"nodes": [{"type": "blocks", "issue": {
                "id": "p1", "identifier": "SYM-0", "state": {"name": "Done"}}}],
                                              "pageInfo": {"hasNextPage": False}}}},
        ])

        issue = client.fetch_issue("SYM-1")

        self.assertTrue(issue.previously_completed)
        self.assertEqual(issue.blocked_by[0]["identifier"], "SYM-0")
        self.assertEqual(client.graphql.call_count, 3)

    def test_fetch_successors_paginates_relations(self):
        client = LinearClient(api_key="test")

        def relation(number):
            return {"type": "blocks", "relatedIssue": {
                "id": f"i{number}",
            }}

        client.graphql = Mock(side_effect=[
            {"issue": {"relations": {"nodes": [relation(1)],
                                       "pageInfo": {"hasNextPage": True, "endCursor": "r1"}}}},
            {"issue": {"relations": {"nodes": [relation(2)],
                                       "pageInfo": {"hasNextPage": False}}}},
        ])
        client.fetch_issue = Mock(side_effect=[
            Mock(identifier="SYM-1"), Mock(identifier="SYM-2"),
        ])

        result = client.fetch_successors("SYM-0")

        self.assertEqual([item.identifier for item in result], ["SYM-1", "SYM-2"])
        self.assertEqual(client.graphql.call_args_list[1].args[1]["after"], "r1")
        self.assertNotIn("history(first", client.graphql.call_args_list[0].args[0])
        self.assertEqual(
            [entry.args[0] for entry in client.fetch_issue.call_args_list],
            ["i1", "i2"],
        )
