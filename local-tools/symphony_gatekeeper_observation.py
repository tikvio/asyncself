"""Minimal, read-only Gatekeeper heartbeat snapshot protocol.

The protocol deliberately has no dependency on Gatekeeper state or lock files.
It is best effort: failure to observe must never change the scan's outcome.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import time
import uuid

CLOCK_ID = "linux:CLOCK_BOOTTIME:ms"
SCHEMA_VERSION = 1


def boottime_ms() -> int | None:
    """Return Linux CLOCK_BOOTTIME as integer milliseconds, or no value.

    Do not substitute ``monotonic`` or wall time here: either side of this
    protocol must become unavailable when BOOTTIME is absent.
    """
    try:
        return time.clock_gettime_ns(time.CLOCK_BOOTTIME) // 1_000_000
    except (AttributeError, OSError):
        return None


def boot_id() -> str | None:
    try:
        return Path("/proc/sys/kernel/random/boot_id").read_text(encoding="utf-8").strip() or None
    except OSError:
        return None


def sanitized_error(error: BaseException | str | None) -> str | None:
    """Keep only a bounded exception class, never an API/path/auth message."""
    if error is None:
        return None
    if isinstance(error, BaseException):
        return type(error).__name__[:80]
    return str(error).split(":", 1)[0][:80] or "ObservationError"


def snapshot(
    profile: str,
    project: str,
    instance_id: str,
    sequence: int,
    *,
    scan_interval_seconds: float,
    last_scan_at: str | None = None,
    last_scan_success_boottime_ms: int | None = None,
    last_result: dict[str, object] | None = None,
    error: BaseException | str | None = None,
) -> dict[str, object]:
    """Build the complete, secret-free schema-v1 observation value."""
    heartbeat = boottime_ms()
    clock_error = "ClockUnavailable" if heartbeat is None else None
    return {
        "schema_version": SCHEMA_VERSION,
        "profile": profile,
        "project": project,
        "pid": os.getpid(),
        "instance_id": instance_id,
        "boot_id": boot_id(),
        "clock_id": CLOCK_ID,
        "sequence": sequence,
        "heartbeat_boottime_ms": heartbeat,
        # UTC is display-only. Reader freshness never uses it.
        "heartbeat_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "last_scan_at": last_scan_at,
        "last_scan_success_boottime_ms": last_scan_success_boottime_ms,
        "scan_interval_seconds": scan_interval_seconds,
        "last_result": last_result or {"kind": "not_scanned"},
        "last_error": sanitized_error(error) or clock_error,
    }


def publish(path: Path, value: dict[str, object]) -> tuple[bool, str | None]:
    """Atomically replace *path*, retaining its previous value on failure.

    The caller carries the returned, sanitized error into the next successful
    heartbeat. This is the only possible durable report if replacement itself
    fails, and it intentionally never raises into Gatekeeper.
    """
    temporary: Path | None = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
        temporary.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")
        temporary.replace(path)
        return True, None
    except OSError as exc:
        return False, sanitized_error(exc)
    finally:
        if temporary is not None:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
