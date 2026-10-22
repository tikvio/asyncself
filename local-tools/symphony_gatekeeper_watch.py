#!/usr/bin/env python3
"""Poll Linear and consume durable webhook hints for the dependency gatekeeper."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import sys
import threading
import time
from typing import Any
import uuid


DEFAULT_SYMPHONY_ROOT = Path(os.environ.get("ASYNCSELF_ROOT") or os.environ.get("SYMPHONY_ROOT", Path(__file__).resolve().parents[1]))
DEFAULT_PROFILE = os.environ.get("ASYNCSELF_PROFILE") or os.environ.get("SYMPHONY_PROFILE", "gitlab")
DEFAULT_RUNTIME_DIR = Path(os.environ.get(
    "SYMPHONY_RUNTIME_DIR", DEFAULT_SYMPHONY_ROOT / "local-config" / "runtime" / DEFAULT_PROFILE
))
DEFAULT_PIPELINE_ROOT = Path(os.environ.get(
    "SYMPHONY_GATEKEEPER_PIPELINE_ROOT", DEFAULT_SYMPHONY_ROOT / "local-tools" / "dependency_pipeline"
))
DEFAULT_STATE_FILE = DEFAULT_RUNTIME_DIR / "gatekeeper-state.json"
DEFAULT_LOCK_FILE = DEFAULT_RUNTIME_DIR / "gatekeeper.lock"
OBSERVATION_HEARTBEAT_SECONDS = 15.0
DEFAULT_PROJECT_SLUG_ID = ""
DEFAULT_ACTIVE_LABEL = ""
WATCHED_STATES = {"Done", "Needs Info", "Waiting"}
GITHUB_MERGE_STATE = "Merging"
GITHUB_WATCHED_STATES = WATCHED_STATES | {GITHUB_MERGE_STATE}


def load_pipeline(root: Path) -> None:
    if not root.exists():
        raise RuntimeError(f"pipeline root missing: {root}")
    sys.path.insert(0, str(root))


def load_state(path: Path) -> dict[str, dict[str, str]]:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"invalid Gatekeeper state file: {type(exc).__name__}") from exc
    if not isinstance(value, dict):
        raise RuntimeError("invalid Gatekeeper state file: expected object")
    return value


def save_state(path: Path, state: dict[str, dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(state, indent=2, ensure_ascii=False, sort_keys=True), encoding="utf-8")
    tmp.replace(path)


def publish_observation_safely(publish: Any, value: dict[str, object]) -> str | None:
    """Return a safe next-heartbeat error without ever disrupting a scan."""
    try:
        ok, write_error = publish(value)
        return None if ok else (str(write_error).split(":", 1)[0][:80] or "ObservationError")
    except Exception as exc:
        return type(exc).__name__[:80]


def project_issues(client: Any, project_id: str) -> list[dict[str, Any]]:
    query = """
        query GatekeeperProjectIssues($projectId: ID!, $after: String) {
          issues(
            first: 100,
            after: $after,
            filter: { project: { id: { eq: $projectId } } },
            orderBy: updatedAt
          ) {
            nodes {
              id identifier updatedAt state { name }
              labels { nodes { name id } }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
    """
    result: list[dict[str, Any]] = []
    after = None
    seen: set[str] = set()
    while True:
        data = client.graphql(query, {"projectId": project_id, "after": after})
        connection = data.get("issues") or {}
        result.extend(connection.get("nodes") or [])
        info = connection.get("pageInfo") or {}
        if not info.get("hasNextPage"):
            return result
        after = info.get("endCursor")
        if not after or str(after) in seen:
            raise RuntimeError("Linear project issue pagination cursor missing or repeated")
        after = str(after)
        seen.add(after)


def linear_issue_summary(client: Any, issue_ref: str) -> dict[str, Any]:
    data = client.graphql(
        """
        query GatekeeperIssue($issueRef: String!) {
          issue(id: $issueRef) {
            id identifier updatedAt state { name }
            project { id }
            labels { nodes { name id } }
          }
        }
        """,
        {"issueRef": issue_ref},
    )
    issue = data.get("issue")
    if not issue:
        raise RuntimeError(f"Linear issue not found: {issue_ref}")
    return issue


def issue_has_label(issue: dict[str, Any], label_name: str) -> bool:
    labels = (((issue.get("labels") or {}).get("nodes")) or [])
    return any(label.get("name") == label_name for label in labels)


def issue_state(issue: dict[str, Any]) -> str:
    return ((issue.get("state") or {}).get("name")) or ""


def should_process(
    issue: dict[str, Any],
    previous: dict[str, str] | None,
    *,
    process_existing: bool,
    watched_states: set[str] = WATCHED_STATES,
) -> bool:
    state = issue_state(issue)
    if state not in watched_states:
        return False
    if state in {"Needs Info", "Waiting", GITHUB_MERGE_STATE}:
        # These handlers are reconciliation-safe and repair missed Done events.
        return True
    if process_existing:
        return True
    if previous is None:
        return False
    return previous.get("state") != state or previous.get("updatedAt") != issue.get("updatedAt")


class EventResult:
    def __init__(self, event: str, issue: str, actions: list[str], warnings: list[str]):
        self.event = event
        self.issue = issue
        self.actions = actions
        self.warnings = warnings


def run_gatekeeper_event(gatekeeper: Any, issue: dict[str, Any], *,
                         github_merger: Any = None, dry_run: bool = False) -> Any:
    state = issue_state(issue)
    issue_id = issue["id"]
    if state == "Done":
        return gatekeeper.handle_done(issue_id)
    if state == "Needs Info":
        return gatekeeper.handle_needs_info_updated(issue_id)
    if state == "Waiting":
        return gatekeeper.handle_entered_waiting(issue_id)
    if state == GITHUB_MERGE_STATE:
        if github_merger is None:
            raise RuntimeError("GitHub merger is unavailable")
        result = github_merger.process_issue(gatekeeper.client, issue_id, dry_run=dry_run)
        return EventResult("github_merge", issue["identifier"], [result], [])
    raise RuntimeError(f"unsupported state: {state}")


def print_result(result: Any) -> None:
    print(f"event={result.event} issue={result.issue}", flush=True)
    for action in result.actions:
        print(f"action: {action}", flush=True)
    for warning in result.warnings:
        print(f"warning: {warning}", flush=True)


class DryRunClient:
    """Pass reads through and suppress all Linear writes."""

    def __init__(self, client: Any):
        self._client = client

    def __getattr__(self, name: str) -> Any:
        if name in {"update_issue_description", "update_issue_state", "set_issue_labels"}:
            return lambda *args, **kwargs: None
        return getattr(self._client, name)


def process_with_lock(gatekeeper: Any, issue: dict[str, Any], lock_file: Path, *,
                      github_merger: Any = None, dry_run: bool = False) -> Any:
    lock_file.parent.mkdir(parents=True, exist_ok=True)
    with lock_file.open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return run_gatekeeper_event(gatekeeper, issue, github_merger=github_merger, dry_run=dry_run)


def scan_once(
    client: Any,
    gatekeeper: Any,
    project_id: str,
    active_label: str,
    remembered: dict[str, dict[str, str]],
    *,
    process_existing: bool,
    issue_refs: list[str],
    lock_file: Path,
    github_merger: Any = None,
    dry_run: bool = False,
    watched_states: set[str] = WATCHED_STATES,
) -> int:
    if issue_refs:
        issues = [linear_issue_summary(client, ref) for ref in issue_refs]
    else:
        issues = project_issues(client, project_id)
    processed = 0
    for issue in issues:
        if (issue.get("project") or {}).get("id") not in {None, project_id}:
            continue
        state_name = issue_state(issue)
        if not issue_refs and state_name != "Done" and not issue_has_label(issue, active_label):
            continue
        current = {
            "identifier": issue["identifier"],
            "state": state_name,
            "updatedAt": issue.get("updatedAt") or "",
        }
        previous = remembered.get(issue["id"])
        if should_process(issue, previous, process_existing=process_existing,
                          watched_states=watched_states):
            print(f"processing {issue['identifier']} state={state_name} updatedAt={current['updatedAt']}", flush=True)
            result = process_with_lock(gatekeeper, issue, lock_file,
                                       github_merger=github_merger, dry_run=dry_run)
            print_result(result)
            processed += 1
        # Checkpoint only after successful processing (or an intentional skip).
        remembered[issue["id"]] = current
    return processed


def consume_one(inbox: Any, owner: str, client: Any, gatekeeper: Any, project_id: str,
                active_label: str, lock_file: Path, lease_seconds: float, *,
                github_merger: Any = None, dry_run: bool = False,
                watched_states: set[str] = WATCHED_STATES) -> bool:
    job = inbox.claim("gatekeeper", owner, lease_seconds=lease_seconds)
    if job is None:
        return False
    try:
        if job.resource.startswith("issue:"):
            issue = linear_issue_summary(client, job.resource.removeprefix("issue:"))
            if (issue.get("project") or {}).get("id") != project_id:
                result = "skipped_project"
            elif issue_state(issue) != "Done" and not issue_has_label(issue, active_label):
                result = "skipped_label"
            elif issue_state(issue) not in watched_states:
                result = "skipped_state"
            else:
                print_result(process_with_lock(gatekeeper, issue, lock_file,
                                               github_merger=github_merger, dry_run=dry_run))
                result = "processed"
        else:
            remembered: dict[str, dict[str, str]] = {}
            count = scan_once(client, gatekeeper, project_id, active_label, remembered,
                              process_existing=True, issue_refs=[], lock_file=lock_file,
                              github_merger=github_merger, dry_run=dry_run,
                              watched_states=watched_states)
            result = f"scan_{count}"
        if not inbox.complete(job):
            raise RuntimeError("Gatekeeper inbox completion lease lost")
        print(f"webhook job={job.id} resource={job.resource} result={result}", flush=True)
    except Exception as exc:
        delay = min(300.0, 5.0 * (2 ** min(job.attempts, 6)))
        inbox.fail(job, type(exc).__name__, delay_seconds=delay)
        print(f"webhook job={job.id} result=retry type={type(exc).__name__}", file=sys.stderr, flush=True)
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pipeline-root", default=str(DEFAULT_PIPELINE_ROOT))
    parser.add_argument("--project-slug-id", default=os.environ.get("ASYNCSELF_LINEAR_PROJECT_SLUG_ID") or os.environ.get("SYMPHONY_LINEAR_PROJECT_SLUG_ID", DEFAULT_PROJECT_SLUG_ID))
    parser.add_argument("--active-label", default=os.environ.get("ASYNCSELF_GATEKEEPER_ACTIVE_LABEL") or os.environ.get("SYMPHONY_GATEKEEPER_ACTIVE_LABEL", DEFAULT_ACTIVE_LABEL))
    parser.add_argument("--state-file", default=os.environ.get("SYMPHONY_GATEKEEPER_STATE_FILE", str(DEFAULT_STATE_FILE)))
    parser.add_argument("--lock-file", default=os.environ.get("SYMPHONY_GATEKEEPER_LOCK_FILE", str(DEFAULT_LOCK_FILE)))
    parser.add_argument("--config")
    parser.add_argument("--poll-seconds", type=float)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--max-loops", type=int)
    parser.add_argument("--process-existing", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--issue", action="append", default=[], help="Only process these issue ids or identifiers")
    args = parser.parse_args(argv)

    if not args.project_slug_id:
        parser.error("--project-slug-id or ASYNCSELF_LINEAR_PROJECT_SLUG_ID is required")
    if not args.active_label:
        parser.error("--active-label or ASYNCSELF_GATEKEEPER_ACTIVE_LABEL is required")

    load_pipeline(Path(args.pipeline_root))
    from symphony_dependency_pipeline.gatekeeper import DependencyGatekeeper, GatekeeperConfig
    from symphony_dependency_pipeline.linear_client import LinearClient
    from symphony_aux.config import load_config
    from symphony_aux.inbox import Inbox
    from symphony_gatekeeper_observation import (
        boottime_ms as observation_boottime_ms,
        publish as publish_observation,
        snapshot as observation_snapshot,
    )

    github_merger = None
    watched_states = WATCHED_STATES
    if DEFAULT_PROFILE == "github":
        import symphony_github_merger as github_merger
        watched_states = GITHUB_WATCHED_STATES

    config = load_config(args.config)
    poll_seconds = args.poll_seconds if args.poll_seconds is not None else config.poll_seconds
    raw_client = LinearClient.from_env()
    client = DryRunClient(raw_client) if args.dry_run else raw_client
    project = client.project(args.project_slug_id)
    todo_state_id = client.state_id(project["team_id"], "Todo")
    waiting_state_id = client.state_id(project["team_id"], "Waiting")
    active_label_id = client.label_id(project["team_id"], args.active_label) if args.active_label else None
    gatekeeper = DependencyGatekeeper(client, GatekeeperConfig(
        todo_state_id=todo_state_id,
        waiting_state_id=waiting_state_id,
        active_label_id=active_label_id,
        active_label_name=args.active_label,
    ))
    shadow_gatekeeper = DependencyGatekeeper(DryRunClient(raw_client), gatekeeper.config)

    inbox = Inbox(config.inbox_path)
    inbox.initialize()
    owner = "gatekeeper-" + uuid.uuid4().hex
    state_file = Path(args.state_file)
    remembered = load_state(state_file)
    lock_file = Path(args.lock_file)
    loops = 0
    next_poll = time.monotonic()
    observation_file = Path(os.environ.get("SYMPHONY_GATEKEEPER_OBSERVATION_FILE", str(DEFAULT_RUNTIME_DIR / "gatekeeper-observation.json")))
    observation_instance = uuid.uuid4().hex
    observation_lock = threading.Lock()
    observation = {
        "error": None,
        "last_scan_at": None,
        "last_scan_success_boottime_ms": None,
        "last_result": {"kind": "not_scanned"},
        "next_heartbeat": 0.0,
        "sequence": 0,
    }
    heartbeat_stop = threading.Event()

    def emit_observation(*, force: bool = False) -> None:
        """Best-effort telemetry only; this must never change scan semantics."""
        with observation_lock:
            if not force and time.monotonic() < observation["next_heartbeat"]:
                return
            observation["sequence"] += 1
            value = observation_snapshot(
                DEFAULT_PROFILE,
                args.project_slug_id,
                observation_instance,
                observation["sequence"],
                scan_interval_seconds=poll_seconds,
                last_scan_at=observation["last_scan_at"],
                last_scan_success_boottime_ms=observation["last_scan_success_boottime_ms"],
                last_result=observation["last_result"],
                error=observation["error"],
            )
            observation["error"] = publish_observation_safely(
                lambda value: publish_observation(observation_file, value), value
            )
            observation["next_heartbeat"] = time.monotonic() + OBSERVATION_HEARTBEAT_SECONDS

    def observation_heartbeat() -> None:
        while not heartbeat_stop.wait(OBSERVATION_HEARTBEAT_SECONDS):
            emit_observation(force=True)

    threading.Thread(target=observation_heartbeat, name="gatekeeper-observation", daemon=True).start()

    while True:
        loops += 1
        emit_observation()
        if config.webhook_enabled:
            for _ in range(100):
                if time.monotonic() >= next_poll:
                    break
                if not consume_one(inbox, owner, raw_client,
                                   shadow_gatekeeper if config.notification_dry_run else gatekeeper,
                                   project["project_id"], args.active_label, lock_file, config.lease_seconds,
                                   github_merger=github_merger,
                                   dry_run=config.notification_dry_run,
                                   watched_states=watched_states):
                    break
        if args.once or time.monotonic() >= next_poll:
            try:
                processed = scan_once(client, gatekeeper, project["project_id"], args.active_label, remembered,
                                      process_existing=args.process_existing, issue_refs=args.issue,
                                      lock_file=lock_file, github_merger=github_merger,
                                      dry_run=args.dry_run,
                                      watched_states=watched_states)
                save_state(state_file, remembered)
                print(f"poll complete processed={processed} watched={len(remembered)}", flush=True)
                with observation_lock:
                    observation["last_scan_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                    observation["last_scan_success_boottime_ms"] = observation_boottime_ms()
                    observation["last_result"] = {"kind": "scan_complete", "processed_count": processed}
                emit_observation(force=True)
            except Exception as exc:
                print(f"poll result=error type={type(exc).__name__}", file=sys.stderr, flush=True)
                with observation_lock:
                    observation["last_scan_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                    observation["last_result"] = {"kind": "scan_error", "error_type": type(exc).__name__[:80]}
                emit_observation(force=True)
                if args.once or args.issue:
                    raise
            next_poll = time.monotonic() + poll_seconds
        if args.once or (args.max_loops and loops >= args.max_loops):
            heartbeat_stop.set()
            return 0
        wait_seconds = min(poll_seconds, config.local_queue_check_seconds) if config.webhook_enabled else poll_seconds
        # The daemon heartbeat keeps its own 15-second cadence; retain the
        # Gatekeeper's existing sleep/poll and max-loop semantics unchanged.
        time.sleep(wait_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
