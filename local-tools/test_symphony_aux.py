import base64
import hashlib
import hmac
import json
import os
import sqlite3
import statistics
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib import request

from symphony_aux.config import AuxConfig, load_config
from symphony_aux.inbox import Inbox
from symphony_aux.webhook_server import WebhookReceiver, create_http_server


class InboxTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.inbox = Inbox(Path(self.temp.name) / "inbox.sqlite3")
        self.inbox.initialize()

    def tearDown(self):
        self.temp.cleanup()

    def test_duplicate_and_generation_are_lossless(self):
        jobs = [("mr", "issue:1", {"event": 1})]
        self.assertTrue(self.inbox.enqueue("linear", "d1", "Issue", "issue:1", b"one", jobs,
                                           now=10, debounce_seconds=1, max_debounce_seconds=3))
        self.assertFalse(self.inbox.enqueue("linear", "d1", "Issue", "issue:1", b"one", jobs,
                                            now=10, debounce_seconds=1, max_debounce_seconds=3))
        first = self.inbox.claim("mr", "worker-a", now=11, lease_seconds=5)
        self.assertEqual(first.generation, 1)
        self.inbox.enqueue("linear", "d2", "Issue", "issue:1", b"two", jobs,
                           now=12, debounce_seconds=1, max_debounce_seconds=3)
        self.assertTrue(self.inbox.complete(first, now=12))
        second = self.inbox.claim("mr", "worker-b", now=12, lease_seconds=5)
        self.assertEqual(second.generation, 2)

    def test_expired_lease_failure_and_replay_recover(self):
        self.inbox.enqueue("gitlab", "d1", "MR", "mr:7", b"x", [("mr", "mr:7", {})],
                           now=10, debounce_seconds=1, max_debounce_seconds=2)
        first = self.inbox.claim("mr", "worker-a", now=11, lease_seconds=2)
        self.assertIsNotNone(first)
        self.assertIsNone(self.inbox.claim("mr", "worker-b", now=12, lease_seconds=2))
        recovered = self.inbox.claim("mr", "worker-b", now=13, lease_seconds=2)
        self.assertEqual(recovered.id, first.id)
        self.assertFalse(self.inbox.complete(first, now=13))
        self.assertTrue(self.inbox.fail(recovered, "network", now=13, delay_seconds=2, max_attempts=1))
        self.assertEqual(self.inbox.status()["parked"], 1)
        self.assertTrue(self.inbox.replay(recovered.id, now=20))
        replayed = self.inbox.claim("mr", "worker-c", now=20, lease_seconds=2)
        self.assertEqual(replayed.generation, 2)

    def test_debounce_has_a_hard_maximum(self):
        for index, now in enumerate((0, 3, 6, 9, 12)):
            self.inbox.enqueue("linear", f"d{index}", "Issue", "issue:1", str(index).encode(),
                               [("mr", "issue:1", {})], now=now,
                               debounce_seconds=2, max_debounce_seconds=10)
        self.assertIsNotNone(self.inbox.claim("mr", "worker", now=10, lease_seconds=2))

    def test_500_events_coalesce_to_30_resources(self):
        durations = []
        for index in range(500):
            started = time.perf_counter()
            resource = f"issue:{index % 30}"
            self.inbox.enqueue("linear", f"load-{index}", "Issue", resource,
                               str(index).encode(), [("mr", resource, {})], now=float(index),
                               debounce_seconds=1, max_debounce_seconds=5)
            durations.append(time.perf_counter() - started)
        claimed = []
        while (job := self.inbox.claim("mr", "load-worker", now=1000, lease_seconds=10)) is not None:
            claimed.append(job.resource)
            self.assertTrue(self.inbox.complete(job, now=1000))
        self.assertEqual(len(set(claimed)), 30)
        self.assertEqual(len(claimed), 30)
        p95 = statistics.quantiles(durations, n=20)[18]
        print(f"load_fixture events=500 resources=30 enqueue_p95_seconds={p95:.6f}")
        self.assertLess(p95, 1.0)

    def test_delivery_id_cannot_be_reused_with_other_body(self):
        self.inbox.enqueue("linear", "same", "Issue", "issue:1", b"one", [], now=1)
        with self.assertRaises(RuntimeError):
            self.inbox.enqueue("linear", "same", "Issue", "issue:1", b"two", [], now=2)


class ReceiverTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.config = AuxConfig(mode="hybrid", storage_dir=Path(self.temp.name),
                                debounce_seconds=1, max_debounce_seconds=2)
        self.inbox = Inbox(self.config.inbox_path)
        self.inbox.initialize()
        self.receiver = WebhookReceiver(self.config, self.inbox, clock=lambda: 100.0)

    def tearDown(self):
        self.temp.cleanup()

    def test_linear_signature_timestamp_duplicate_and_jobs(self):
        body = json.dumps({"type": "Issue", "webhookTimestamp": 100000,
                           "data": {"id": "issue-1"}}).encode()
        signature = hmac.new(b"linear-secret", body, hashlib.sha256).hexdigest()
        headers = {"Linear-Signature": signature, "Linear-Delivery": "delivery-1"}
        with patch.dict(os.environ, {"LINEAR_WEBHOOK_SECRET": "linear-secret"}):
            self.assertEqual(self.receiver.handle("/webhooks/linear", headers, body)[0], 200)
            self.assertEqual(self.receiver.handle("/webhooks/linear", headers, body)[1]["status"], "duplicate")
        self.assertEqual(self.inbox.claim("gatekeeper", "g", now=101).resource, "issue:issue-1")
        self.assertEqual(self.inbox.claim("mr", "m", now=101).resource, "issue:issue-1")

    def test_linear_rejects_bad_signature_and_stale_timestamp(self):
        body = json.dumps({"type": "Issue", "webhookTimestamp": 0, "data": {"id": "x"}}).encode()
        signature = hmac.new(b"linear-secret", body, hashlib.sha256).hexdigest()
        with patch.dict(os.environ, {"LINEAR_WEBHOOK_SECRET": "linear-secret"}):
            self.assertEqual(self.receiver.handle("/webhooks/linear", {
                "Linear-Signature": "bad", "Linear-Delivery": "1"}, body)[0], 401)
            self.assertEqual(self.receiver.handle("/webhooks/linear", {
                "Linear-Signature": signature, "Linear-Delivery": "2"}, body)[1]["status"], "stale")

    def test_storage_failure_returns_retryable_503(self):
        body = json.dumps({"type": "Issue", "webhookTimestamp": 100000,
                           "data": {"id": "issue-1"}}).encode()
        signature = hmac.new(b"linear-secret", body, hashlib.sha256).hexdigest()
        with patch.dict(os.environ, {"LINEAR_WEBHOOK_SECRET": "linear-secret"}), \
             patch.object(self.inbox, "enqueue", side_effect=sqlite3.OperationalError("disk")):
            status, result = self.receiver.handle("/webhooks/linear", {
                "Linear-Signature": signature, "Linear-Delivery": "failed"}, body)
        self.assertEqual((status, result["status"]), (503, "unavailable"))

    def test_gitlab_filters_project_and_accepts_secret_token(self):
        payload = {"object_kind": "merge_request", "project": {"path_with_namespace": "other/project"},
                   "object_attributes": {"iid": 7}}
        with patch.dict(os.environ, {"GITLAB_WEBHOOK_SECRET": "gitlab-secret"}):
            status, result = self.receiver.handle("/webhooks/gitlab", {
                "X-Gitlab-Token": "gitlab-secret", "X-Gitlab-Event": "Merge Request Hook"},
                json.dumps(payload).encode())
        self.assertEqual((status, result["status"]), (200, "ignored_project"))
        self.assertEqual(self.inbox.status()["pending"], 0)

    def test_gitlab_event_uuid_is_not_used_as_delivery_dedup_key(self):
        headers = {"X-Gitlab-Token": "gitlab-secret", "X-Gitlab-Event-UUID": "shared-chain"}
        base = {"object_kind": "merge_request",
                "project": {"path_with_namespace": "example-group/example-repo"}}
        with patch.dict(os.environ, {"GITLAB_WEBHOOK_SECRET": "gitlab-secret"}):
            for iid in (7, 8):
                payload = {**base, "object_attributes": {"iid": iid}}
                status, _ = self.receiver.handle(
                    "/webhooks/gitlab", headers, json.dumps(payload).encode())
                self.assertEqual(status, 200)
        self.assertIsNotNone(self.inbox.claim("mr", "m1", now=103))
        self.assertIsNotNone(self.inbox.claim("mr", "m2", now=103))

    def test_gitlab_signing_token(self):
        key = b"0123456789abcdef"
        secret = "whsec_" + base64.b64encode(key).decode()
        body = json.dumps({"object_kind": "merge_request",
                           "project": {"path_with_namespace": "example-group/example-repo"},
                           "object_attributes": {"iid": 7}}).encode()
        message = b"message-1.100." + body
        signature = "v1," + base64.b64encode(hmac.new(key, message, hashlib.sha256).digest()).decode()
        config = AuxConfig(mode="hybrid", storage_dir=Path(self.temp.name),
                           gitlab_webhook_auth="signing_token")
        receiver = WebhookReceiver(config, self.inbox, clock=lambda: 100.0)
        with patch.dict(os.environ, {"GITLAB_WEBHOOK_SECRET": secret}):
            status, _ = receiver.handle("/webhooks/gitlab", {
                "Webhook-Id": "message-1", "Webhook-Timestamp": "100",
                "Webhook-Signature": signature}, body)
        self.assertEqual(status, 200)
        self.assertEqual(self.inbox.claim("mr", "m", now=103).resource, "mr:7")

    def test_github_profile_routes_only_linear_to_gatekeeper(self):
        config = AuxConfig(
            profile="github",
            mode="hybrid",
            storage_dir=Path(self.temp.name),
            allowed_sources=("linear",),
            linear_consumers=("gatekeeper",),
            debounce_seconds=1,
            max_debounce_seconds=2,
        )
        receiver = WebhookReceiver(config, self.inbox, clock=lambda: 100.0)
        body = json.dumps({"type": "Issue", "webhookTimestamp": 100000,
                           "data": {"id": "github-issue"}}).encode()
        signature = hmac.new(b"linear-secret", body, hashlib.sha256).hexdigest()
        with patch.dict(os.environ, {"LINEAR_WEBHOOK_SECRET": "linear-secret"}):
            status, _ = receiver.handle("/webhooks/linear", {
                "Linear-Signature": signature, "Linear-Delivery": "github-linear"}, body)
        self.assertEqual(status, 200)
        self.assertEqual(self.inbox.claim("gatekeeper", "g", now=101).resource,
                         "issue:github-issue")
        self.assertIsNone(self.inbox.claim("mr", "m", now=101))
        self.assertEqual(receiver.handle("/webhooks/gitlab", {}, b"{}")[0], 404)

    def test_standard_library_http_server_smoke(self):
        server = create_http_server(self.receiver, "127.0.0.1", 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_address[1]}"
        try:
            with request.urlopen(base + "/health/ready", timeout=2) as response:
                self.assertEqual(response.status, 200)
            body = json.dumps({"type": "Issue", "webhookTimestamp": 100000,
                               "data": {"id": "issue-http"}}).encode()
            signature = hmac.new(b"linear-secret", body, hashlib.sha256).hexdigest()
            req = request.Request(base + "/webhooks/linear", data=body, method="POST", headers={
                "Content-Type": "application/json", "Linear-Signature": signature,
                "Linear-Delivery": "http-delivery",
            })
            with patch.dict(os.environ, {"LINEAR_WEBHOOK_SECRET": "linear-secret"}), \
                 request.urlopen(req, timeout=2) as response:
                self.assertEqual(response.status, 200)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_http_500_event_fixture_p95_under_one_second(self):
        server = create_http_server(self.receiver, "127.0.0.1", 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_address[1]}/webhooks/linear"
        durations = []
        try:
            with patch.dict(os.environ, {"LINEAR_WEBHOOK_SECRET": "linear-secret"}):
                for index in range(500):
                    body = json.dumps({"type": "Issue", "webhookTimestamp": 100000,
                                       "data": {"id": f"issue-{index % 30}"}}).encode()
                    signature = hmac.new(b"linear-secret", body, hashlib.sha256).hexdigest()
                    req = request.Request(url, data=body, method="POST", headers={
                        "Content-Type": "application/json", "Linear-Signature": signature,
                        "Linear-Delivery": f"http-load-{index}",
                    })
                    started = time.perf_counter()
                    with request.urlopen(req, timeout=2) as response:
                        self.assertEqual(response.status, 200)
                    durations.append(time.perf_counter() - started)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
        p95 = statistics.quantiles(durations, n=20)[18]
        print(f"http_load_fixture events=500 resources=30 response_p95_seconds={p95:.6f}")
        self.assertLess(p95, 1.0)
        self.assertEqual(self.inbox.status()["pending"], 60)


class ConfigTest(unittest.TestCase):
    def test_config_rejects_main_and_malformed_project(self):
        with self.assertRaises(RuntimeError):
            AuxConfig(allowed_target_branches=("main",)).validate()
        with self.assertRaises(RuntimeError):
            AuxConfig(gitlab_project="missing-group").validate()

        AuxConfig(gitlab_project="another-group/another-project").validate()

    def test_default_is_safe_polling_without_secrets(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = load_config(Path(tmp) / "missing.json", require_secrets=True)
        self.assertEqual(config.mode, "polling")
        self.assertFalse(config.webhook_enabled)

    def test_github_profile_rejects_gitlab_or_mr_routes(self):
        with self.assertRaises(RuntimeError):
            AuxConfig(profile="github").validate()
        AuxConfig(
            profile="github",
            allowed_sources=("linear",),
            linear_consumers=("gatekeeper",),
        ).validate()


if __name__ == "__main__":
    unittest.main()
