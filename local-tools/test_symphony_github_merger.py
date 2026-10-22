import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

path = Path(__file__).with_name("symphony_github_merger.py")
spec = importlib.util.spec_from_file_location("symphony_github_merger", path)
merger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(merger)


def issue(state="Merging"):
    return {
        "id": "id-1", "identifier": "EXM-7", "title": "test",
        "description": "GitHub PR: https://github.com/example-org/example-repo/pull/7",
        "project": {"id": "project-1"}, "state": {"name": state},
        "labels": {"nodes": [{"name": "example-project"}]},
        "comments": {"nodes": []}, "attachments": {"nodes": []},
    }


def pr(**overrides):
    value = {
        "number": 7, "title": "EXM-7 implement change", "body": "Fixes EXM-7",
        "state": "OPEN", "isDraft": False, "mergeable": "MERGEABLE",
        "mergeStateStatus": "CLEAN", "baseRefName": "feature/asyncself/example-target",
        "headRefName": "asyncself/exm-7", "headRefOid": "abc123",
        "statusCheckRollup": [{"__typename": "CheckRun", "name": "build",
                               "status": "COMPLETED", "conclusion": "SUCCESS"}],
    }
    value.update(overrides)
    return value


class GitHubMergerTest(unittest.TestCase):
    def setUp(self):
        self.client = Mock()
        self.client.project.return_value = {"project_id": "project-1", "team_id": "team-1"}
        self.expected_repo = patch.object(merger, "EXPECTED_REPOSITORY", "example-org/example-repo")
        self.expected_target = patch.object(
            merger, "EXPECTED_TARGET", "feature/asyncself/example-target")
        self.required_label = patch.object(merger, "LABEL", "example-project")
        self.expected_repo.start()
        self.expected_target.start()
        self.required_label.start()
        self.addCleanup(self.expected_repo.stop)
        self.addCleanup(self.expected_target.stop)
        self.addCleanup(self.required_label.stop)

    def run_case(self, current_issue=None, current_pr=None, *, threads=0, dry_run=True):
        with patch.object(merger, "pull_request", return_value=current_pr or pr()), \
             patch.object(merger, "unresolved_review_threads", return_value=threads), \
             patch.object(merger, "gh_run") as gh:
            result = merger.process_issue_data(
                self.client, current_issue or issue(), dry_run=dry_run)
            return result, gh

    def test_ready_dry_run(self):
        result, gh = self.run_case()
        self.assertEqual(result, "ready_to_merge_dry_run")
        gh.assert_not_called()

    def test_mergeability_does_not_authorize_in_review(self):
        result, gh = self.run_case(issue("In Review"))
        self.assertEqual(result, "skipped_state")
        gh.assert_not_called()

    def test_wrong_repository_or_target_blocks(self):
        current = issue()
        current["description"] = "https://github.com/other/repo/pull/7"
        self.assertEqual(self.run_case(current)[0], "blocked_repository_mismatch")
        self.assertEqual(self.run_case(current_pr=pr(baseRefName="main"))[0],
                         "blocked_target_mismatch")

    def test_required_build_must_exist_and_pass(self):
        self.assertEqual(self.run_case(current_pr=pr(statusCheckRollup=[]))[0],
                         "waiting_required_check_absent")
        self.assertEqual(self.run_case(current_pr=pr(statusCheckRollup=[{
            "__typename": "CheckRun", "name": "build", "status": "COMPLETED",
            "conclusion": "FAILURE"}]))[0], "blocked_required_check_failed")

    def test_unresolved_threads_block(self):
        self.assertEqual(self.run_case(threads=1)[0], "blocked_unresolved_review_threads")

    def test_issue_identity_is_required(self):
        self.assertEqual(self.run_case(current_pr=pr(title="missing"))[0],
                         "blocked_issue_id_missing_from_title")
        self.assertEqual(self.run_case(current_pr=pr(title="EXM-70 wrong issue"))[0],
                         "blocked_issue_id_missing_from_title")
        self.assertEqual(self.run_case(current_pr=pr(body="missing"))[0],
                         "blocked_fixes_missing_from_body")

    def test_merge_uses_head_guard_and_marks_done(self):
        with patch.object(merger, "pull_request", side_effect=[pr(), pr(state="MERGED")]), \
             patch.object(merger, "unresolved_review_threads", return_value=0), \
             patch.object(merger, "gh_run") as gh, \
             patch.object(merger, "write_done", return_value="done") as done:
            result = merger.process_issue_data(self.client, issue(), dry_run=False)
        self.assertEqual(result, "done")
        gh.assert_called_once_with([
            "pr", "merge", "7", "--repo", "example-org/example-repo", "--squash",
            "--match-head-commit", "abc123"])
        done.assert_called_once()

    def test_already_merged_reconciles_done_without_second_merge(self):
        with patch.object(merger, "pull_request", return_value=pr(state="MERGED")), \
             patch.object(merger, "write_done", return_value="done") as done, \
             patch.object(merger, "gh_run") as gh:
            result = merger.process_issue_data(self.client, issue(), dry_run=False)
        self.assertEqual(result, "done")
        done.assert_called_once()
        gh.assert_not_called()

    def test_multiple_pr_links_are_rejected(self):
        current = issue()
        current["comments"]["nodes"].append({
            "body": "https://github.com/example-org/example-repo/pull/8"})
        with self.assertRaises(RuntimeError):
            merger.linked_pr(current)


if __name__ == "__main__":
    unittest.main()
