"""AsyncSelf dependency Gatekeeper event logic."""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from typing import Protocol

from .linear_client import LinearIssue
from . import start_gate


class GatekeeperClient(Protocol):
    def fetch_issue(self, issue_ref: str) -> LinearIssue: ...

    def fetch_successors(self, issue_ref: str) -> list[LinearIssue]: ...

    def update_issue_description(self, issue_id: str, description: str) -> None: ...

    def update_issue_state(self, issue_id: str, state_id: str) -> None: ...

    def set_issue_labels(self, issue_id: str, label_ids: list[str]) -> None: ...


@dataclass(frozen=True)
class GatekeeperConfig:
    todo_state_id: str
    waiting_state_id: str
    active_label_id: str | None = None
    active_label_name: str | None = None
    done_state_names: tuple[str, ...] = ("Done",)


@dataclass
class GatekeeperResult:
    event: str
    issue: str
    actions: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def action(self, text: str) -> None:
        self.actions.append(text)

    def warn(self, text: str) -> None:
        self.warnings.append(text)


class DependencyGatekeeper:
    def __init__(self, client: GatekeeperClient, config: GatekeeperConfig):
        self.client = client
        self.config = config

    def handle_done(self, issue_ref: str) -> GatekeeperResult:
        issue = self.client.fetch_issue(issue_ref)
        result = GatekeeperResult("done", issue.identifier)
        if normalize_state(issue.state) not in {normalize_state(name) for name in self.config.done_state_names}:
            result.action(f"{issue.identifier} is no longer Done; ignore stale event")
            return result
        successors = self.client.fetch_successors(issue.id)

        if not successors:
            result.action("no successors")
            return result

        for successor in successors:
            # The successor embedded in a relation can be stale by the time a
            # queued webhook is consumed.  Re-read before every mutation.
            successor = self.client.fetch_issue(successor.id)
            mark = start_gate.mark_dependency_checked(successor.description, issue.identifier)
            description = successor.description
            if mark.found and mark.changed:
                self.client.update_issue_description(successor.id, mark.text)
                description = mark.text
                result.action(f"marked {issue.identifier} in {successor.identifier}")
            elif mark.found:
                result.action(f"{issue.identifier} already marked in {successor.identifier}")
            else:
                result.warn(f"{successor.identifier} has no Start Gate item for {issue.identifier}")

            state = normalize_state(successor.state)
            if state == "needs info":
                result.action(f"{successor.identifier} is Needs Info; stop after marking dependency")
                continue
            if state == "waiting":
                refreshed = LinearIssue(
                    id=successor.id,
                    identifier=successor.identifier,
                    title=successor.title,
                    description=description,
                    state=successor.state,
                    labels=successor.labels,
                    label_ids=successor.label_ids,
                    blocked_by=successor.blocked_by,
                    url=successor.url,
                    previously_completed=successor.previously_completed,
                )
                self._promote_waiting_if_ready(refreshed, result)
                continue

            result.action(f"{successor.identifier} state {successor.state}; no-op")

        return result

    def handle_needs_info_updated(self, issue_ref: str) -> GatekeeperResult:
        issue = self.client.fetch_issue(issue_ref)
        result = GatekeeperResult("needs_info_updated", issue.identifier)
        if normalize_state(issue.state) != "needs info":
            result.action(f"{issue.identifier} state {issue.state}; ignore stale Needs Info event")
            return result
        if issue.previously_completed:
            result.action(f"{issue.identifier} was previously Done; skip automatic Needs Info -> Waiting")
            return result

        issue = self._mark_completed_blockers(issue, result)

        dependency_keys = tuple(_blocker_identifier(blocker) for blocker in issue.blocked_by)
        dependency_keys = tuple(key for key in dependency_keys if key)

        if start_gate.human_items_checked(issue.description, dependency_keys):
            self.client.update_issue_state(issue.id, self.config.waiting_state_id)
            result.action(f"moved {issue.identifier} to Waiting")
        else:
            result.action(f"{issue.identifier} still has incomplete Needs Info items")

        return result

    def handle_entered_waiting(self, issue_ref: str) -> GatekeeperResult:
        issue = self.client.fetch_issue(issue_ref)
        result = GatekeeperResult("entered_waiting", issue.identifier)
        if normalize_state(issue.state) != "waiting":
            result.action(f"{issue.identifier} state {issue.state}; ignore stale Waiting event")
            return result
        issue = self._mark_completed_blockers(issue, result)
        self._promote_waiting_if_ready(issue, result)
        return result

    def _mark_completed_blockers(self, issue: LinearIssue, result: GatekeeperResult) -> LinearIssue:
        description = issue.description
        done_names = {normalize_state(name) for name in self.config.done_state_names}
        for blocker in issue.blocked_by:
            if normalize_state(str(blocker.get("state") or "")) not in done_names:
                continue
            identifier = _blocker_identifier(blocker)
            if not identifier:
                result.warn(f"{issue.identifier} has a completed blocker without an identifier")
                continue
            mark = start_gate.mark_dependency_checked(description, identifier)
            if mark.found and mark.changed:
                description = mark.text
                result.action(f"marked {identifier} in {issue.identifier}")
            elif not mark.found:
                result.warn(f"{issue.identifier} has no Start Gate item for {identifier}")
        if description != issue.description:
            self.client.update_issue_description(issue.id, description)
            return replace(issue, description=description)
        return issue

    def _promote_waiting_if_ready(self, issue: LinearIssue, result: GatekeeperResult) -> None:
        if issue.previously_completed:
            result.action(f"{issue.identifier} was previously Done; skip automatic Waiting -> Todo")
            return

        blockers_done = self._blockers_done(issue)
        gates_done = start_gate.all_checkboxes_checked(issue.description)

        if blockers_done and gates_done:
            # Set the dispatch label first.  A label failure therefore cannot
            # leave an unlabelled Todo issue that AsyncSelf will never claim.
            self._ensure_active_label(issue, result)
            self.client.update_issue_state(issue.id, self.config.todo_state_id)
            result.action(f"moved {issue.identifier} to Todo")
            return

        if not blockers_done:
            result.action(f"{issue.identifier} blockers not all Done")
        if not gates_done:
            result.action(f"{issue.identifier} Start Gate not complete")

    def _ensure_active_label(self, issue: LinearIssue, result: GatekeeperResult) -> None:
        if not self.config.active_label_id:
            result.action("no active label configured")
            return
        if self.config.active_label_name and self.config.active_label_name in issue.labels:
            result.action(f"{issue.identifier} already has active label")
            return
        label_ids = list(dict.fromkeys([*issue.label_ids, self.config.active_label_id]))
        self.client.set_issue_labels(issue.id, label_ids)
        result.action(f"set active label on {issue.identifier}")

    def _blockers_done(self, issue: LinearIssue) -> bool:
        done_names = {normalize_state(name) for name in self.config.done_state_names}
        return all(normalize_state(str(blocker.get("state") or "")) in done_names for blocker in issue.blocked_by)


def normalize_state(state_name: str) -> str:
    return state_name.strip().lower()


def _blocker_identifier(blocker: dict[str, str | None]) -> str | None:
    value = blocker.get("identifier")
    return value.strip() if isinstance(value, str) and value.strip() else None
