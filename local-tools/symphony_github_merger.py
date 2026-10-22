#!/usr/bin/env python3
"""Deterministic GitHub PR merge handler invoked by the AsyncSelf Gatekeeper."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import time
from typing import Any


SYMPHONY_ROOT = Path(os.environ.get("ASYNCSELF_ROOT") or os.environ.get("SYMPHONY_ROOT", Path(__file__).resolve().parents[1]))
PROJECT_SLUG = os.environ.get("ASYNCSELF_LINEAR_PROJECT_SLUG") or os.environ.get("SYMPHONY_LINEAR_PROJECT_SLUG", "")
LABEL = os.environ.get("ASYNCSELF_GATEKEEPER_ACTIVE_LABEL") or os.environ.get("SYMPHONY_GATEKEEPER_ACTIVE_LABEL", "")
EXPECTED_REPOSITORY = os.environ.get("ASYNCSELF_GITHUB_REPOSITORY") or os.environ.get("SYMPHONY_GITHUB_REPOSITORY", "")
EXPECTED_TARGET = os.environ.get("ASYNCSELF_TARGET_BRANCH") or os.environ.get("SYMPHONY_TARGET_BRANCH", "")
REQUIRED_CHECK = os.environ.get("ASYNCSELF_GITHUB_REQUIRED_CHECK") or os.environ.get("SYMPHONY_GITHUB_REQUIRED_CHECK", "build")
WATCH_STATE = "Merging"
PR_RE = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/(\d+)(?:\b|/)")


def gh_json(args: list[str]) -> Any:
    completed = subprocess.run(["gh", *args], text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        raise RuntimeError(f"GitHub CLI request failed: {' '.join(args[:2])}")
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("GitHub CLI returned invalid JSON") from exc


def gh_run(args: list[str]) -> None:
    completed = subprocess.run(["gh", *args], text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        raise RuntimeError(f"GitHub CLI command failed: {' '.join(args[:2])}")


def linear_issue(client: Any, issue_ref: str) -> dict[str, Any]:
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


def linked_pr(issue: dict[str, Any]) -> tuple[str, int] | None:
    texts = [issue.get("description") or ""]
    texts += [node.get("body") or "" for node in issue.get("comments", {}).get("nodes", [])]
    texts += [node.get("url") or "" for node in issue.get("attachments", {}).get("nodes", [])]
    matches = {(f"{owner}/{repo}".lower(), int(number))
               for text in texts for owner, repo, number in PR_RE.findall(text)}
    if len(matches) > 1:
        raise RuntimeError("Multiple GitHub PRs linked; select one explicitly")
    return next(iter(matches)) if matches else None


def pull_request(repository: str, number: int) -> dict[str, Any]:
    fields = (
        "number,title,body,state,isDraft,mergeable,mergeStateStatus,baseRefName,"
        "headRefName,headRefOid,statusCheckRollup,url"
    )
    return gh_json(["pr", "view", str(number), "--repo", repository, "--json", fields])


def unresolved_review_threads(repository: str, number: int) -> int:
    owner, name = repository.split("/", 1)
    query = """
      query($owner: String!, $name: String!, $number: Int!, $after: String) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            reviewThreads(first: 100, after: $after) {
              nodes { isResolved }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
      }
    """
    unresolved = 0
    after: str | None = None
    seen: set[str] = set()
    while True:
        args = ["api", "graphql", "-f", f"query={query}", "-F", f"owner={owner}",
                "-F", f"name={name}", "-F", f"number={number}"]
        if after is not None:
            args += ["-F", f"after={after}"]
        data = gh_json(args)
        connection = (((data.get("data") or {}).get("repository") or {})
                      .get("pullRequest") or {}).get("reviewThreads") or {}
        unresolved += sum(1 for node in connection.get("nodes") or [] if not node.get("isResolved"))
        page = connection.get("pageInfo") or {}
        if not page.get("hasNextPage"):
            return unresolved
        cursor = page.get("endCursor")
        if not cursor or str(cursor) in seen:
            raise RuntimeError("GitHub review thread pagination cursor missing or repeated")
        after = str(cursor)
        seen.add(after)


def required_check_status(pr: dict[str, Any]) -> str:
    checks = [item for item in pr.get("statusCheckRollup") or []
              if (item.get("name") or item.get("context")) == REQUIRED_CHECK]
    if not checks:
        return "absent"
    for check in checks:
        if check.get("__typename") == "CheckRun":
            if check.get("status") != "COMPLETED":
                return "pending"
            if check.get("conclusion") != "SUCCESS":
                return "failed"
        elif check.get("state") != "SUCCESS":
            return "pending" if check.get("state") in {"EXPECTED", "PENDING"} else "failed"
    return "success"


def write_done(client: Any, issue: dict[str, Any]) -> str:
    current = linear_issue(client, issue["id"])
    state = current["state"]["name"]
    if state == "Done":
        return "already_done"
    if state != WATCH_STATE:
        return "blocked_linear_state_changed"
    project = client.project(PROJECT_SLUG)
    done_state_id = client.state_id(project["team_id"], "Done")
    client.update_issue_state(current["id"], done_state_id)
    verified = linear_issue(client, current["id"])
    if verified["state"]["name"] != "Done":
        raise RuntimeError("Linear Done update was not confirmed")
    return "done"


def process_issue_data(client: Any, issue: dict[str, Any], *, dry_run: bool = False) -> str:
    project = client.project(PROJECT_SLUG)
    if (issue.get("project") or {}).get("id") != project["project_id"]:
        return "skipped_project"
    if (issue.get("state") or {}).get("name") != WATCH_STATE:
        return "skipped_state"
    if LABEL not in [node.get("name") for node in (issue.get("labels") or {}).get("nodes", [])]:
        return "skipped_label"
    if not EXPECTED_REPOSITORY or not EXPECTED_TARGET or EXPECTED_TARGET == "main":
        return "blocked_invalid_configuration"
    link = linked_pr(issue)
    if link is None:
        return "blocked_missing_pr"
    repository, number = link
    if repository != EXPECTED_REPOSITORY.lower():
        return "blocked_repository_mismatch"
    pr = pull_request(repository, number)
    if pr.get("baseRefName") != EXPECTED_TARGET:
        return "blocked_target_mismatch"
    issue_id = re.escape(issue["identifier"])
    if not re.search(rf"(?i)\b{issue_id}\b", pr.get("title") or ""):
        return "blocked_issue_id_missing_from_title"
    fixes = re.compile(rf"(?i)\bfixes\s+{issue_id}\b")
    if not fixes.search(pr.get("body") or ""):
        return "blocked_fixes_missing_from_body"
    if pr.get("state") == "MERGED":
        return "already_merged_dry_run" if dry_run else write_done(client, issue)
    if pr.get("state") != "OPEN":
        return "blocked_pr_not_open"
    if pr.get("isDraft"):
        return "blocked_pr_is_draft"
    check = required_check_status(pr)
    if check != "success":
        return ("waiting_required_check_" if check in {"absent", "pending"}
                else "blocked_required_check_") + check
    if pr.get("mergeable") != "MERGEABLE":
        return "waiting_mergeable" if pr.get("mergeable") == "UNKNOWN" else "blocked_conflict"
    if unresolved_review_threads(repository, number):
        return "blocked_unresolved_review_threads"
    if dry_run:
        return "ready_to_merge_dry_run"
    head_oid = pr.get("headRefOid")
    if not head_oid:
        return "blocked_missing_head_oid"
    gh_run(["pr", "merge", str(number), "--repo", repository, "--squash",
            "--match-head-commit", head_oid])
    for _ in range(6):
        confirmed = pull_request(repository, number)
        if confirmed.get("state") == "MERGED":
            return write_done(client, issue)
        time.sleep(2)
    return "blocked_merge_unconfirmed"


def process_issue(client: Any, issue_ref: str, *, dry_run: bool = False) -> str:
    return process_issue_data(client, linear_issue(client, issue_ref), dry_run=dry_run)
