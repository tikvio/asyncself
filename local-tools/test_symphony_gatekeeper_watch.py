import importlib.util
from pathlib import Path
import tempfile
import unittest

path = Path(__file__).with_name("symphony_gatekeeper_watch.py")
spec = importlib.util.spec_from_file_location("symphony_gatekeeper_watch", path)
watcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watcher)


def summary(state="Done", updated="u1"):
    return {"id": "id-1", "identifier": "SYM-1", "updatedAt": updated,
            "state": {"name": state}, "project": {"id": "project-1"},
            "labels": {"nodes": [{"name": "example-project"}]}}


class GraphClient:
    def __init__(self, pages):
        self.pages = list(pages)
        self.calls = []

    def graphql(self, query, variables):
        self.calls.append((query, variables))
        return self.pages.pop(0)


class Result:
    event = "done"
    issue = "SYM-1"
    actions = []
    warnings = []


class Keeper:
    def __init__(self, fail=False):
        self.fail = fail

    def handle_done(self, issue_id):
        if self.fail:
            raise RuntimeError("temporary")
        return Result()

    handle_needs_info_updated = handle_done
    handle_entered_waiting = handle_done


class Merger:
    def __init__(self):
        self.calls = []

    def process_issue(self, client, issue_id, *, dry_run=False):
        self.calls.append((client, issue_id, dry_run))
        return "ready_to_merge_dry_run"


class GatekeeperWatchTest(unittest.TestCase):
    def test_project_scan_paginates(self):
        client = GraphClient([
            {"issues": {"nodes": [summary()], "pageInfo": {"hasNextPage": True, "endCursor": "c1"}}},
            {"issues": {"nodes": [summary("Waiting")], "pageInfo": {"hasNextPage": False}}},
        ])
        self.assertEqual(len(watcher.project_issues(client, "project-1")), 2)
        self.assertEqual(client.calls[1][1]["after"], "c1")

    def test_failed_item_remains_unremembered(self):
        remembered = {}
        client = GraphClient([{"issues": {"nodes": [summary()],
                                           "pageInfo": {"hasNextPage": False}}}])
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(RuntimeError):
            watcher.scan_once(client, Keeper(fail=True), "project-1", "example-project", remembered,
                              process_existing=True, issue_refs=[], lock_file=Path(tmp) / "lock")
        self.assertEqual(remembered, {})

    def test_direct_issue_does_not_scan_project(self):
        client = GraphClient([{"issue": summary("Waiting")}])
        remembered = {}
        with tempfile.TemporaryDirectory() as tmp:
            count = watcher.scan_once(client, Keeper(), "project-1", "example-project", remembered,
                                      process_existing=True, issue_refs=["SYM-1"],
                                      lock_file=Path(tmp) / "lock")
        self.assertEqual(count, 1)
        self.assertIn("query GatekeeperIssue", client.calls[0][0])

    def test_needs_info_and_waiting_reconcile_without_updated_at_change(self):
        for state in ("Needs Info", "Waiting"):
            current = summary(state)
            self.assertTrue(watcher.should_process(current, {
                "state": state, "updatedAt": "u1"}, process_existing=False))

    def test_github_merging_is_reconciled_without_updated_at_change(self):
        current = summary("Merging")
        self.assertTrue(watcher.should_process(
            current, {"state": "Merging", "updatedAt": "u1"},
            process_existing=False, watched_states=watcher.GITHUB_WATCHED_STATES))

    def test_github_merging_dispatches_deterministic_handler(self):
        merger = Merger()
        keeper = Keeper()
        keeper.client = object()
        result = watcher.run_gatekeeper_event(
            keeper, summary("Merging"), github_merger=merger, dry_run=True)
        self.assertEqual(result.event, "github_merge")
        self.assertEqual(result.actions, ["ready_to_merge_dry_run"])
        self.assertEqual(merger.calls, [(keeper.client, "id-1", True)])

    def test_dry_run_client_suppresses_writes(self):
        class Client:
            def __init__(self): self.writes = 0
            def update_issue_state(self, *args): self.writes += 1
            def project(self): return "read"
        raw = Client()
        dry = watcher.DryRunClient(raw)
        dry.update_issue_state("id", "state")
        self.assertEqual(raw.writes, 0)
        self.assertEqual(dry.project(), "read")

    def test_telemetry_failure_is_reduced_to_a_safe_error_without_touching_business_logic(self):
        def broken_publish(_value):
            raise OSError("token=secret")

        self.assertEqual(
            watcher.publish_observation_safely(broken_publish, {"last_result": {"kind": "scan_complete"}}),
            "OSError",
        )


if __name__ == "__main__":
    unittest.main()
