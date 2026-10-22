import unittest

from symphony_dependency_pipeline import start_gate


class StartGateTest(unittest.TestCase):
    def test_mark_dependency_checked(self):
        markdown = """Branch: feature/x

## Start Gate
- [ ] dep:SYM-21 dependency completed
- [x] human: design confirmed

## Notes
body
"""

        result = start_gate.mark_dependency_checked(markdown, "SYM-21")

        self.assertTrue(result.found)
        self.assertTrue(result.changed)
        self.assertIn("- [x] dep:SYM-21 dependency completed", result.text)
        self.assertIn("## Notes", result.text)

    def test_mark_dependency_checked_matches_dep_marker_exactly(self):
        markdown = """## Start Gate
- [ ] dep:SYM-2 dependency completed
- [ ] dep:SYM-21 dependency completed
"""

        result = start_gate.mark_dependency_checked(markdown, "SYM-2")

        self.assertIn("- [x] dep:SYM-2 dependency completed", result.text)
        self.assertIn("- [ ] dep:SYM-21 dependency completed", result.text)

    def test_mark_dependency_checked_supports_legacy_dependency_lines(self):
        markdown = """## Start Gate
- [ ] SYM-21 dependency completed
- [x] design confirmed
"""

        result = start_gate.mark_dependency_checked(markdown, "SYM-21")

        self.assertTrue(result.changed)
        self.assertIn("- [x] SYM-21 dependency completed", result.text)

    def test_human_items_checked_ignores_dependency_items(self):
        markdown = """## Start Gate
- [ ] dep:SYM-21 dependency completed
- [x] human: design confirmed
"""

        self.assertTrue(start_gate.human_items_checked(markdown, ["SYM-21"]))

    def test_human_marker_keeps_issue_key_text_human_owned(self):
        markdown = """## Start Gate
- [ ] dep:SYM-21 dependency completed
- [x] human: check rollout note mentioning SYM-99
"""

        self.assertTrue(start_gate.human_items_checked(markdown, ["SYM-21"]))

    def test_all_checkboxes_checked_requires_everything(self):
        markdown = """## Start Gate
- [ ] dep:SYM-21 dependency completed
- [x] human: design confirmed
"""

        self.assertFalse(start_gate.all_checkboxes_checked(markdown))

    def test_ensure_human_checkbox_marker(self):
        line = "- [ ] backend contract confirmed"

        self.assertEqual(
            start_gate.ensure_human_checkbox_marker(line),
            "- [ ] human: backend contract confirmed",
        )


if __name__ == "__main__":
    unittest.main()
