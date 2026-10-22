#!/usr/bin/env python3
"""Deterministic GitLab MR merge and Linear Done reconciliation for AsyncSelf."""

from __future__ import annotations

import argparse
from contextlib import ExitStack
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import time
from typing import Any
from urllib import error, parse, request
import uuid

SYMPHONY_ROOT = Path(os.environ.get("ASYNCSELF_ROOT") or os.environ.get("SYMPHONY_ROOT", Path(__file__).resolve().parents[1]))
PIPELINE_ROOT = Path(os.environ.get(
    "ASYNCSELF_GATEKEEPER_PIPELINE_ROOT"
    ) or os.environ.get(
    "SYMPHONY_GATEKEEPER_PIPELINE_ROOT", SYMPHONY_ROOT / "local-tools" / "dependency_pipeline"
))
LOCK_ROOT = Path(os.environ.get(
    "ASYNCSELF_MR_WATCHER_LOCK_ROOT"
    ) or os.environ.get(
    "SYMPHONY_MR_WATCHER_LOCK_ROOT", SYMPHONY_ROOT / "local-config" / "runtime" / "gitlab" / "mr-watcher-locks"
))
GITLAB_HOST = (os.environ.get("ASYNCSELF_GITLAB_HOST") or os.environ.get("SYMPHONY_GITLAB_HOST", "https://gitlab.com")).rstrip("/")
PROJECT = os.environ.get("ASYNCSELF_GITLAB_PROJECT") or os.environ.get("SYMPHONY_GITLAB_PROJECT", "")
PROJECT_SLUG = os.environ.get("ASYNCSELF_LINEAR_PROJECT_SLUG") or os.environ.get("SYMPHONY_LINEAR_PROJECT_SLUG", "")
LABEL = os.environ.get("ASYNCSELF_GATEKEEPER_ACTIVE_LABEL") or os.environ.get("SYMPHONY_GATEKEEPER_ACTIVE_LABEL", "")
WATCH_STATES = {"In Review", "Merging"}


def _client():
    sys.path.insert(0, str(PIPELINE_ROOT))
    from symphony_dependency_pipeline.linear_client import LinearClient
    return LinearClient.from_env()


def gitlab(path: str, *, method: str = "GET", payload: dict | None = None) -> dict | list:
    token = os.environ.get("GITLAB_TOKEN")
    if not token:
        raise RuntimeError("GITLAB_TOKEN is missing")
    host = GITLAB_HOST
    parsed_host = parse.urlsplit(host)
    if parsed_host.scheme != "https" or not parsed_host.netloc or parsed_host.path not in {"", "/"}:
        raise RuntimeError("ASYNCSELF_GITLAB_HOST must be an HTTPS origin without a path")
    body = None if payload is None else json.dumps(payload).encode()
    req = request.Request(host + "/api/v4/" + path, data=body, method=method,
                          headers={"PRIVATE-TOKEN": token, "Content-Type": "application/json"})
    with request.urlopen(req, timeout=30) as res:
        content = res.read()
    return json.loads(content) if content else {}


def project_path() -> str:
    if not PROJECT:
        raise RuntimeError("ASYNCSELF_GITLAB_PROJECT is missing")
    return "projects/" + parse.quote(PROJECT, safe="")


def gitlab_collection(path: str) -> list[dict]:
    result: list[dict] = []
    for page in range(1, 1001):
        separator = "&" if "?" in path else "?"
        value = gitlab(f"{path}{separator}per_page=100&page={page}")
        if not isinstance(value, list):
            raise RuntimeError("GitLab collection response was not a list")
        result.extend(value)
        if len(value) < 100:
            return result
    raise RuntimeError("GitLab collection pagination exceeded safety limit")


def linear_issue(client: Any, issue_ref: str) -> dict:
    query = """query($id: String!) {
      issue(id: $id) {
        id identifier title description state { name } project { id }
        labels { nodes { name } }
        comments(first: 100) { nodes { id body } pageInfo { hasNextPage endCursor } }
        attachments(first: 100) { nodes { id url } pageInfo { hasNextPage endCursor } }
      }
    }"""
    issue = client.graphql(query, {"id": issue_ref}).get("issue")
    if not issue:
        raise RuntimeError("Linear issue not found")
    for name, fields in (("comments", "id body"), ("attachments", "id url")):
        connection = issue.get(name) or {"nodes": []}
        nodes = list(connection.get("nodes") or [])
        seen: set[str] = set()
        while (connection.get("pageInfo") or {}).get("hasNextPage"):
            after = (connection.get("pageInfo") or {}).get("endCursor")
            if not after or str(after) in seen:
                raise RuntimeError(f"Linear {name} pagination cursor missing or repeated")
            after = str(after)
            seen.add(after)
            page_query = f"""query($id: String!, $after: String) {{
              issue(id: $id) {{
                {name}(first: 100, after: $after) {{
                  nodes {{ {fields} }} pageInfo {{ hasNextPage endCursor }}
                }}
              }}
            }}"""
            page_issue = client.graphql(page_query, {"id": issue_ref, "after": after}).get("issue") or {}
            connection = page_issue.get(name) or {}
            nodes.extend(connection.get("nodes") or [])
        issue[name] = {"nodes": nodes, "pageInfo": connection.get("pageInfo") or {}}
    return issue


def project_candidates(client: Any) -> list[dict]:
    project = client.project(PROJECT_SLUG)
    query = """query($projectId: ID!, $after: String) {
      issues(first: 100, after: $after,
        filter: {project: {id: {eq: $projectId}}, state: {name: {in: ["In Review", "Merging"]}}}) {
        nodes { id identifier state { name } labels { nodes { name } } }
        pageInfo { hasNextPage endCursor }
      }
    }"""
    result, after = [], None
    seen: set[str] = set()
    while True:
        page = client.graphql(query, {"projectId": project["project_id"], "after": after})["issues"]
        result.extend(page.get("nodes") or [])
        info = page.get("pageInfo") or {}
        if not info.get("hasNextPage"):
            return result
        after = info.get("endCursor")
        if not after or str(after) in seen:
            raise RuntimeError("Linear pagination cursor missing or repeated")
        after = str(after)
        seen.add(after)


def linked_mr_iid(issue: dict) -> int | None:
    if not PROJECT:
        raise RuntimeError("ASYNCSELF_GITLAB_PROJECT is missing")
    mr_re = re.compile(
        rf"{re.escape(GITLAB_HOST)}/{re.escape(PROJECT)}/-/merge_requests/(\d+)(?:\b|/)"
    )
    texts = [issue.get("description") or ""]
    texts += [node.get("body") or "" for node in issue.get("comments", {}).get("nodes", [])]
    texts += [node.get("url") or "" for node in issue.get("attachments", {}).get("nodes", [])]
    ids = {int(match) for text in texts for match in mr_re.findall(text)}
    if len(ids) > 1:
        raise RuntimeError("Multiple GitLab MRs linked; select one explicitly")
    return next(iter(ids)) if ids else None


def expected_target(issue: dict) -> str | None:
    description = issue.get("description") or ""
    match = re.search(
        r"(?im)^\s*(?:(?:MR\s+)?Target(?:\s+Branch)?|目标分支)\s*:\s*`?([A-Za-z0-9_./-]+)",
        description,
    )
    return match.group(1) if match else None


def pipeline_ready(mr: dict, pipelines: list[dict], *, require_pipeline: bool = False) -> tuple[bool, str]:
    sha = mr.get("sha")
    relevant = [p for p in pipelines if p.get("sha") == sha]
    if not relevant:
        return (False, "pipeline_absent") if require_pipeline else (True, "no_pipeline_configured")
    latest = max(relevant, key=lambda p: int(p.get("id") or 0))
    status = latest.get("status")
    return (status == "success", "pipeline_" + str(status))


def explicit_approval(approvals: dict) -> bool:
    return bool(approvals.get("approved_by")) and approvals.get("approvals_left", 0) == 0


def write_done(client: Any, issue: dict) -> str:
    current = linear_issue(client, issue["id"])
    state = current["state"]["name"]
    if state == "Done":
        return "already_done"
    if state not in WATCH_STATES:
        return "blocked_linear_state_changed"
    project = client.project(PROJECT_SLUG)
    state_id = client.state_id(project["team_id"], "Done")
    client.update_issue_state(current["id"], state_id)
    verified = linear_issue(client, current["id"])
    if verified["state"]["name"] != "Done":
        raise RuntimeError("Linear Done update was not confirmed")
    return "done"


def process_issue_data(client: Any, issue: dict, *, dry_run: bool = False,
                       allowed_targets: tuple[str, ...] | None = None,
                       require_pipeline: bool = False) -> str:
    if issue.get("project", {}).get("id") != client.project(PROJECT_SLUG)["project_id"]:
        return "skipped_project"
    state = issue["state"]["name"]
    if state not in WATCH_STATES:
        return "skipped_state"
    if LABEL not in [n["name"] for n in issue["labels"]["nodes"]]:
        return "skipped_label"
    iid = linked_mr_iid(issue)
    if iid is None:
        return "blocked_missing_mr"
    target = expected_target(issue)
    if target is None:
        return "blocked_missing_target"
    if allowed_targets is not None and target not in allowed_targets:
        return "blocked_target_not_allowed"
    path = project_path() + f"/merge_requests/{iid}"
    mr = gitlab(path)
    if mr.get("target_branch") != target:
        return "blocked_target_mismatch"
    if mr.get("state") == "merged":
        return "already_merged_dry_run" if dry_run else write_done(client, issue)
    if state == "In Review":
        return "waiting_review_or_human_merge"
    if mr.get("state") != "opened":
        return "blocked_mr_not_open"
    approvals = gitlab(path + "/approvals")
    if not explicit_approval(approvals):
        return "blocked_not_approved"
    ready, pipeline = pipeline_ready(mr, gitlab_collection(path + "/pipelines"),
                                     require_pipeline=require_pipeline)
    if not ready:
        return "waiting_" + pipeline
    if mr.get("detailed_merge_status") not in {"mergeable", "can_be_merged"}:
        return "blocked_" + str(mr.get("detailed_merge_status"))
    if dry_run:
        return "ready_to_merge_dry_run"
    try:
        gitlab(path + "/merge", method="PUT", payload={"sha": mr["sha"], "should_remove_source_branch": False})
    except error.HTTPError as exc:
        if exc.code not in {405, 409}:
            raise
    for _ in range(6):
        confirmed = gitlab(path)
        if confirmed.get("state") == "merged":
            return write_done(client, issue)
        time.sleep(2)
    return "blocked_merge_unconfirmed"


def process_issue(client: Any, issue_ref: str, *, dry_run: bool = False,
                  allowed_targets: tuple[str, ...] | None = None,
                  require_pipeline: bool = False) -> str:
    return process_issue_data(client, linear_issue(client, issue_ref), dry_run=dry_run,
                              allowed_targets=allowed_targets, require_pipeline=require_pipeline)


def process_locked(client: Any, issue: dict, *, dry_run: bool,
                   allowed_targets: tuple[str, ...] | None = None,
                   require_pipeline: bool = False) -> str:
    LOCK_ROOT.mkdir(parents=True, exist_ok=True)
    full_issue = linear_issue(client, issue["id"])
    iid = linked_mr_iid(full_issue)
    names = ["issue-" + full_issue["identifier"]]
    if iid is not None:
        names.append(f"mr-{iid}")
    with ExitStack() as stack:
        for name in sorted(names):
            lock = stack.enter_context((LOCK_ROOT / (name + ".lock")).open("w"))
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return "skipped_locked"
        return process_issue_data(client, full_issue, dry_run=dry_run,
                                  allowed_targets=allowed_targets, require_pipeline=require_pipeline)


def bind_candidate(inbox: Any, client: Any, summary: dict) -> None:
    issue = linear_issue(client, summary["id"])
    iid = linked_mr_iid(issue)
    if iid is not None:
        inbox.bind_mr(iid, issue["id"])


def prepare_candidates(inbox: Any, client: Any, candidates: list[dict]) -> list[tuple[dict, bool]]:
    """Resolve all links before writing so a shared MR blocks every mapped issue."""
    full: list[dict] = []
    iids: dict[str, int] = {}
    for candidate in candidates:
        issue = candidate if "description" in candidate else linear_issue(client, candidate["id"])
        full.append(issue)
        iid = linked_mr_iid(issue)
        if iid is not None:
            iids[issue["id"]] = iid
            inbox.bind_mr(iid, issue["id"])
    return [(issue, issue["id"] in iids and len(inbox.issues_for_mr(iids[issue["id"]])) > 1)
            for issue in full]


def candidates_for_job(inbox: Any, client: Any, resource: str) -> list[dict]:
    if resource.startswith("issue:"):
        return [linear_issue(client, resource.removeprefix("issue:"))]
    if resource.startswith("mr:"):
        iid = int(resource.removeprefix("mr:"))
        ids = inbox.issues_for_mr(iid)
        if ids:
            return [linear_issue(client, issue_id) for issue_id in ids]
        candidates = project_candidates(client)
        matches = []
        for summary in candidates:
            issue = linear_issue(client, summary["id"])
            linked = linked_mr_iid(issue)
            if linked is not None:
                inbox.bind_mr(linked, issue["id"])
            if linked == iid:
                matches.append(issue)
        return matches
    return project_candidates(client)


def consume_one(inbox: Any, owner: str, client: Any, *, dry_run: bool,
                allowed_targets: tuple[str, ...], require_pipeline: bool,
                lease_seconds: float) -> bool:
    job = inbox.claim("mr", owner, lease_seconds=lease_seconds)
    if job is None:
        return False
    try:
        candidates = prepare_candidates(inbox, client, candidates_for_job(inbox, client, job.resource))
        results = []
        for issue, shared_mr in candidates:
            result = "blocked_shared_mr" if shared_mr else process_locked(
                client, issue, dry_run=dry_run, allowed_targets=allowed_targets,
                require_pipeline=require_pipeline)
            results.append(result)
        if not inbox.complete(job):
            raise RuntimeError("MR inbox completion lease lost")
        print(f"webhook job={job.id} resource={job.resource} results={','.join(results) or 'no_match'}", flush=True)
    except Exception as exc:
        delay = min(300.0, 5.0 * (2 ** min(job.attempts, 6)))
        inbox.fail(job, type(exc).__name__, delay_seconds=delay)
        print(f"webhook job={job.id} result=retry type={type(exc).__name__}", file=sys.stderr, flush=True)
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--issue", help="Only check this issue identifier or ID")
    parser.add_argument("--poll-seconds", type=float)
    parser.add_argument("--config")
    args = parser.parse_args(argv)
    from symphony_aux.config import load_config
    from symphony_aux.inbox import Inbox

    config = load_config(args.config)
    poll_seconds = args.poll_seconds if args.poll_seconds is not None else config.poll_seconds
    require_pipeline = config.pipeline_policy == "require_success"
    client = _client()
    inbox = Inbox(config.inbox_path)
    inbox.initialize()
    owner = "mr-" + uuid.uuid4().hex
    previous: dict[str, str] = {}
    next_poll = time.monotonic()
    while True:
        if config.webhook_enabled:
            for _ in range(100):
                if time.monotonic() >= next_poll:
                    break
                if not consume_one(inbox, owner, client,
                                   dry_run=args.dry_run or config.notification_dry_run,
                                   allowed_targets=config.allowed_target_branches,
                                   require_pipeline=require_pipeline, lease_seconds=config.lease_seconds):
                    break
        if args.once or time.monotonic() >= next_poll:
            try:
                summaries = [linear_issue(client, args.issue)] if args.issue else project_candidates(client)
                candidates = prepare_candidates(inbox, client, summaries)
                for issue, shared_mr in candidates:
                    result = "blocked_shared_mr" if shared_mr else process_locked(
                        client, issue, dry_run=args.dry_run,
                        allowed_targets=config.allowed_target_branches,
                        require_pipeline=require_pipeline)
                    if previous.get(issue["id"]) != result or args.once:
                        print(f"issue={issue['identifier']} result={result}", flush=True)
                    previous[issue["id"]] = result
            except Exception as exc:
                print(f"poll result=error type={type(exc).__name__}", file=sys.stderr, flush=True)
                if args.once or args.issue:
                    raise
            next_poll = time.monotonic() + poll_seconds
        if args.once:
            return 0
        time.sleep(min(poll_seconds, config.local_queue_check_seconds) if config.webhook_enabled else poll_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
