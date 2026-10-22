"""ASGI webhook receiver that authenticates and durably enqueues notifications."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import sqlite3
import time
from typing import Any

from .config import AuxConfig, load_config
from .inbox import Inbox


class WebhookReceiver:
    def __init__(self, config: AuxConfig, inbox: Inbox, *, clock=time.time):
        self.config = config
        self.inbox = inbox
        self.clock = clock

    def handle(self, path: str, headers: dict[str, str], body: bytes) -> tuple[int, dict[str, Any]]:
        if len(body) > self.config.max_body_bytes:
            return 413, {"status": "too_large"}
        normalized = {str(key).lower(): str(value) for key, value in headers.items()}
        if path == "/webhooks/linear":
            if "linear" not in self.config.allowed_sources:
                return 404, {"status": "source_disabled"}
            return self._linear(normalized, body)
        if path == "/webhooks/gitlab":
            if "gitlab" not in self.config.allowed_sources:
                return 404, {"status": "source_disabled"}
            return self._gitlab(normalized, body)
        return 404, {"status": "not_found"}

    def _linear(self, headers: dict[str, str], body: bytes) -> tuple[int, dict[str, Any]]:
        secret = os.environ.get(self.config.linear_webhook_secret_env)
        signature = headers.get("linear-signature", "")
        delivery = headers.get("linear-delivery", "")
        if not secret or not signature or not delivery:
            return 401, {"status": "unauthorized"}
        expected = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, signature):
            return 401, {"status": "unauthorized"}
        try:
            payload = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return 400, {"status": "invalid_json"}
        timestamp_ms = payload.get("webhookTimestamp")
        if not isinstance(timestamp_ms, (int, float)):
            return 400, {"status": "missing_timestamp"}
        if abs(self.clock() - float(timestamp_ms) / 1000.0) > self.config.timestamp_tolerance_seconds:
            return 401, {"status": "stale"}
        event_type = str(payload.get("type") or headers.get("linear-event") or "unknown")
        data = payload.get("data") if isinstance(payload.get("data"), dict) else {}
        issue_id = _linear_issue_id(event_type, data)
        resource = f"issue:{issue_id}" if issue_id else "scan:linear"
        jobs = [
            (consumer, resource, {"source": "linear", "event_type": event_type})
            for consumer in self.config.linear_consumers
        ]
        try:
            inserted = self.inbox.enqueue(
                "linear", delivery, event_type, resource, body, jobs,
                now=self.clock(), debounce_seconds=self.config.debounce_seconds,
                max_debounce_seconds=self.config.max_debounce_seconds,
            )
        except (OSError, RuntimeError, sqlite3.Error) as exc:
            return 503, {"status": "unavailable", "error": type(exc).__name__}
        return 200, {"status": "accepted" if inserted else "duplicate"}

    def _gitlab(self, headers: dict[str, str], body: bytes) -> tuple[int, dict[str, Any]]:
        secret = os.environ.get(self.config.gitlab_webhook_secret_env)
        if not secret or not self._verify_gitlab(headers, body, secret):
            return 401, {"status": "unauthorized"}
        try:
            payload = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return 400, {"status": "invalid_json"}
        project = payload.get("project") if isinstance(payload.get("project"), dict) else {}
        if project.get("path_with_namespace") != self.config.gitlab_project:
            return 200, {"status": "ignored_project"}
        event_type = str(headers.get("x-gitlab-event") or payload.get("object_kind") or "unknown")
        resources = _gitlab_resources(payload)
        if not resources:
            resources = ["scan:gitlab"]
        delivery = (
            headers.get("webhook-id") or headers.get("idempotency-key")
            or hashlib.sha256(body).hexdigest()
        )
        jobs = [("mr", resource, {"source": "gitlab", "event_type": event_type}) for resource in resources]
        try:
            inserted = self.inbox.enqueue(
                "gitlab", delivery, event_type, ",".join(resources), body, jobs,
                now=self.clock(), debounce_seconds=self.config.debounce_seconds,
                max_debounce_seconds=self.config.max_debounce_seconds,
            )
        except (OSError, RuntimeError, sqlite3.Error) as exc:
            return 503, {"status": "unavailable", "error": type(exc).__name__}
        return 200, {"status": "accepted" if inserted else "duplicate"}

    def _verify_gitlab(self, headers: dict[str, str], body: bytes, secret: str) -> bool:
        if self.config.gitlab_webhook_auth == "secret_token":
            return hmac.compare_digest(headers.get("x-gitlab-token", ""), secret)
        message_id = headers.get("webhook-id", "")
        timestamp = headers.get("webhook-timestamp", "")
        received = headers.get("webhook-signature", "")
        if not message_id or not timestamp or not received:
            return False
        try:
            timestamp_value = int(timestamp)
            if abs(self.clock() - timestamp_value) > max(300, self.config.timestamp_tolerance_seconds):
                return False
            key_text = secret.removeprefix("whsec_")
            key = base64.b64decode(key_text, validate=True)
        except (ValueError, binascii.Error):
            return False
        message = message_id.encode() + b"." + timestamp.encode() + b"." + body
        expected = "v1," + base64.b64encode(hmac.new(key, message, hashlib.sha256).digest()).decode()
        return any(hmac.compare_digest(expected, item) for item in received.split())


class WebhookApp:
    def __init__(self, receiver: WebhookReceiver):
        self.receiver = receiver

    async def __call__(self, scope: dict, receive: Any, send: Any) -> None:
        if scope.get("type") != "http":
            return
        method = scope.get("method", "GET")
        path = scope.get("path", "")
        if method == "GET" and path in {"/health/live", "/health/ready"}:
            status, payload = 200, {"status": "ok"}
        elif method != "POST":
            status, payload = 405, {"status": "method_not_allowed"}
        else:
            body = bytearray()
            while True:
                event = await receive()
                body.extend(event.get("body", b""))
                if len(body) > self.receiver.config.max_body_bytes:
                    status, payload = 413, {"status": "too_large"}
                    break
                if not event.get("more_body", False):
                    headers = {key.decode("latin1"): value.decode("latin1") for key, value in scope.get("headers", [])}
                    status, payload = self.receiver.handle(path, headers, bytes(body))
                    break
        encoded = json.dumps(payload, separators=(",", ":")).encode()
        await send({"type": "http.response.start", "status": status,
                    "headers": [(b"content-type", b"application/json"),
                                (b"content-length", str(len(encoded)).encode())]})
        await send({"type": "http.response.body", "body": encoded})


def build_app(config_path: str | None = None) -> WebhookApp:
    config = load_config(config_path, require_secrets=True)
    if not config.webhook_enabled:
        raise RuntimeError("webhook receiver is disabled in polling mode")
    inbox = Inbox(config.inbox_path)
    inbox.initialize()
    return WebhookApp(WebhookReceiver(config, inbox))


def create_http_server(receiver: WebhookReceiver, host: str, port: int) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path in {"/health/live", "/health/ready"}:
                self._reply(200, {"status": "ok"})
            else:
                self._reply(404, {"status": "not_found"})

        def do_POST(self) -> None:
            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                self._reply(400, {"status": "invalid_content_length"})
                return
            if length < 0 or length > receiver.config.max_body_bytes:
                self._reply(413, {"status": "too_large"})
                return
            body = self.rfile.read(length)
            status, payload = receiver.handle(self.path, dict(self.headers.items()), body)
            self._reply(status, payload)

        def _reply(self, status: int, payload: dict[str, Any]) -> None:
            encoded = json.dumps(payload, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, format: str, *args: Any) -> None:
            # Do not log request headers or bodies because they may contain secrets.
            return

    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    return server


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config")
    args = parser.parse_args(argv)
    config = load_config(args.config, require_secrets=True)
    if not config.webhook_enabled:
        raise RuntimeError("webhook receiver is disabled in polling mode")
    app = build_app(args.config)
    server = create_http_server(app.receiver, config.receiver_host, config.receiver_port)
    print(
        f"webhook receiver profile={config.profile} listening on "
        f"{config.receiver_host}:{config.receiver_port}",
        flush=True,
    )
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def _linear_issue_id(event_type: str, data: dict[str, Any]) -> str | None:
    if event_type.lower() in {"issue", "issues"}:
        value = data.get("id")
    else:
        value = data.get("issueId") or ((data.get("issue") or {}).get("id") if isinstance(data.get("issue"), dict) else None)
    return str(value) if value else None


def _gitlab_resources(payload: dict[str, Any]) -> list[str]:
    kind = str(payload.get("object_kind") or "")
    attributes = payload.get("object_attributes") if isinstance(payload.get("object_attributes"), dict) else {}
    if kind == "merge_request" and attributes.get("iid") is not None:
        return [f"mr:{int(attributes['iid'])}"]
    if kind in {"pipeline", "build"}:
        merge_requests = payload.get("merge_requests") if isinstance(payload.get("merge_requests"), list) else []
        ids = sorted({int(item["iid"]) for item in merge_requests if isinstance(item, dict) and item.get("iid") is not None})
        return [f"mr:{iid}" for iid in ids]
    return []


if __name__ == "__main__":
    raise SystemExit(main())
