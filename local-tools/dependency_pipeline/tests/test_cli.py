import os
from pathlib import Path
import unittest
from unittest.mock import patch

from symphony_dependency_pipeline import cli


class Spec:
    title = "Coordinate tests"
    scm_project = "example-org/page-builder"
    project_slug = "page-builder-1234abcd"
    local_source_repo = "/home/example/code/page-builder"


class DefaultPreviewOutputDirTest(unittest.TestCase):
    def clean_output_env(self):
        return patch.dict(os.environ, {}, clear=True)

    def test_central_layout_uses_instance_and_project_namespaces(self):
        with self.clean_output_env():
            output = cli.default_preview_output_dir(
                Spec(),
                store_root="/tmp/spec-store",
                instance="personal",
                project="page-builder",
            )

        self.assertEqual(output.parent, Path("/tmp/spec-store/personal/page-builder"))
        self.assertRegex(output.name, r"^\d{8}-\d{6}-\d{3}-coordinate-tests$")

    def test_central_layout_infers_project_from_scm_project(self):
        with self.clean_output_env():
            output = cli.default_preview_output_dir(
                Spec(),
                store_root="/tmp/spec-store",
                instance="personal",
            )

        self.assertEqual(
            output.parent,
            Path("/tmp/spec-store/personal/example-org-page-builder"),
        )

    def test_central_layout_reads_environment_configuration(self):
        with patch.dict(
            os.environ,
            {
                "ASYNCSELF_SPEC_STORE_ROOT": "/tmp/spec-store",
                "ASYNCSELF_SPEC_INSTANCE": "work",
                "ASYNCSELF_SPEC_PROJECT": "example-app",
            },
            clear=True,
        ):
            output = cli.default_preview_output_dir(Spec())

        self.assertEqual(
            output.parent,
            Path("/tmp/spec-store/work/example-app"),
        )

    def test_adjacent_layout_uses_sibling_directory(self):
        with self.clean_output_env():
            output = cli.default_preview_output_dir(Spec(), output_mode="adjacent")

        self.assertEqual(
            output.parent,
            Path("/home/example/code/page-builder.asyncself-specs"),
        )

    def test_adjacent_layout_accepts_explicit_store_root(self):
        with self.clean_output_env():
            output = cli.default_preview_output_dir(
                Spec(),
                output_mode="adjacent",
                store_root="/tmp/page-builder-specs",
            )

        self.assertEqual(output.parent, Path("/tmp/page-builder-specs"))

    def test_adjacent_layout_reads_environment_mode(self):
        with patch.dict(
            os.environ,
            {"ASYNCSELF_SPEC_OUTPUT_MODE": "adjacent"},
            clear=True,
        ):
            output = cli.default_preview_output_dir(Spec())

        self.assertEqual(
            output.parent,
            Path("/home/example/code/page-builder.asyncself-specs"),
        )

    def test_legacy_exact_output_root_remains_highest_default_override(self):
        with patch.dict(
            os.environ,
            {"ASYNCSELF_SPEC_OUTPUT_ROOT": "/tmp/exact-project-root"},
        ):
            output = cli.default_preview_output_dir(
                Spec(),
                output_mode="central",
                store_root="/tmp/ignored",
                instance="ignored",
                project="ignored",
            )

        self.assertEqual(output.parent, Path("/tmp/exact-project-root"))

    def test_invalid_environment_mode_fails_closed(self):
        with patch.dict(
            os.environ,
            {
                "ASYNCSELF_SPEC_OUTPUT_ROOT": "",
                "ASYNCSELF_SPEC_OUTPUT_MODE": "somewhere",
            },
        ):
            with self.assertRaisesRegex(RuntimeError, "central or adjacent"):
                cli.default_preview_output_dir(Spec())


if __name__ == "__main__":
    unittest.main()
