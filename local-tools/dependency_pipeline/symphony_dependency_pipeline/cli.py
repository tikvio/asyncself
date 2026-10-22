"""Command line entrypoint for AsyncSelf dependency pipeline."""

from __future__ import annotations

import argparse
from datetime import datetime
import os
from pathlib import Path
import re
import sys

from .applier import apply_plan
from .gatekeeper import DependencyGatekeeper, GatekeeperConfig
from .linear_client import DEFAULT_WORKFLOW_STATE_ORDER, LinearClient
from .planner import SpecError, parse_spec, write_preview


DEFAULT_SPEC_OUTPUT_ROOT = Path(
    os.environ.get(
        "ASYNCSELF_SPEC_OUTPUT_ROOT",
        str(Path.home() / ".local" / "state" / "asyncself" / "specs"),
    )
)
ENSURED_WORKFLOW_STATE_NAMES = ("Needs Info", "Waiting", "Rework")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="asyncself-pipeline")
    subparsers = parser.add_subparsers(dest="command", required=True)

    preview = subparsers.add_parser("preview", help="Generate DAG preview and plan JSON from a Markdown spec")
    preview.add_argument("spec")
    preview.add_argument("--out")

    apply = subparsers.add_parser("apply", help="Apply dag-plan.json to Linear in topological order")
    apply.add_argument("plan")
    apply.add_argument("--execute", action="store_true", help="Actually create/update Linear issues")
    apply.add_argument("--api-key-env", default="LINEAR_API_KEY")

    ensure = subparsers.add_parser("ensure-states", help="Ensure Linear dependency states exist and sync workflow order")
    ensure.add_argument("--project-slug", required=True)
    ensure.add_argument("--api-key-env", default="LINEAR_API_KEY")
    ensure.add_argument(
        "--order",
        default=",".join(DEFAULT_WORKFLOW_STATE_ORDER),
        help="Comma-separated Linear workflow state order prefix",
    )

    gate = subparsers.add_parser("gatekeeper", help="Run one Dependency Gatekeeper event")
    gate.add_argument("event", choices=["done", "needs-info-updated", "entered-waiting"])
    gate.add_argument("issue")
    gate.add_argument("--project-slug", required=True)
    gate.add_argument("--active-label")
    gate.add_argument("--api-key-env", default="LINEAR_API_KEY")

    args = parser.parse_args(argv)

    try:
        if args.command == "preview":
            spec = parse_spec(args.spec)
            output_dir = Path(args.out) if args.out else default_preview_output_dir(spec)
            preview_path, plan_path = write_preview(spec, output_dir)
            print(f"preview: {preview_path}")
            print(f"plan: {plan_path}")
            return 0

        if args.command == "apply":
            client = LinearClient.from_env(args.api_key_env) if args.execute else None
            results = apply_plan(args.plan, client, execute=args.execute)
            for result in results:
                suffix = f" {result.identifier}" if result.identifier else ""
                detail = f" - {result.details}" if result.details else ""
                print(f"{result.node_id}: {result.action}{suffix}{detail}")
            if not args.execute:
                print("dry-run only; pass --execute to create/update Linear issues")
            return 0

        if args.command == "ensure-states":
            client = LinearClient.from_env(args.api_key_env)
            project = client.project(args.project_slug)
            for name in ENSURED_WORKFLOW_STATE_NAMES:
                state_id = client.ensure_workflow_state(project["team_id"], name)
                print(f"{name}: {state_id}")
            ordered_names = parse_state_order(args.order)
            changed = client.sync_workflow_state_order(project["team_id"], ordered_names)
            if changed:
                for state in changed:
                    print(f"ordered {state.name}: position={state.position:g}")
            else:
                print("workflow order: already correct")
            return 0

        if args.command == "gatekeeper":
            client = LinearClient.from_env(args.api_key_env)
            project = client.project(args.project_slug)
            todo_state_id = client.state_id(project["team_id"], "Todo")
            waiting_state_id = client.ensure_workflow_state(project["team_id"], "Waiting")
            active_label_id = client.label_id(project["team_id"], args.active_label) if args.active_label else None
            gatekeeper = DependencyGatekeeper(
                client,
                GatekeeperConfig(
                    todo_state_id=todo_state_id,
                    waiting_state_id=waiting_state_id,
                    active_label_id=active_label_id,
                    active_label_name=args.active_label,
                ),
            )
            if args.event == "done":
                result = gatekeeper.handle_done(args.issue)
            elif args.event == "needs-info-updated":
                result = gatekeeper.handle_needs_info_updated(args.issue)
            else:
                result = gatekeeper.handle_entered_waiting(args.issue)

            print(f"event={result.event} issue={result.issue}")
            for action in result.actions:
                print(f"action: {action}")
            for warning in result.warnings:
                print(f"warning: {warning}")
            return 0

    except (SpecError, RuntimeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    return 1


def default_preview_output_dir(spec) -> Path:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    title_slug = slugify(spec.title)
    return DEFAULT_SPEC_OUTPUT_ROOT / f"{timestamp}-{title_slug}"


def slugify(text: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", text.strip().lower()).strip("-")
    return slug or "spec"


def parse_state_order(value: str) -> tuple[str, ...]:
    names = tuple(name.strip() for name in value.split(",") if name.strip())
    return names or DEFAULT_WORKFLOW_STATE_ORDER


if __name__ == "__main__":
    raise SystemExit(main())

