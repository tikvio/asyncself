import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


LAUNCHER = Path(__file__).resolve().parents[1] / "start_asyncself.sh"


class LauncherTest(unittest.TestCase):
    def test_aux_only_supervision_singleton_restart_and_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "root"
            tools = root / "local-tools"
            elixir = root / "elixir"
            fake_bin = Path(tmp) / "bin"
            tools.mkdir(parents=True)
            elixir.mkdir()
            fake_bin.mkdir()
            (elixir / "WORKFLOW.md").write_text("test\n")
            (elixir / "WORKFLOW.github.md").write_text("test\n")
            for name in ("symphony_mr_watcher.py", "symphony_gatekeeper_watch.py"):
                (tools / name).write_text("# test fixture\n")
            pipeline = tools / "dependency_pipeline" / "symphony_dependency_pipeline"
            pipeline.mkdir(parents=True)
            (pipeline / "gatekeeper.py").write_text("# test fixture\n")
            source = Path(tmp) / "source"
            source.mkdir()
            webhook = Path(tmp) / "gitlab.webhook.json"
            webhook.write_text("{}\n")
            fake_python = fake_bin / "python3"
            fake_python.write_text(
                "#!/usr/bin/env bash\n"
                "if [[ \"$*\" == *\"symphony_aux.cli\"* ]]; then echo \"${FAKE_MODE:-polling}\"; exit 0; fi\n"
                "echo \"$$ $*\" >> \"$FAKE_LOG\"\n"
                "if [[ \"$*\" == *\"symphony_mr_watcher.py\"* && ! -e \"$FAKE_ONCE\" ]]; then "
                "touch \"$FAKE_ONCE\"; exit 7; fi\n"
                "trap 'exit 0' TERM INT\n"
                "while true; do sleep 0.05; done\n"
            )
            fake_python.chmod(0o755)
            log = Path(tmp) / "children.log"
            env = os.environ.copy()
            env.update({
                "PATH": str(fake_bin) + os.pathsep + env["PATH"],
                "SYMPHONY_ROOT": str(root),
                "SYMPHONY_AUX_STACK_LOCK": str(Path(tmp) / "stack.lock"),
                "SYMPHONY_AUX_RESTART_DELAY_SECONDS": "0.05",
                "FAKE_MODE": "shadow",
                "FAKE_LOG": str(log),
                "FAKE_ONCE": str(Path(tmp) / "mr-exited-once"),
                "SYMPHONY_LINEAR_PROJECT_SLUG": "gitlab-project-test-id",
                "SYMPHONY_LINEAR_PROJECT_SLUG_ID": "test-id",
                "SYMPHONY_REPOSITORY_URL": "https://gitlab.example.com/example-group/example-repo.git",
                "SYMPHONY_GITLAB_HOST": "https://gitlab.example.com",
                "SYMPHONY_GITLAB_PROJECT": "example-group/example-repo",
                "SYMPHONY_TARGET_BRANCH": "feature/asyncself/example-target",
                "SYMPHONY_SOURCE_REPO": str(source),
                "SYMPHONY_GATEKEEPER_PIPELINE_ROOT": str(tools / "dependency_pipeline"),
                "SYMPHONY_WEBHOOK_CONFIG": str(webhook),
                "LINEAR_API_KEY": "test-linear",
                "GITLAB_TOKEN": "test-gitlab",
            })
            process = subprocess.Popen(["bash", str(LAUNCHER), "--aux-only"], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            child_pids = []
            try:
                self._wait_until(lambda: log.exists() and len(log.read_text().splitlines()) >= 4)
                self.assertIsNone(process.poll())
                lines = log.read_text().splitlines()
                self.assertGreaterEqual(sum("symphony_mr_watcher.py" in line for line in lines), 2)
                self.assertTrue(any("symphony_gatekeeper_watch.py" in line for line in lines))
                self.assertTrue(any("symphony_aux.webhook_server" in line for line in lines))

                duplicate = subprocess.run(["bash", str(LAUNCHER), "--aux-only"], env=env,
                                           capture_output=True, text=True, timeout=3)
                self.assertEqual(duplicate.returncode, 5)
                self.assertIn("already running", duplicate.stderr)
                child_pids = [int(line.split()[0]) for line in lines]
            finally:
                process.terminate()
                process.communicate(timeout=5)

            self._wait_until(lambda: all(not Path(f"/proc/{pid}").exists() for pid in child_pids))

    def test_github_aux_only_starts_gatekeeper_and_receiver_without_mr_watcher(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "root"
            tools = root / "local-tools"
            elixir = root / "elixir"
            fake_bin = Path(tmp) / "bin"
            tools.mkdir(parents=True)
            elixir.mkdir()
            fake_bin.mkdir()
            (elixir / "WORKFLOW.github.md").write_text("test\n")
            for name in ("symphony_mr_watcher.py", "symphony_gatekeeper_watch.py", "symphony_github_merger.py"):
                (tools / name).write_text("# test fixture\n")
            pipeline = tools / "dependency_pipeline" / "symphony_dependency_pipeline"
            pipeline.mkdir(parents=True)
            (pipeline / "gatekeeper.py").write_text("# test fixture\n")
            source = Path(tmp) / "source"
            source.mkdir()
            webhook = Path(tmp) / "github.webhook.json"
            webhook.write_text("{}\n")
            fake_python = fake_bin / "python3"
            fake_python.write_text(
                "#!/usr/bin/env bash\n"
                "if [[ \"$*\" == *\"symphony_aux.cli\"* ]]; then echo shadow; exit 0; fi\n"
                "echo \"$$ $*\" >> \"$FAKE_LOG\"\n"
                "trap 'exit 0' TERM INT\n"
                "while true; do sleep 0.05; done\n"
            )
            fake_python.chmod(0o755)
            fake_gh = fake_bin / "gh"
            fake_gh.write_text("#!/usr/bin/env sh\nexit 0\n")
            fake_gh.chmod(0o755)
            log = Path(tmp) / "children.log"
            env = os.environ.copy()
            env.update({
                "PATH": str(fake_bin) + os.pathsep + env["PATH"],
                "SYMPHONY_ROOT": str(root),
                "SYMPHONY_PROFILE": "github",
                "SYMPHONY_CODE_HOST": "github",
                "SYMPHONY_AUX_STACK_LOCK": str(Path(tmp) / "github.lock"),
                "SYMPHONY_AUX_RESTART_DELAY_SECONDS": "0.05",
                "FAKE_LOG": str(log),
                "SYMPHONY_LINEAR_PROJECT_SLUG": "github-project-test-id",
                "SYMPHONY_LINEAR_PROJECT_SLUG_ID": "test-id",
                "SYMPHONY_LINEAR_PROJECT_ID": "project-uuid",
                "SYMPHONY_REPOSITORY_URL": "https://github.com/example-org/example-repo.git",
                "SYMPHONY_GITHUB_REPOSITORY": "example-org/example-repo",
                "SYMPHONY_TARGET_BRANCH": "feature/asyncself/example-target",
                "SYMPHONY_SOURCE_REPO": str(source),
                "SYMPHONY_GATEKEEPER_PIPELINE_ROOT": str(tools / "dependency_pipeline"),
                "SYMPHONY_WEBHOOK_CONFIG": str(webhook),
                "LINEAR_API_KEY": "test-linear",
                "GH_TOKEN": "test-github",
            })
            process = subprocess.Popen(
                ["bash", str(LAUNCHER), "--profile", "github", "--aux-only"],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            try:
                self._wait_until(lambda: log.exists() and len(log.read_text().splitlines()) >= 2)
                lines = log.read_text().splitlines()
                self.assertTrue(any("symphony_gatekeeper_watch.py" in line for line in lines))
                self.assertTrue(any("symphony_aux.webhook_server" in line for line in lines))
                self.assertFalse(any("symphony_mr_watcher.py" in line for line in lines))
            finally:
                process.terminate()
                process.communicate(timeout=5)

    def _wait_until(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.05)
        self.fail("timed out waiting for launcher fixture")


if __name__ == "__main__":
    unittest.main()
