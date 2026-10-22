import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name("land_watch.py")
SPEC = importlib.util.spec_from_file_location("land_watch", MODULE_PATH)
land_watch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(land_watch)


def pr(**changes):
    values = {
        "number": 1,
        "url": "https://github.com/example-org/example-repo/pull/1",
        "head_sha": "abc",
        "mergeable": "MERGEABLE",
        "merge_state": "CLEAN",
        "base_ref": "feature/asyncself/example-target",
        "head_ref": "asyncself/exm-1-change",
        "author_login": "author",
        "is_draft": False,
        "state": "OPEN",
    }
    values.update(changes)
    return land_watch.PrInfo(**values)


class ScopeGuardTest(unittest.TestCase):
    def test_expected_repo_and_target_pass(self):
        with patch.dict(os.environ, {
            "SYMPHONY_GITHUB_REPOSITORY": "example-org/example-repo",
            "SYMPHONY_TARGET_BRANCH": "feature/asyncself/example-target",
        }, clear=False):
            land_watch.validate_pr_scope(pr(), "example-org/example-repo")

    def test_wrong_repo_base_or_main_is_rejected(self):
        with patch.dict(os.environ, {
            "SYMPHONY_GITHUB_REPOSITORY": "example-org/example-repo",
            "SYMPHONY_TARGET_BRANCH": "feature/asyncself/example-target",
        }, clear=False):
            with self.assertRaises(RuntimeError):
                land_watch.validate_pr_scope(pr(), "other/repo")
            with self.assertRaises(RuntimeError):
                land_watch.validate_pr_scope(pr(base_ref="main"), "example-org/example-repo")
        with patch.dict(os.environ, {
            "SYMPHONY_GITHUB_REPOSITORY": "example-org/example-repo",
            "SYMPHONY_TARGET_BRANCH": "main",
        }, clear=False):
            with self.assertRaises(RuntimeError):
                land_watch.validate_pr_scope(pr(base_ref="main"), "example-org/example-repo")

    def test_no_approving_review_is_required(self):
        land_watch.raise_on_human_feedback([], [], [], None)

    def test_changes_requested_still_blocks(self):
        reviews = [{
            "user": {"login": "reviewer", "type": "User"},
            "state": "CHANGES_REQUESTED",
            "submitted_at": "2026-01-01T00:01:00Z",
        }]
        with self.assertRaises(SystemExit) as raised:
            land_watch.raise_on_human_feedback([], [], reviews, None)
        self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
