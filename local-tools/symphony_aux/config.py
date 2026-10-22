"""Configuration for the profile-scoped webhook accelerator."""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
from typing import Any


DEFAULT_ROOT = Path(os.environ.get("ASYNCSELF_ROOT") or os.environ.get("SYMPHONY_ROOT", Path(__file__).resolve().parents[2]))
DEFAULT_CONFIG_PATH = DEFAULT_ROOT / "local-config" / "webhook.json"
DEFAULT_STORAGE_DIR = DEFAULT_ROOT / "local-config" / "webhook"
VALID_MODES = {"polling", "shadow", "hybrid"}
VALID_GITLAB_AUTH = {"secret_token", "signing_token"}
VALID_PROFILES = {"gitlab", "github"}
VALID_SOURCES = {"linear", "gitlab"}
VALID_CONSUMERS = {"gatekeeper", "mr"}


@dataclass(frozen=True)
class AuxConfig:
    profile: str = "gitlab"
    mode: str = "polling"
    receiver_host: str = "127.0.0.1"
    receiver_port: int = 4081
    storage_dir: Path = DEFAULT_STORAGE_DIR
    poll_seconds: float = 15.0
    local_queue_check_seconds: float = 1.0
    debounce_seconds: float = 2.0
    max_debounce_seconds: float = 10.0
    lease_seconds: float = 120.0
    linear_webhook_secret_env: str = "LINEAR_WEBHOOK_SECRET"
    gitlab_webhook_auth: str = "secret_token"
    gitlab_webhook_secret_env: str = "GITLAB_WEBHOOK_SECRET"
    gitlab_project: str = "example-group/example-repo"
    allowed_target_branches: tuple[str, ...] = ("feature/asyncself/example-target",)
    missing_target_policy: str = "block"
    pipeline_policy: str = "allow_absent_current_sha"
    max_body_bytes: int = 2 * 1024 * 1024
    timestamp_tolerance_seconds: int = 60
    allowed_sources: tuple[str, ...] = ("linear", "gitlab")
    linear_consumers: tuple[str, ...] = ("gatekeeper", "mr")

    @property
    def inbox_path(self) -> Path:
        return self.storage_dir / "inbox.sqlite3"

    @property
    def webhook_enabled(self) -> bool:
        return self.mode in {"shadow", "hybrid"}

    @property
    def notification_dry_run(self) -> bool:
        return self.mode == "shadow"

    def secret_presence(self) -> dict[str, bool]:
        result: dict[str, bool] = {}
        if "linear" in self.allowed_sources:
            result[self.linear_webhook_secret_env] = bool(os.environ.get(self.linear_webhook_secret_env))
        if "gitlab" in self.allowed_sources:
            result[self.gitlab_webhook_secret_env] = bool(os.environ.get(self.gitlab_webhook_secret_env))
        return result

    def validate(self, *, require_secrets: bool = False) -> None:
        if self.profile not in VALID_PROFILES:
            raise RuntimeError(f"invalid profile: {self.profile}")
        if self.mode not in VALID_MODES:
            raise RuntimeError(f"invalid webhook mode: {self.mode}")
        if not self.allowed_sources or not set(self.allowed_sources) <= VALID_SOURCES:
            raise RuntimeError("allowed_sources must contain only linear/gitlab")
        if not self.linear_consumers or not set(self.linear_consumers) <= VALID_CONSUMERS:
            raise RuntimeError("linear consumers must contain only gatekeeper/mr")
        if self.profile == "github":
            if set(self.allowed_sources) != {"linear"}:
                raise RuntimeError("GitHub profile only accepts Linear webhooks")
            if set(self.linear_consumers) != {"gatekeeper"}:
                raise RuntimeError("GitHub profile only routes Linear notifications to Gatekeeper")
        elif "gitlab" not in self.allowed_sources or "mr" not in self.linear_consumers:
            raise RuntimeError("GitLab profile must retain GitLab MR notifications")
        if self.gitlab_webhook_auth not in VALID_GITLAB_AUTH:
            raise RuntimeError(f"invalid GitLab webhook auth mode: {self.gitlab_webhook_auth}")
        if not (1 <= self.receiver_port <= 65535):
            raise RuntimeError("receiver port must be between 1 and 65535")
        if self.max_body_bytes <= 0 or self.timestamp_tolerance_seconds <= 0:
            raise RuntimeError("body size and timestamp tolerance must be positive")
        for name, value in (
            ("poll_seconds", self.poll_seconds),
            ("local_queue_check_seconds", self.local_queue_check_seconds),
            ("debounce_seconds", self.debounce_seconds),
            ("max_debounce_seconds", self.max_debounce_seconds),
            ("lease_seconds", self.lease_seconds),
        ):
            if value <= 0:
                raise RuntimeError(f"{name} must be positive")
        if self.max_debounce_seconds < self.debounce_seconds:
            raise RuntimeError("max_debounce_seconds must be >= debounce_seconds")
        if "gitlab" in self.allowed_sources and not _valid_project_path(self.gitlab_project):
            raise RuntimeError("gitlab.project_path must be group/repository")
        if self.missing_target_policy != "block":
            raise RuntimeError("missing_target_policy must remain block")
        if self.pipeline_policy not in {"allow_absent_current_sha", "require_success"}:
            raise RuntimeError("invalid pipeline_policy")
        if not self.allowed_target_branches:
            raise RuntimeError("allowed_target_branches cannot be empty")
        if "main" in self.allowed_target_branches:
            raise RuntimeError("main cannot be an allowed webhook experiment target")
        if require_secrets and self.webhook_enabled:
            missing = [name for name, present in self.secret_presence().items() if not present]
            if missing:
                raise RuntimeError("missing webhook secret variables: " + ", ".join(missing))


def load_config(path: str | Path | None = None, *, require_secrets: bool = False) -> AuxConfig:
    config_path = Path(
        path
        or os.environ.get("ASYNCSELF_WEBHOOK_CONFIG")
        or os.environ.get("SYMPHONY_WEBHOOK_CONFIG", DEFAULT_CONFIG_PATH)
    )
    if not config_path.exists():
        config = AuxConfig()
        config.validate(require_secrets=require_secrets)
        return config

    try:
        raw = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"invalid webhook config: {type(exc).__name__}") from exc
    if not isinstance(raw, dict):
        raise RuntimeError("webhook config must be a JSON object")
    unknown = set(raw) - {
        "schema_version", "profile", "mode", "receiver", "linear", "gitlab", "consumers",
        "allowed_sources", "storage_dir",
        "poll_seconds", "local_queue_check_seconds", "debounce_seconds",
        "max_debounce_seconds", "lease_seconds", "max_body_bytes",
        "timestamp_tolerance_seconds",
    }
    if unknown:
        raise RuntimeError("unknown webhook config fields: " + ", ".join(sorted(unknown)))
    if raw.get("schema_version", 1) not in {1, 2}:
        raise RuntimeError("unsupported webhook config schema_version")
    receiver = _mapping(raw.get("receiver"), "receiver")
    linear = _mapping(raw.get("linear"), "linear")
    gitlab = _mapping(raw.get("gitlab"), "gitlab")
    consumers = _mapping(raw.get("consumers"), "consumers")
    config = AuxConfig(
        profile=str(raw.get("profile", "gitlab")),
        mode=str(raw.get("mode", "polling")),
        receiver_host=str(receiver.get("host", "127.0.0.1")),
        receiver_port=int(receiver.get("port", 4081)),
        storage_dir=Path(os.path.expandvars(str(raw.get("storage_dir", DEFAULT_STORAGE_DIR)))).expanduser(),
        poll_seconds=float(raw.get("poll_seconds", 15)),
        local_queue_check_seconds=float(raw.get("local_queue_check_seconds", 1)),
        debounce_seconds=float(raw.get("debounce_seconds", 2)),
        max_debounce_seconds=float(raw.get("max_debounce_seconds", 10)),
        lease_seconds=float(raw.get("lease_seconds", 120)),
        linear_webhook_secret_env=str(linear.get("webhook_secret_env", "LINEAR_WEBHOOK_SECRET")),
        gitlab_webhook_auth=str(gitlab.get("webhook_auth", "secret_token")),
        gitlab_webhook_secret_env=str(gitlab.get("webhook_secret_env", "GITLAB_WEBHOOK_SECRET")),
        gitlab_project=str(gitlab.get("project_path", "example-group/example-repo")),
        allowed_target_branches=tuple(str(item) for item in gitlab.get(
            "allowed_target_branches", ["feature/asyncself/example-target"]
        )),
        missing_target_policy=str(gitlab.get("missing_target_policy", "block")),
        pipeline_policy=str(gitlab.get("pipeline_policy", "allow_absent_current_sha")),
        max_body_bytes=int(raw.get("max_body_bytes", 2 * 1024 * 1024)),
        timestamp_tolerance_seconds=int(raw.get("timestamp_tolerance_seconds", 60)),
        allowed_sources=tuple(str(item) for item in raw.get("allowed_sources", ["linear", "gitlab"])),
        linear_consumers=tuple(str(item) for item in consumers.get("linear", ["gatekeeper", "mr"])),
    )
    config.validate(require_secrets=require_secrets)
    return config


def _mapping(value: Any, name: str) -> dict[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise RuntimeError(f"{name} must be a JSON object")
    return value


def _valid_project_path(value: str) -> bool:
    parts = value.strip("/").split("/") if isinstance(value, str) else []
    return len(parts) >= 2 and all(part and part not in {".", ".."} for part in parts)
