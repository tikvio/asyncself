import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


path = Path(__file__).with_name("symphony_gatekeeper_observation.py")
spec = importlib.util.spec_from_file_location("symphony_gatekeeper_observation", path)
observation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observation)


class GatekeeperObservationTest(unittest.TestCase):
    def test_snapshot_is_minimal_complete_and_uses_linux_boottime(self):
        value = observation.snapshot(
            "github", "project", "instance", 7,
            scan_interval_seconds=15,
            last_scan_at="2026-10-19T00:00:00Z",
            last_scan_success_boottime_ms=10,
            last_result={"kind": "scan_complete", "processed_count": 2},
            error=RuntimeError("token=secret"),
        )
        self.assertEqual(value["clock_id"], "linux:CLOCK_BOOTTIME:ms")
        self.assertIsInstance(value["heartbeat_boottime_ms"], int)
        self.assertEqual(value["last_error"], "RuntimeError")
        self.assertNotIn("secret", json.dumps(value))
        for field in (
            "schema_version", "profile", "project", "pid", "instance_id", "boot_id",
            "sequence", "heartbeat_at", "last_scan_at", "scan_interval_seconds", "last_result",
        ):
            self.assertIn(field, value)

    def test_atomic_failure_keeps_previous_snapshot_and_returns_redacted_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "gatekeeper-observation.json"
            target.write_text('{"previous":true}', encoding="utf-8")
            value = observation.snapshot("github", "project", "instance", 1,
                                         scan_interval_seconds=15)

            with patch.object(Path, "replace", side_effect=OSError("/secret/path denied")):
                ok, error = observation.publish(target, value)

            self.assertFalse(ok)
            self.assertEqual(error, "OSError")
            self.assertEqual(target.read_text(encoding="utf-8"), '{"previous":true}')

            recovered = observation.snapshot("github", "project", "instance", 2,
                                             scan_interval_seconds=15, error=error)
            self.assertEqual(observation.publish(target, recovered), (True, None))
            self.assertEqual(json.loads(target.read_text(encoding="utf-8"))["last_error"], "OSError")

    def test_clock_unavailable_is_explicit_and_never_becomes_monotonic(self):
        with patch.object(observation.time, "CLOCK_BOOTTIME", create=True), \
             patch.object(observation.time, "clock_gettime_ns", side_effect=OSError("unavailable")):
            self.assertIsNone(observation.boottime_ms())


if __name__ == "__main__":
    unittest.main()
