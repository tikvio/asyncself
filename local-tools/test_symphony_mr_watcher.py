import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

path = Path(__file__).with_name("symphony_mr_watcher.py")
spec = importlib.util.spec_from_file_location("symphony_mr_watcher", path)
watcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watcher)
watcher.PROJECT = "example-group/example-repo"
watcher.LABEL = "example-project"


def issue(state="Merging", target="feature/experiment"):
    return {
        "id": "id-1", "identifier": "SYM-1",
        "project": {"id": "project-1"},
        "description": f"Target: {target}\nGitLab MR: {watcher.GITLAB_HOST}/example-group/example-repo/-/merge_requests/7",
        "state": {"name": state}, "labels": {"nodes": [{"name": "example-project"}]},
        "comments": {"nodes": []}, "attachments": {"nodes": []},
    }


def mr(state="opened", status="mergeable", target="feature/experiment"):
    return {"state": state, "detailed_merge_status": status,
            "target_branch": target, "sha": "abc123"}


class WatcherTest(unittest.TestCase):
    def run_case(self, current_issue, replies, dry_run=True):
        with patch.object(watcher, "linear_issue", return_value=current_issue), \
             patch.object(watcher, "gitlab", side_effect=replies) as api, \
             patch.object(watcher, "write_done", return_value="done") as done:
            client = Mock()
            client.project.return_value = {"project_id": "project-1"}
            result = watcher.process_issue(client, current_issue["id"], dry_run=dry_run)
            return result, api, done

    def test_other_project_skipped(self):
        foreign = issue()
        foreign["project"] = {"id": "other-project"}
        result, api, _ = self.run_case(foreign, [])
        self.assertEqual(result, "skipped_project")
        api.assert_not_called()

    def test_in_review_open_waits_without_merge(self):
        result, api, done = self.run_case(issue("In Review"), [mr()])
        self.assertEqual(result, "waiting_review_or_human_merge")
        self.assertEqual(api.call_count, 1)
        done.assert_not_called()

    def test_directly_merged_reconciles_done(self):
        result, api, done = self.run_case(issue("In Review"), [mr("merged")], dry_run=False)
        self.assertEqual(result, "done")
        done.assert_called_once()

    def test_wrong_target_blocks_even_if_merged(self):
        result, _, done = self.run_case(issue("In Review"), [mr("merged", target="main")], dry_run=False)
        self.assertEqual(result, "blocked_target_mismatch")
        done.assert_not_called()

    def test_unapproved_blocks(self):
        result, _, done = self.run_case(issue(), [mr(), {"approved_by": []}])
        self.assertEqual(result, "blocked_not_approved")
        done.assert_not_called()

    def test_pending_pipeline_waits(self):
        replies = [mr(), {"approved_by": [{"user": {"id": 1}}]},
                   [{"sha": "abc123", "status": "pending"}]]
        result, _, done = self.run_case(issue(), replies)
        self.assertEqual(result, "waiting_pipeline_pending")
        done.assert_not_called()

    def test_latest_pipeline_wins_even_when_api_order_is_unexpected(self):
        replies = [mr(), {"approved_by": [{"user": {"id": 1}}], "approvals_left": 0},
                   [{"id": 3, "sha": "abc123", "status": "success"},
                    {"id": 4, "sha": "abc123", "status": "failed"}]]
        result, _, _ = self.run_case(issue(), replies)
        self.assertEqual(result, "waiting_pipeline_failed")

    def test_pipeline_match_on_second_gitlab_page_is_not_missed(self):
        first_page = [{"id": number, "sha": "other", "status": "success"} for number in range(100)]
        replies = [mr(), {"approved_by": [{"user": {"id": 1}}], "approvals_left": 0},
                   first_page, [{"id": 101, "sha": "abc123", "status": "success"}]]
        result, api, _ = self.run_case(issue(), replies)
        self.assertEqual(result, "ready_to_merge_dry_run")
        self.assertEqual(api.call_count, 4)

    def test_partial_approval_does_not_merge(self):
        result, _, _ = self.run_case(issue(), [mr(), {"approved_by": [{"user": {"id": 1}}], "approvals_left": 1}])
        self.assertEqual(result, "blocked_not_approved")

    def test_failed_pipeline_waits(self):
        replies = [mr(), {"approved_by": [{"user": {"id": 1}}]},
                   [{"sha": "abc123", "status": "failed"}]]
        result, _, _ = self.run_case(issue(), replies)
        self.assertEqual(result, "waiting_pipeline_failed")

    def test_conflict_blocks(self):
        replies = [mr(status="conflict"), {"approved_by": [{"user": {"id": 1}}]}, []]
        result, _, _ = self.run_case(issue(), replies)
        self.assertEqual(result, "blocked_conflict")

    def test_approved_mergeable_dry_run(self):
        replies = [mr(), {"approved_by": [{"user": {"id": 1}}]}, []]
        result, api, done = self.run_case(issue(), replies)
        self.assertEqual(result, "ready_to_merge_dry_run")
        self.assertEqual(api.call_count, 3)
        done.assert_not_called()

    def test_missing_or_multiple_mr_links_block(self):
        bare = issue()
        bare["description"] = "No link"
        self.assertEqual(watcher.linked_mr_iid(bare), None)
        bare["description"] += f" {watcher.GITLAB_HOST}/example-group/example-repo/-/merge_requests/1"
        bare["comments"]["nodes"].append({"body": f"{watcher.GITLAB_HOST}/example-group/example-repo/-/merge_requests/2"})
        with self.assertRaises(RuntimeError):
            watcher.linked_mr_iid(bare)

    def test_missing_target_is_blocked_instead_of_falling_back_to_main(self):
        current = issue()
        current["description"] = f"GitLab MR: {watcher.GITLAB_HOST}/example-group/example-repo/-/merge_requests/7"
        result, api, _ = self.run_case(current, [])
        self.assertEqual(result, "blocked_missing_target")
        api.assert_not_called()

    def test_target_must_be_in_config_allowlist(self):
        current = issue(target="feature/not-allowed")
        with patch.object(watcher, "linear_issue", return_value=current), \
             patch.object(watcher, "gitlab") as api:
            client = Mock()
            client.project.return_value = {"project_id": "project-1"}
            result = watcher.process_issue(client, current["id"], dry_run=True,
                                           allowed_targets=("feature/experiment",))
        self.assertEqual(result, "blocked_target_not_allowed")
        api.assert_not_called()

    def test_linear_issue_paginates_comments_and_attachments(self):
        client = Mock()
        first = issue()
        first["description"] = "Target: feature/experiment"
        first["comments"] = {"nodes": [], "pageInfo": {"hasNextPage": True, "endCursor": "c1"}}
        first["attachments"] = {"nodes": [], "pageInfo": {"hasNextPage": True, "endCursor": "a1"}}
        client.graphql.side_effect = [
            {"issue": first},
            {"issue": {"comments": {"nodes": [{"id": "c", "body": f"{watcher.GITLAB_HOST}/example-group/example-repo/-/merge_requests/7"}],
                                     "pageInfo": {"hasNextPage": False}}}},
            {"issue": {"attachments": {"nodes": [{"id": "a", "url": "https://example.invalid"}],
                                        "pageInfo": {"hasNextPage": False}}}},
        ]
        result = watcher.linear_issue(client, "SYM-1")
        self.assertEqual(watcher.linked_mr_iid(result), 7)
        self.assertEqual(client.graphql.call_count, 3)

    def test_done_write_rechecks_linear_state(self):
        original = issue("Merging")
        changed = issue("Needs Info")
        with patch.object(watcher, "linear_issue", return_value=changed):
            client = Mock()
            result = watcher.write_done(client, original)
        self.assertEqual(result, "blocked_linear_state_changed")
        client.update_issue_state.assert_not_called()

    def test_two_issues_linking_same_mr_are_both_marked_ambiguous(self):
        from symphony_aux.inbox import Inbox
        first = issue()
        second = issue()
        second["id"], second["identifier"] = "id-2", "SYM-2"
        with tempfile.TemporaryDirectory() as tmp:
            inbox = Inbox(Path(tmp) / "inbox.sqlite3")
            inbox.initialize()
            prepared = watcher.prepare_candidates(inbox, Mock(), [first, second])
        self.assertEqual([ambiguous for _, ambiguous in prepared], [True, True])


if __name__ == "__main__":
    unittest.main()
