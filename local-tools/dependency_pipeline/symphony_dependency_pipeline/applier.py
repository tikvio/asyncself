"""Apply a generated DAG plan to Linear in topological order."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
from typing import Any

from .linear_client import LinearClient, CreatedIssue
from .planner import task_slug
from . import start_gate


@dataclass(frozen=True)
class ApplyResult:
    node_id: str
    action: str
    identifier: str | None = None
    details: str | None = None


def apply_plan(
    plan_path: str | Path,
    client: LinearClient | None,
    *,
    execute: bool = False,
) -> list[ApplyResult]:
    plan = json.loads(Path(plan_path).read_text(encoding="utf-8"))
    project_slug = plan.get("project_slug")
    active_label = plan.get("active_label")
    plan_labels = label_names(plan.get("linear_labels") or ([active_label] if active_label else []))
    topo_order: list[str] = plan["topo_order"]
    tasks = {task["node_id"]: task for task in plan["tasks"]}

    if not project_slug:
        raise RuntimeError("Plan is missing project_slug")

    if not execute:
        return _dry_run_results(tasks, topo_order, plan_labels)

    if client is None:
        raise RuntimeError("Linear client is required when execute=True")

    project = client.project(project_slug)
    team_id = project["team_id"]
    project_id = project["project_id"]
    state_ids = {
        "Todo": client.state_id(team_id, "Todo"),
        "Waiting": client.ensure_workflow_state(team_id, "Waiting"),
        "Needs Info": client.ensure_workflow_state(team_id, "Needs Info"),
    }
    all_label_names = sorted(
        {
            label
            for task in tasks.values()
            for label in task_label_names(task, plan_labels)
        }
    )
    label_ids_by_name = {label: client.label_id(team_id, label) for label in all_label_names}

    created: dict[str, CreatedIssue] = {}
    results: list[ApplyResult] = []

    for node_id in topo_order:
        task = tasks[node_id]
        initial = task_initial(task)
        branch_name = f"feature/asyncself/pending-{_task_slug(task)}"
        description = render_description(task, created, branch_name, plan)
        labels = task_label_names(task, plan_labels)
        label_ids = [label_ids_by_name[label] for label in labels]

        issue = client.create_issue(
            team_id=team_id,
            project_id=project_id,
            title=task["title"],
            description=description,
            state_id=state_ids.get(initial),
            label_ids=label_ids,
        )
        created[node_id] = issue
        results.append(ApplyResult(node_id, "created", issue.identifier, issue.url))

        final_branch = f"feature/asyncself/{issue.identifier}-{_task_slug(task)}"
        final_description = render_description(task, created, final_branch, plan)
        client.update_issue_description(issue.id, final_description)
        results.append(ApplyResult(node_id, "finalized", issue.identifier, final_branch))

        for dep in task.get("depends_on", []):
            client.create_blocked_by(issue.id, created[dep].id)
            results.append(ApplyResult(node_id, "blocked-by", issue.identifier, created[dep].identifier))

    return results


def render_description(
    task: dict[str, Any],
    created: dict[str, CreatedIssue],
    branch_name: str,
    plan: dict[str, Any] | None = None,
) -> str:
    plan = plan or {}
    delivery = task.get("delivery") or "mr"
    lines = [
        f"Branch: {branch_name}",
    ]
    if plan.get("branch_strategy"):
        lines.append(f"Branch Strategy: {plan['branch_strategy']}")
    if plan.get("integration_branch"):
        lines.append(f"Integration Branch: {plan['integration_branch']}")
    if plan.get("final_merge"):
        lines.append(f"Final Merge: {plan['final_merge']}")
    if task.get("base_branch"):
        lines.append(f"Base Branch: {task['base_branch']}")
    if delivery in {"pr", "mr"}:
        review_target_branch = plan.get("integration_branch") or task.get("base_branch") or plan.get("target_branch")
        if review_target_branch:
            lines.append(f"Review Target Branch: {review_target_branch}")
    lines.extend(
        [
            f"Delivery: {delivery}",
            f"Review: {task.get('review') or ('pull-request' if delivery == 'pr' else 'merge-request')}",
            f"Review URL: {task.get('review_url') or 'fill when available'}",
            f"Merging Action: {task.get('merging_action') or ('land-pr' if delivery == 'pr' else 'land-mr')}",
            "",
            "## Start Gate",
        ]
    )

    for dep in task.get("depends_on", []):
        dep_issue = created.get(dep)
        dep_label = dep_issue.identifier if dep_issue else dep
        lines.append(start_gate.dependency_checkbox(dep_label))

    for item in task.get("start_gate", []):
        lines.append(start_gate.ensure_human_checkbox_marker(item))

    if not task.get("depends_on") and not task.get("start_gate"):
        lines.append("- [x] No prerequisites")

    body = task.get("body") or ""
    if body:
        lines.extend(["", "## Notes", body])

    return "\n".join(lines).rstrip() + "\n"


def task_initial(task: dict[str, Any]) -> str:
    initial = str(task.get("initial") or "auto").strip().lower().replace("_", " ").replace("-", " ")
    if initial in {"todo", "waiting", "needs info"}:
        return {"todo": "Todo", "waiting": "Waiting", "needs info": "Needs Info"}[initial]
    if any(_unchecked(item) for item in task.get("start_gate", [])):
        return "Needs Info"
    if task.get("depends_on"):
        return "Waiting"
    return "Todo"


def _dry_run_results(
    tasks: dict[str, dict[str, Any]],
    topo_order: list[str],
    plan_labels: tuple[str, ...],
) -> list[ApplyResult]:
    results: list[ApplyResult] = []
    for node_id in topo_order:
        task = tasks[node_id]
        labels = task_label_names(task, plan_labels)
        results.append(
            ApplyResult(
                node_id=node_id,
                action="would-create",
                identifier=None,
                details=(
                    f"{task['title']} initial={task_initial(task)} "
                    f"depends_on={','.join(task.get('depends_on', [])) or 'none'} "
                    f"labels={','.join(labels) or 'none'}"
                ),
            )
        )
    return results


def task_label_names(task: dict[str, Any], plan_labels: tuple[str, ...]) -> tuple[str, ...]:
    return label_names(task.get("labels") or plan_labels)


def label_names(labels: Any) -> tuple[str, ...]:
    if labels is None:
        return ()
    if isinstance(labels, str):
        raw_labels = labels.split(",")
    else:
        raw_labels = labels

    result: list[str] = []
    seen: set[str] = set()
    for label in raw_labels:
        value = str(label).strip()
        key = value.lower()
        if not value or key in seen:
            continue
        seen.add(key)
        result.append(value)
    return tuple(result)


def _task_slug(task: dict[str, Any]) -> str:
    if task.get("slug"):
        return task["slug"]

    class _Task:
        title = task["title"]
        node_id = task["node_id"]
        slug = None

    return task_slug(_Task())


def _unchecked(item: str) -> bool:
    return "[ ]" in item

