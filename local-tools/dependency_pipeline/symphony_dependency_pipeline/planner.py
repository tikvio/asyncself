"""Spec Planner parser, DAG validator, and preview generator."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import json
import re
from pathlib import Path
from typing import Iterable

from . import start_gate


TASK_HEADING_RE = re.compile(r"^###\s+(?P<node>[A-Za-z][A-Za-z0-9_-]*)\s+(?P<title>.+?)\s*$")
FIELD_RE = re.compile(r"^(?P<name>[A-Za-z][A-Za-z ]+|[\u4e00-\u9fff]+)\s*[:：]\s*(?P<value>.*)$")
CHECKBOX_RE = re.compile(r"^\s*[-*]\s+\[( |x|X)\]\s+.+$")


@dataclass(frozen=True)
class TaskSpec:
    node_id: str
    title: str
    depends_on: tuple[str, ...]
    labels: tuple[str, ...]
    base_branch: str | None
    delivery: str
    review: str
    review_url: str | None
    merging_action: str
    start_gate: tuple[str, ...]
    initial: str
    slug: str | None
    body: str


@dataclass(frozen=True)
class PipelineSpec:
    title: str
    project_slug: str | None
    active_label: str | None
    linear_labels: tuple[str, ...]
    workflow: str | None
    local_source_repo: str | None
    workspace: str | None
    scm_provider: str | None
    scm_project: str | None
    forbidden_paths: tuple[str, ...]
    branch_strategy: str
    target_branch: str | None
    integration_branch: str | None
    final_merge: str | None
    tasks: tuple[TaskSpec, ...]
    topo_order: tuple[str, ...]


class SpecError(ValueError):
    """Raised when a spec cannot be parsed or validated."""


def parse_spec(path: str | Path) -> PipelineSpec:
    spec_path = Path(path)
    text = spec_path.read_text(encoding="utf-8")
    title = _first_title(text) or spec_path.stem
    project_slug = _top_field(text, "Project Slug", "项目")
    active_label = _top_field(text, "Active Label", "Active 标签", "标签")
    agent_profile_label = _top_field(text, "Agent Profile Label", "Profile Label", "AI Label")
    linear_labels = _resolve_top_labels(_top_field(text, "Linear Labels", "Linear 标签"), active_label, agent_profile_label)
    workflow = _top_field(text, "Workflow", "Workflow Path", "工作流")
    local_source_repo = _top_field(text, "Local Source Repo", "Local Repo", "Source Repo", "本地仓库")
    workspace = _top_field(text, "Workspace", "工作区")
    github_project = _top_field(text, "GitHub Project")
    gitlab_project = _top_field(text, "GitLab Project", "GitLab Remote")
    scm_provider = _normalize_scm_provider(_top_field(text, "SCM Provider"), github_project, gitlab_project)
    scm_project = _top_field(text, "SCM Project", "Remote Project", "远程仓库") or github_project or gitlab_project
    forbidden_paths = _parse_list(_top_field(text, "Forbidden Paths", "Forbidden Path", "禁止路径"))
    branch_strategy = _normalize_branch_strategy(_top_field(text, "Branch Strategy", "分支策略"))
    target_branch = _top_field(text, "Target Branch", "目标分支")
    integration_branch = _top_field(text, "Integration Branch", "集成分支")
    final_merge = _top_field(text, "Final Merge", "最终合并")
    default_delivery = "pr" if scm_provider == "github" else "mr"
    tasks = tuple(_parse_tasks(text, linear_labels, default_delivery))

    if not tasks:
        raise SpecError("No tasks found. Add tasks under '## Tasks' with headings like '### T1 Title'.")

    topo_order = tuple(topological_sort(tasks))
    spec = PipelineSpec(
        title,
        project_slug,
        active_label,
        linear_labels,
        workflow,
        local_source_repo,
        workspace,
        scm_provider,
        scm_project,
        forbidden_paths,
        branch_strategy,
        target_branch,
        integration_branch,
        final_merge,
        tasks,
        topo_order,
    )
    _validate_spec(spec)
    return spec


def write_preview(spec: PipelineSpec, output_dir: str | Path) -> tuple[Path, Path]:
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    preview_path = out / "dag-preview.md"
    graph_path = out / "preview-graph.md"
    plan_path = out / "dag-plan.json"
    specs_dir = out / "specs"
    specs_dir.mkdir(parents=True, exist_ok=True)

    preview_path.write_text(render_preview(spec), encoding="utf-8")
    graph_path.write_text(render_preview_graph(spec), encoding="utf-8")
    plan_path.write_text(json.dumps(_plan_dict(spec), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for task in spec.tasks:
        (specs_dir / task_spec_filename(task)).write_text(render_node_spec(spec, task), encoding="utf-8")
    return preview_path, plan_path


def render_preview_graph(spec: PipelineSpec) -> str:
    lines = [
        f"# DAG graph: {spec.title}",
        "",
        "```mermaid",
        "flowchart TD",
    ]
    manual_node_ids = [task.node_id for task in spec.tasks if requires_human_input(task)]
    for task in spec.tasks:
        marker = " [human input]" if requires_human_input(task) else ""
        lines.append(f'  {task.node_id}["{task.node_id} {task.title}{marker}"]')
    for task in spec.tasks:
        for dep in task.depends_on:
            lines.append(f"  {dep} --> {task.node_id}")
    if manual_node_ids:
        lines.append("  classDef manualInput fill:#fff4ce,stroke:#b7791f,stroke-width:2px,color:#1f2937;")
        lines.append(f"  class {','.join(manual_node_ids)} manualInput;")
    lines.extend(
        [
            "```",
            "",
            f"- Branch Strategy: `{spec.branch_strategy}` ({_branch_strategy_label(spec.branch_strategy)})",
            f"- Target Branch: `{spec.target_branch or ''}`",
            f"- Integration Branch: `{spec.integration_branch or ''}`",
        ]
    )
    return "\n".join(lines).rstrip() + "\n"


def render_preview(spec: PipelineSpec) -> str:
    lines = [
        f"# DAG preview: {spec.title}",
        "",
        "## Metadata",
        "",
        f"- Project Slug: `{spec.project_slug or ''}`",
        f"- Active Label: `{spec.active_label or ''}`",
        f"- Linear Labels: `{', '.join(spec.linear_labels)}`",
        "",
        "## Execution scope",
        "",
        f"- Workflow: `{spec.workflow or ''}`",
        f"- Local Source Repo: `{spec.local_source_repo or ''}`",
        f"- Workspace: `{spec.workspace or ''}`",
        f"- SCM Provider: `{spec.scm_provider or ''}`",
        f"- SCM Project: `{spec.scm_project or ''}`",
        f"- Forbidden Paths: `{', '.join(spec.forbidden_paths)}`",
        "",
        "## Branch plan",
        "",
        f"- Branch Strategy: `{spec.branch_strategy}` ({_branch_strategy_label(spec.branch_strategy)})",
        f"- Target Branch: `{spec.target_branch or ''}`",
        f"- Integration Branch: `{spec.integration_branch or ''}`",
        f"- Final Merge: `{spec.final_merge or ''}`",
        "",
        "## DAG graph",
        "",
        "```mermaid",
        "flowchart TD",
    ]

    task_map = {task.node_id: task for task in spec.tasks}
    manual_node_ids = [task.node_id for task in spec.tasks if requires_human_input(task)]
    for task in spec.tasks:
        marker = " [human input]" if requires_human_input(task) else ""
        lines.append(f'  {task.node_id}["{task.node_id} {task.title}{marker}"]')
    for task in spec.tasks:
        for dep in task.depends_on:
            lines.append(f"  {dep} --> {task.node_id}")
    if manual_node_ids:
        lines.append("  classDef manualInput fill:#fff4ce,stroke:#b7791f,stroke-width:2px,color:#1f2937;")
        lines.append(f"  class {','.join(manual_node_ids)} manualInput;")
    lines.extend(
        [
            "```",
            "",
            "`[human input]` marks a node that starts in `Needs Info` until its Start Gate is completed.",
            f"Branch Strategy: `{spec.branch_strategy}` ({_branch_strategy_label(spec.branch_strategy)}).",
            "",
            "## Task table",
            "",
            "| Node | Title | Depends on | Initial state | Marker | Base branch | Delivery | Review | Merge action | Labels | Branch template | Spec file |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|",
        ]
    )

    for task in spec.tasks:
        branch_template = f"feature/asyncself/{{issue-key}}-{task_slug(task)}"
        depends_on = ", ".join(task.depends_on) if task.depends_on else "none"
        initial = resolve_initial_state(task)
        marker = "human input" if requires_human_input(task) else "-"
        labels = ", ".join(task.labels) if task.labels else "-"
        base_branch = task.base_branch or "target default"
        spec_file = f"specs/{task_spec_filename(task)}"
        lines.append(
            f"| `{task.node_id}` | {task.title} | {depends_on} | `{initial}` | {marker} | `{base_branch}` | `{task.delivery}` | `{task.review}` | `{task.merging_action}` | {labels} | `{branch_template}` | `{spec_file}` |"
        )

    lines.extend(["", "## Linear creation order", "", "```text", " -> ".join(spec.topo_order), "```", "", "## Task details", ""])

    for node_id in spec.topo_order:
        task = task_map[node_id]
        lines.extend(
            [
                f"### {task.node_id} {task.title}",
                "",
                f"- Standalone spec: `specs/{task_spec_filename(task)}`",
                f"- Depends on: {', '.join(task.depends_on) if task.depends_on else 'none'}",
                f"- Initial state: {resolve_initial_state(task)}",
                f"- Marker: {'human input' if requires_human_input(task) else '-'}",
                f"- Labels: {', '.join(task.labels) if task.labels else '-'}",
                f"- Base Branch: {task.base_branch or 'target default'}",
                f"- Delivery: {task.delivery}",
                f"- Review: {task.review}",
                f"- Review URL: {task.review_url or 'fill when available'}",
                f"- Merging Action: {task.merging_action}",
                f"- Branch Template: feature/asyncself/{{issue-key}}-{task_slug(task)}",
                "",
                "#### Start Gate",
                "",
            ]
        )
        for dep in task.depends_on:
            dep_task = task_map[dep]
            lines.append(start_gate.dependency_checkbox(dep, dep_task.title))
        for item in task.start_gate:
            lines.append(start_gate.ensure_human_checkbox_marker(item))
        if not task.depends_on and not task.start_gate:
            lines.append("- [x] No prerequisites")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def render_node_spec(spec: PipelineSpec, task: TaskSpec) -> str:
    branch_template = f"feature/asyncself/{{issue-key}}-{task_slug(task)}"
    lines = [
        f"# {task.node_id} {task.title}",
        "",
        "## Background",
        "",
        f"- DAG: {spec.title}",
        f"- Branch Strategy: `{spec.branch_strategy}` ({_branch_strategy_label(spec.branch_strategy)})",
        f"- Target Branch: `{spec.target_branch or ''}`",
        f"- Integration Branch: `{spec.integration_branch or ''}`",
        "",
        "## Goal",
        "",
        f"- Complete the `{task.title}` DAG node and satisfy this spec's acceptance criteria.",
        "",
        "## Inputs and dependencies",
        "",
        f"- Depends on: {', '.join(task.depends_on) if task.depends_on else 'none'}",
        f"- Initial State: `{resolve_initial_state(task)}`",
        f"- Labels: {', '.join(task.labels) if task.labels else '-'}",
        "",
        "## Branch plan",
        "",
        f"- Base Branch: `{task.base_branch or 'target default'}`",
        f"- Review Target Branch: `{resolved_review_target_branch(spec, task) or 'n/a'}`",
        f"- Created Branch Template: `{branch_template}`",
        f"- Delivery: `{task.delivery}`",
        f"- Review: `{task.review}`",
        f"- Review URL: `{task.review_url or 'fill when available'}`",
        f"- Merging Action: `{task.merging_action}`",
        "",
        "## Start Gate",
        "",
    ]
    if task.depends_on:
        for dep in task.depends_on:
            lines.append(start_gate.dependency_checkbox(dep))
    for item in task.start_gate:
        lines.append(start_gate.ensure_human_checkbox_marker(item))
    if not task.depends_on and not task.start_gate:
        lines.append("- [x] No prerequisites")

    lines.extend(
        [
            "",
            "## Acceptance criteria and task notes",
            "",
            task.body or "- No additional notes; follow the DAG preview and Start Gate.",
            "",
            "## Constraints",
            "",
            f"- Forbidden paths: {', '.join(spec.forbidden_paths) if spec.forbidden_paths else '-'}",
            "- Do not create branches, labels, or merge actions that are absent from the approved preview.",
            "",
            "## Linear write-back",
            "",
            "- Write back the review URL, branch details, verification results, or blocking reason according to the Delivery/Review contract.",
        ]
    )
    return "\n".join(lines).rstrip() + "\n"


def task_spec_filename(task: TaskSpec) -> str:
    return f"{task.node_id}-{task_slug(task)}.md"


def topological_sort(tasks: Iterable[TaskSpec]) -> list[str]:
    task_list = list(tasks)
    task_ids = [task.node_id for task in task_list]
    task_set = set(task_ids)

    for task in task_list:
        unknown = [dep for dep in task.depends_on if dep not in task_set]
        if unknown:
            raise SpecError(f"{task.node_id} depends on unknown node(s): {', '.join(unknown)}")

    incoming = {task.node_id: set(task.depends_on) for task in task_list}
    outgoing = {task.node_id: set() for task in task_list}
    for task in task_list:
        for dep in task.depends_on:
            outgoing[dep].add(task.node_id)

    ready = [node_id for node_id in task_ids if not incoming[node_id]]
    result: list[str] = []

    while ready:
        node_id = ready.pop(0)
        result.append(node_id)
        for child in sorted(outgoing[node_id], key=task_ids.index):
            incoming[child].remove(node_id)
            if not incoming[child]:
                ready.append(child)

    if len(result) != len(task_ids):
        remaining = [node_id for node_id in task_ids if node_id not in result]
        raise SpecError(f"Cycle detected around: {', '.join(remaining)}")

    return result


def resolve_initial_state(task: TaskSpec) -> str:
    explicit = _normalize_state(task.initial)
    if explicit != "auto":
        return explicit
    if any(_unchecked_checkbox(item) for item in task.start_gate):
        return "Needs Info"
    if task.depends_on:
        return "Waiting"
    return "Todo"


def resolved_review_target_branch(spec: PipelineSpec, task: TaskSpec) -> str | None:
    if task.delivery not in {"pr", "mr"}:
        return None
    return spec.integration_branch or task.base_branch or spec.target_branch


def _validate_spec(spec: PipelineSpec) -> None:
    if spec.branch_strategy == "integration-branch" and not spec.integration_branch:
        raise SpecError("Branch Strategy: integration-branch requires Integration Branch.")

    for task in spec.tasks:
        if task.delivery in {"pr", "mr"}:
            expected_review = "pull-request" if task.delivery == "pr" else "merge-request"
            expected_action = "land-pr" if task.delivery == "pr" else "land-mr"
            if task.review != expected_review:
                raise SpecError(
                    f"{task.node_id} uses Delivery: {task.delivery} but Review is {task.review}; "
                    f"use Review: {expected_review}."
                )
            if task.merging_action != expected_action:
                raise SpecError(
                    f"{task.node_id} uses Delivery: {task.delivery} but Merging Action is {task.merging_action}; "
                    f"use Merging Action: {expected_action}."
                )
            if spec.branch_strategy == "integration-branch":
                expected = spec.integration_branch
                if task.base_branch != expected:
                    actual = task.base_branch or "target default"
                    raise SpecError(
                        f"{task.node_id} uses Delivery: {task.delivery} in integration-branch mode; "
                        f"Base Branch must be the Integration Branch {expected}, got {actual}."
                    )
                if resolved_review_target_branch(spec, task) != expected:
                    raise SpecError(
                        f"{task.node_id} must resolve its review target to Integration Branch {expected} "
                        "in integration-branch mode."
                    )

        if task.delivery not in {"pr", "mr"} or task.merging_action == "mark-done":
            if not _has_no_merge_reason(task.body):
                raise SpecError(
                    f"{task.node_id} uses Delivery: {task.delivery} with Merging Action: {task.merging_action}; "
                    "add an explicit No Merge Reason, Mark Done Reason, or exception note."
                )


def requires_human_input(task: TaskSpec) -> bool:
    return resolve_initial_state(task) == "Needs Info"


def task_slug(task: TaskSpec) -> str:
    if task.slug:
        return task.slug
    text = task.title.strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    return text or task.node_id.lower()


def _parse_tasks(text: str, default_labels: tuple[str, ...], default_delivery: str) -> list[TaskSpec]:
    lines = text.splitlines()
    tasks_start = _section_start(lines, "Tasks", "任务")
    if tasks_start is None:
        return []

    tasks: list[TaskSpec] = []
    index = tasks_start + 1
    while index < len(lines):
        match = TASK_HEADING_RE.match(lines[index])
        if not match:
            index += 1
            continue

        node_id = match.group("node")
        title = match.group("title").strip()
        block_start = index + 1
        block_end = len(lines)
        for cursor in range(block_start, len(lines)):
            if TASK_HEADING_RE.match(lines[cursor]):
                block_end = cursor
                break

        tasks.append(_parse_task_block(node_id, title, lines[block_start:block_end], default_labels, default_delivery))
        index = block_end

    duplicate_ids = sorted({task.node_id for task in tasks if [t.node_id for t in tasks].count(task.node_id) > 1})
    if duplicate_ids:
        raise SpecError(f"Duplicate task node id(s): {', '.join(duplicate_ids)}")

    return tasks


def _parse_task_block(
    node_id: str,
    title: str,
    lines: list[str],
    default_labels: tuple[str, ...],
    default_delivery: str,
) -> TaskSpec:
    depends_on: tuple[str, ...] = ()
    labels: tuple[str, ...] = default_labels
    base_branch: str | None = None
    delivery = default_delivery
    review: str | None = None
    review_url: str | None = None
    merging_action: str | None = None
    initial = "auto"
    slug: str | None = None
    body_lines: list[str] = []
    gate_lines: list[str] = []
    in_gate = False

    for line in lines:
        stripped = line.strip()
        field = FIELD_RE.match(stripped)

        if field and _field_name(field.group("name")) in {"depends on", "depends", "依赖"}:
            depends_on = _parse_depends(field.group("value"))
            in_gate = False
            continue
        if field and _field_name(field.group("name")) in {"labels", "linear labels", "标签"}:
            labels = _parse_labels(field.group("value"))
            in_gate = False
            continue
        if field and _field_name(field.group("name")) in {"base branch", "source branch", "基准分支", "来源分支"}:
            base_branch = field.group("value").strip() or None
            in_gate = False
            continue
        if field and _field_name(field.group("name")) in {"delivery", "delivery mode", "交付", "交付模式"}:
            delivery = field.group("value").strip() or default_delivery
            in_gate = False
            continue
        if field and _field_name(field.group("name")) in {"review", "review type", "评审", "评审方式"}:
            review = field.group("value").strip() or None
            in_gate = False
            continue
        if field and _field_name(field.group("name")) in {"review url", "review link", "评审地址", "评审链接"}:
            review_url = field.group("value").strip() or None
            in_gate = False
            continue
        if field and _field_name(field.group("name")) in {"merging action", "merge action", "合并动作"}:
            merging_action = field.group("value").strip() or None
            in_gate = False
            continue
        if field and _field_name(field.group("name")) in {"initial", "state", "初始状态", "状态"}:
            initial = field.group("value").strip() or "auto"
            in_gate = False
            continue
        if field and _field_name(field.group("name")) == "slug":
            slug = field.group("value").strip() or None
            in_gate = False
            continue
        if field and _field_name(field.group("name")) in {"start gate", "开始门禁", "前置条件"}:
            in_gate = True
            continue
        if in_gate and CHECKBOX_RE.match(stripped):
            gate_lines.append(stripped)
            continue
        if in_gate and stripped == "":
            continue
        if in_gate and field:
            in_gate = False

        if stripped:
            body_lines.append(line)

    delivery = _normalize_delivery(delivery)
    review = _normalize_review(review, delivery)
    merging_action = _normalize_merging_action(merging_action, delivery)

    return TaskSpec(
        node_id,
        title,
        depends_on,
        labels,
        base_branch,
        delivery,
        review,
        review_url,
        merging_action,
        tuple(gate_lines),
        initial,
        slug,
        "\n".join(body_lines).strip(),
    )


def _parse_depends(value: str) -> tuple[str, ...]:
    value = value.strip()
    if value.lower() in {"", "none", "no", "n/a", "无"}:
        return ()
    return tuple(part.strip() for part in re.split(r"[,，、\s]+", value) if part.strip())


def _parse_labels(value: str | None) -> tuple[str, ...]:
    if not value:
        return ()
    return _dedupe(part.strip() for part in re.split(r"[,，;；]+", value) if part.strip())


def _parse_list(value: str | None) -> tuple[str, ...]:
    if not value:
        return ()
    return _dedupe(part.strip() for part in re.split(r"[,，;；]+", value) if part.strip())


def _resolve_top_labels(
    linear_labels_value: str | None,
    active_label: str | None,
    agent_profile_label: str | None,
) -> tuple[str, ...]:
    explicit_labels = _parse_labels(linear_labels_value)
    if explicit_labels:
        return explicit_labels
    return _dedupe(label for label in [active_label, agent_profile_label] if label)


def _dedupe(values: Iterable[str]) -> tuple[str, ...]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        key = value.strip().lower()
        if not key or key in seen:
            continue
        seen.add(key)
        result.append(value.strip())
    return tuple(result)


def _first_title(text: str) -> str | None:
    for line in text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return None


def _top_field(text: str, *names: str) -> str | None:
    name_set = {_field_name(name) for name in names}
    for line in text.splitlines():
        match = FIELD_RE.match(line.strip())
        if match and _field_name(match.group("name")) in name_set:
            return match.group("value").strip() or None
    return None


def _section_start(lines: list[str], *names: str) -> int | None:
    normalized = {_field_name(name) for name in names}
    for index, line in enumerate(lines):
        if not line.startswith("## "):
            continue
        title = _field_name(line[3:].strip())
        if title in normalized:
            return index
    return None


def _field_name(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip().lower())


def _unchecked_checkbox(line: str) -> bool:
    match = CHECKBOX_RE.match(line)
    return bool(match and match.group(1) == " ")


def _normalize_state(value: str) -> str:
    normalized = value.strip().lower().replace("_", " ").replace("-", " ")
    states = {
        "auto": "auto",
        "needs info": "Needs Info",
        "need info": "Needs Info",
        "waiting": "Waiting",
        "todo": "Todo",
    }
    return states.get(normalized, value.strip() or "auto")


def _normalize_delivery(value: str) -> str:
    normalized = value.strip().lower().replace("_", "-").replace(" ", "-")
    deliveries = {
        "": "mr",
        "mr": "mr",
        "merge-request": "mr",
        "pr": "pr",
        "pull-request": "pr",
        "branch-diff": "branch-diff",
        "branch-artifact": "branch-diff",
        "branch-only": "branch-diff",
        "no-code": "no-code",
        "nocode": "no-code",
        "aggregate-mr": "aggregate-mr",
    }
    return deliveries.get(normalized, value.strip() or "mr")


def _normalize_branch_strategy(value: str | None) -> str:
    normalized = (value or "").strip().lower().replace("_", "-").replace(" ", "-")
    strategies = {
        "": "independent-branches",
        "independent": "independent-branches",
        "independent-branch": "independent-branches",
        "independent-branches": "independent-branches",
        "per-issue": "independent-branches",
        "per-issue-branches": "independent-branches",
        "integration": "integration-branch",
        "integration-branch": "integration-branch",
        "staging": "integration-branch",
        "staging-branch": "integration-branch",
    }
    return strategies.get(normalized, value.strip() if value else "independent-branches")


def _branch_strategy_label(value: str) -> str:
    names = {
        "independent-branches": "one branch per issue",
        "integration-branch": "shared integration branch",
    }
    return names.get(value, value)


def _has_no_merge_reason(body: str) -> bool:
    compact = re.sub(r"\s+", "", body.lower())
    markers = (
        "nomergereason",
        "nomrreason",
        "markdonereason",
        "no-merge",
        "mark-done",
        "exception",
        "例外",
        "不创建mr",
        "不需要mr",
        "不合并",
        "不把",
        "只准备分支",
        "终端总结",
        "清理",
    )
    return any(marker in compact for marker in markers)


def _normalize_review(value: str | None, delivery: str) -> str:
    if value is None or value.strip() == "":
        defaults = {
            "pr": "pull-request",
            "mr": "merge-request",
            "branch-diff": "branch-diff",
            "no-code": "none",
        }
        return defaults.get(delivery, "merge-request")

    normalized = value.strip().lower().replace("_", "-").replace(" ", "-")
    reviews = {
        "mr": "merge-request",
        "merge-request": "merge-request",
        "pr": "pull-request",
        "pull-request": "pull-request",
        "branch-diff": "branch-diff",
        "compare": "branch-diff",
        "none": "none",
        "no-code": "none",
    }
    return reviews.get(normalized, value.strip())


def _normalize_merging_action(value: str | None, delivery: str) -> str:
    if value is None or value.strip() == "":
        if delivery in {"branch-diff", "no-code"}:
            return "mark-done"
        if delivery == "pr":
            return "land-pr"
        return "land-mr"

    normalized = value.strip().lower().replace("_", "-").replace(" ", "-")
    actions = {
        "land": "land-mr",
        "land-mr": "land-mr",
        "land-pr": "land-pr",
        "merge": "land-mr",
        "mark-done": "mark-done",
        "done": "mark-done",
    }
    return actions.get(normalized, value.strip())


def _normalize_scm_provider(
    value: str | None,
    github_project: str | None,
    gitlab_project: str | None,
) -> str | None:
    normalized = (value or "").strip().lower()
    if normalized in {"github", "gitlab"}:
        return normalized
    if github_project:
        return "github"
    if gitlab_project:
        return "gitlab"
    return normalized or None


def _plan_dict(spec: PipelineSpec) -> dict:
    data = asdict(spec)
    data["tasks"] = [asdict(task) for task in spec.tasks]
    return data

