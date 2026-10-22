"""Small Linear GraphQL client for AsyncSelf dependency operations."""

from __future__ import annotations

from dataclasses import dataclass, field
import json
import os
from typing import Any
from urllib import request, error


LINEAR_ENDPOINT = "https://api.linear.app/graphql"
DEFAULT_WORKFLOW_STATE_ORDER = ("Needs Info", "Waiting", "Todo", "Rework", "In Progress", "In Review", "Merging")
WORKFLOW_STATE_POSITION_STEP = 1000
WORKFLOW_STATE_NAME_ALIASES = {
    "need info": "needs info",
}
RESERVED_WORKFLOW_STATE_NAMES = {
    "backlog",
    "todo",
    "in progress",
    "done",
    "canceled",
    "cancelled",
    "duplicate",
}
WORKFLOW_STATE_COLORS = {
    "Needs Info": "#F2C94C",
    "Waiting": "#A3AAB8",
    "Rework": "#EB5757",
}
DEFAULT_WORKFLOW_STATE_COLOR = "#6B7280"


@dataclass(frozen=True)
class LinearIssue:
    id: str
    identifier: str
    title: str
    description: str
    state: str
    labels: tuple[str, ...] = ()
    label_ids: tuple[str, ...] = ()
    blocked_by: tuple[dict[str, str | None], ...] = ()
    url: str | None = None
    previously_completed: bool = False


@dataclass(frozen=True)
class CreatedIssue:
    id: str
    identifier: str
    url: str | None = None


@dataclass(frozen=True)
class WorkflowState:
    id: str
    name: str
    type: str | None = None
    position: float | None = None


@dataclass
class LinearClient:
    api_key: str
    endpoint: str = LINEAR_ENDPOINT

    @classmethod
    def from_env(cls, env_name: str = "LINEAR_API_KEY") -> "LinearClient":
        api_key = os.environ.get(env_name)
        if not api_key:
            raise RuntimeError(f"Missing {env_name}")
        return cls(api_key=api_key)

    def graphql(self, query: str, variables: dict[str, Any] | None = None) -> dict[str, Any]:
        body = json.dumps({"query": query, "variables": variables or {}}).encode("utf-8")
        req = request.Request(
            self.endpoint,
            data=body,
            headers={
                "Authorization": self.api_key,
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with request.urlopen(req, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Linear HTTP {exc.code}: {detail[:1000]}") from exc

        if payload.get("errors"):
            raise RuntimeError(f"Linear GraphQL error: {payload['errors']}")
        return payload.get("data") or {}

    def project(self, project_slug: str) -> dict[str, str]:
        data = self.graphql(
            """
            query AsyncSelfProject($projectSlug: String!) {
              projects(filter: {slugId: {eq: $projectSlug}}, first: 1) {
                nodes {
                  id
                  name
                  teams {
                    nodes {
                      id
                      key
                      name
                    }
                  }
                }
              }
            }
            """,
            {"projectSlug": project_slug},
        )
        node = _first_node(data, "projects")
        if not node:
            raise RuntimeError(f"Linear project not found: {project_slug}")
        team = ((((node.get("teams") or {}).get("nodes")) or [{}])[0]) or {}
        return {
            "project_id": node["id"],
            "project_name": node.get("name") or "",
            "team_id": team.get("id") or "",
            "team_key": team.get("key") or "",
        }

    def state_id(self, team_id: str, state_name: str) -> str:
        data = self.graphql(
            """
            query AsyncSelfState($teamId: String!, $stateName: String!) {
              team(id: $teamId) {
                states(filter: {name: {eq: $stateName}}, first: 1) {
                  nodes { id name }
                }
              }
            }
            """,
            {"teamId": team_id, "stateName": state_name},
        )
        node = (((data.get("team") or {}).get("states") or {}).get("nodes") or [None])[0]
        if not node:
            raise RuntimeError(f"Linear state not found: {state_name}")
        return node["id"]

    def workflow_states(self, team_id: str) -> list[WorkflowState]:
        data = self.graphql(
            """
            query AsyncSelfWorkflowStates($teamId: String!) {
              team(id: $teamId) {
                states {
                  nodes {
                    id
                    name
                    type
                    position
                  }
                }
              }
            }
            """,
            {"teamId": team_id},
        )
        nodes = (((data.get("team") or {}).get("states") or {}).get("nodes")) or []
        return [_workflow_state_from_node(node) for node in nodes]

    def label_id(self, team_id: str, label_name: str) -> str:
        data = self.graphql(
            """
            query AsyncSelfLabel($teamId: ID!, $labelName: String!) {
              issueLabels(filter: {team: {id: {eq: $teamId}}, name: {eq: $labelName}}, first: 1) {
                nodes { id name }
              }
            }
            """,
            {"teamId": team_id, "labelName": label_name},
        )
        node = _first_node(data, "issueLabels")
        if not node:
            raise RuntimeError(f"Linear label not found: {label_name}")
        return node["id"]

    def create_issue(
        self,
        *,
        team_id: str,
        project_id: str,
        title: str,
        description: str,
        state_id: str | None = None,
        label_ids: list[str] | None = None,
    ) -> CreatedIssue:
        input_data: dict[str, Any] = {
            "teamId": team_id,
            "projectId": project_id,
            "title": title,
            "description": description,
        }
        if state_id:
            input_data["stateId"] = state_id
        if label_ids:
            input_data["labelIds"] = label_ids

        data = self.graphql(
            """
            mutation AsyncSelfCreateIssue($input: IssueCreateInput!) {
              issueCreate(input: $input) {
                success
                issue { id identifier url }
              }
            }
            """,
            {"input": input_data},
        )
        payload = data.get("issueCreate") or {}
        if not payload.get("success"):
            raise RuntimeError("Linear issueCreate failed")
        issue = payload["issue"]
        return CreatedIssue(issue["id"], issue["identifier"], issue.get("url"))

    def create_blocked_by(self, blocked_issue_id: str, blocker_issue_id: str) -> None:
        data = self.graphql(
            """
            mutation AsyncSelfCreateIssueRelation($input: IssueRelationCreateInput!) {
              issueRelationCreate(input: $input) {
                success
              }
            }
            """,
            {
                "input": {
                    "issueId": blocker_issue_id,
                    "relatedIssueId": blocked_issue_id,
                    "type": "blocks",
                }
            },
        )
        if not (data.get("issueRelationCreate") or {}).get("success"):
            raise RuntimeError("Linear issueRelationCreate failed")

    def fetch_issue(self, issue_ref: str) -> LinearIssue:
        data = self.graphql(
            """
            query AsyncSelfIssue($issueRef: String!) {
              issue(id: $issueRef) {
                id
                identifier
                title
                description
                state { name }
                url
                labels { nodes { name id } }
                history(first: 100) {
                  nodes {
                    fromState { name }
                    toState { name }
                  }
                  pageInfo { hasNextPage endCursor }
                }
                inverseRelations(first: 100) {
                  nodes {
                    type
                    issue {
                      id
                      identifier
                      state { name }
                    }
                  }
                  pageInfo { hasNextPage endCursor }
                }
              }
            }
            """,
            {"issueRef": issue_ref},
        )
        issue = data.get("issue")
        if not issue:
            raise RuntimeError(f"Linear issue not found: {issue_ref}")
        self._extend_issue_connection(issue_ref, issue, "history")
        self._extend_issue_connection(issue_ref, issue, "inverseRelations")
        return _issue_from_node(issue)

    def fetch_successors(self, issue_ref: str) -> list[LinearIssue]:
        query = """
        query AsyncSelfIssueSuccessors($issueRef: String!, $after: String) {
          issue(id: $issueRef) {
            relations(first: 100, after: $after) {
              nodes {
                type
                relatedIssue { id }
              }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
        """
        relations: list[dict[str, Any]] = []
        after = None
        seen_cursors: set[str] = set()
        while True:
            data = self.graphql(query, {"issueRef": issue_ref, "after": after})
            connection = (((data.get("issue") or {}).get("relations")) or {})
            relations.extend(connection.get("nodes") or [])
            after = _next_cursor(connection, seen_cursors, "successor relations")
            if after is None:
                break
        successor_ids: list[str] = []
        for relation in relations:
            if str(relation.get("type") or "").lower().strip() != "blocks":
                continue
            related = relation.get("relatedIssue")
            if related and related.get("id") and related["id"] not in successor_ids:
                successor_ids.append(related["id"])
        # Fetch each successor separately. Nesting labels, history, and inverse
        # relations under a 100-item relation connection exceeds Linear's
        # query-complexity limit even for issues with only a few relations.
        return [self.fetch_issue(successor_id) for successor_id in successor_ids]

    def _extend_issue_connection(self, issue_ref: str, issue: dict[str, Any], name: str) -> None:
        connection = issue.get(name) or {"nodes": []}
        nodes = list(connection.get("nodes") or [])
        after = None
        seen_cursors: set[str] = set()
        while _connection_has_next(connection):
            after = _next_cursor(connection, seen_cursors, name)
            if after is None:
                break
            if name == "history":
                query = """
                query AsyncSelfIssueHistoryPage($issueRef: String!, $after: String) {
                  issue(id: $issueRef) {
                    history(first: 100, after: $after) {
                      nodes { fromState { name } toState { name } }
                      pageInfo { hasNextPage endCursor }
                    }
                  }
                }
                """
            else:
                query = """
                query AsyncSelfIssueBlockersPage($issueRef: String!, $after: String) {
                  issue(id: $issueRef) {
                    inverseRelations(first: 100, after: $after) {
                      nodes { type issue { id identifier state { name } } }
                      pageInfo { hasNextPage endCursor }
                    }
                  }
                }
                """
            data = self.graphql(query, {"issueRef": issue_ref, "after": after})
            connection = (((data.get("issue") or {}).get(name)) or {})
            nodes.extend(connection.get("nodes") or [])
        issue[name] = {"nodes": nodes, "pageInfo": connection.get("pageInfo") or {}}

    def update_issue_description(self, issue_id: str, description: str) -> None:
        self._issue_update(issue_id, {"description": description})

    def update_issue_state(self, issue_id: str, state_id: str) -> None:
        self._issue_update(issue_id, {"stateId": state_id})

    def set_issue_labels(self, issue_id: str, label_ids: list[str]) -> None:
        self._issue_update(issue_id, {"labelIds": label_ids})

    def ensure_workflow_state(self, team_id: str, name: str, state_type: str = "unstarted") -> str:
        try:
            return self.state_id(team_id, name)
        except RuntimeError:
            input_data = {
                "teamId": team_id,
                "name": name,
                "type": state_type,
                "color": WORKFLOW_STATE_COLORS.get(name, DEFAULT_WORKFLOW_STATE_COLOR),
            }
            data = self.graphql(
                """
                mutation AsyncSelfCreateState($input: WorkflowStateCreateInput!) {
                  workflowStateCreate(input: $input) {
                    success
                    workflowState { id name }
                  }
                }
                """,
                {"input": input_data},
            )
            payload = data.get("workflowStateCreate") or {}
            if not payload.get("success"):
                raise RuntimeError(f"Linear workflowStateCreate failed: {name}")
            return payload["workflowState"]["id"]

    def sync_workflow_state_order(
        self,
        team_id: str,
        desired_order: tuple[str, ...] = DEFAULT_WORKFLOW_STATE_ORDER,
    ) -> list[WorkflowState]:
        states = self.workflow_states(team_id)
        states_by_name = {_normalize_state_name(state.name): state for state in states}
        changed: list[WorkflowState] = []
        for state, position in self._custom_state_position_updates(states_by_name, desired_order):
            if state.position is not None and float(state.position) == position:
                continue
            self.update_workflow_state_position(state.id, position)
            changed.append(WorkflowState(state.id, state.name, state.type, position))
        return changed

    def _custom_state_position_updates(
        self,
        states_by_name: dict[str, WorkflowState],
        desired_order: tuple[str, ...],
    ) -> list[tuple[WorkflowState, float]]:
        reserved_positions = {
            _normalize_state_name(name): float(state.position)
            for name in ("Todo", "In Progress")
            if (state := states_by_name.get(_normalize_state_name(name))) and state.position is not None
        }
        todo_position = reserved_positions.get("todo", float(WORKFLOW_STATE_POSITION_STEP * 3))
        in_progress_position = reserved_positions.get("in progress", todo_position + WORKFLOW_STATE_POSITION_STEP * 2)

        custom_names = [
            _normalize_state_name(name)
            for name in desired_order
            if _normalize_state_name(name) not in RESERVED_WORKFLOW_STATE_NAMES
        ]
        before_todo = [name for name in custom_names if desired_order_index(name, desired_order) < desired_order_index("todo", desired_order)]
        between_todo_and_progress = [
            name
            for name in custom_names
            if desired_order_index("todo", desired_order) < desired_order_index(name, desired_order) < desired_order_index("in progress", desired_order)
        ]
        after_progress = [
            name
            for name in custom_names
            if desired_order_index(name, desired_order) > desired_order_index("in progress", desired_order)
        ]

        updates: list[tuple[WorkflowState, float]] = []
        updates.extend(_spread_before(states_by_name, before_todo, todo_position))
        updates.extend(_spread_between(states_by_name, between_todo_and_progress, todo_position, in_progress_position))
        updates.extend(_spread_after(states_by_name, after_progress, in_progress_position))
        return updates

    def update_workflow_state_position(self, state_id: str, position: int | float) -> None:
        data = self.graphql(
            """
            mutation AsyncSelfUpdateWorkflowState($stateId: String!, $input: WorkflowStateUpdateInput!) {
              workflowStateUpdate(id: $stateId, input: $input) {
                success
              }
            }
            """,
            {"stateId": state_id, "input": {"position": position}},
        )
        if not (data.get("workflowStateUpdate") or {}).get("success"):
            raise RuntimeError(f"Linear workflowStateUpdate failed: {state_id}")

    def _issue_update(self, issue_id: str, input_data: dict[str, Any]) -> None:
        data = self.graphql(
            """
            mutation AsyncSelfIssueUpdate($issueId: String!, $input: IssueUpdateInput!) {
              issueUpdate(id: $issueId, input: $input) {
                success
              }
            }
            """,
            {"issueId": issue_id, "input": input_data},
        )
        if not (data.get("issueUpdate") or {}).get("success"):
            raise RuntimeError(f"Linear issueUpdate failed: {issue_id}")


def _first_node(data: dict[str, Any], key: str) -> dict[str, Any] | None:
    nodes = ((data.get(key) or {}).get("nodes")) or []
    return nodes[0] if nodes else None


def _workflow_state_from_node(node: dict[str, Any]) -> WorkflowState:
    position = node.get("position")
    return WorkflowState(
        id=node["id"],
        name=node.get("name") or "",
        type=node.get("type"),
        position=float(position) if position is not None else None,
    )


def _normalize_state_name(name: str) -> str:
    normalized = " ".join(name.strip().lower().replace("_", " ").replace("-", " ").split())
    return WORKFLOW_STATE_NAME_ALIASES.get(normalized, normalized)


def desired_order_index(name: str, desired_order: tuple[str, ...]) -> int:
    normalized = _normalize_state_name(name)
    for index, candidate in enumerate(desired_order):
        if _normalize_state_name(candidate) == normalized:
            return index
    return len(desired_order) + 1


def _spread_before(
    states_by_name: dict[str, WorkflowState],
    names: list[str],
    anchor_position: float,
) -> list[tuple[WorkflowState, float]]:
    gap = WORKFLOW_STATE_POSITION_STEP / 10
    start = anchor_position - gap * len(names)
    return _existing_custom_updates(states_by_name, names, start, gap)


def _spread_between(
    states_by_name: dict[str, WorkflowState],
    names: list[str],
    start_position: float,
    end_position: float,
) -> list[tuple[WorkflowState, float]]:
    if not names:
        return []
    gap = (end_position - start_position) / (len(names) + 1)
    if gap <= 0:
        gap = WORKFLOW_STATE_POSITION_STEP / 10
    return _existing_custom_updates(states_by_name, names, start_position + gap, gap)


def _spread_after(
    states_by_name: dict[str, WorkflowState],
    names: list[str],
    anchor_position: float,
) -> list[tuple[WorkflowState, float]]:
    gap = WORKFLOW_STATE_POSITION_STEP / 10
    return _existing_custom_updates(states_by_name, names, anchor_position + gap, gap)


def _existing_custom_updates(
    states_by_name: dict[str, WorkflowState],
    names: list[str],
    first_position: float,
    gap: float,
) -> list[tuple[WorkflowState, float]]:
    updates: list[tuple[WorkflowState, float]] = []
    for index, name in enumerate(names):
        state = states_by_name.get(name)
        if state and _normalize_state_name(state.name) not in RESERVED_WORKFLOW_STATE_NAMES:
            updates.append((state, first_position + gap * index))
    return updates


def _issue_from_node(node: dict[str, Any]) -> LinearIssue:
    label_nodes = (((node.get("labels") or {}).get("nodes")) or [])
    labels = tuple(label.get("name") or "" for label in label_nodes)
    label_ids = tuple(label.get("id") or "" for label in label_nodes if label.get("id"))
    blocked_by: list[dict[str, str | None]] = []
    for relation in (((node.get("inverseRelations") or {}).get("nodes")) or []):
        if str(relation.get("type") or "").lower().strip() != "blocks":
            continue
        blocker = relation.get("issue") or {}
        blocked_by.append(
            {
                "id": blocker.get("id"),
                "identifier": blocker.get("identifier"),
                "state": ((blocker.get("state") or {}).get("name")),
            }
        )
    return LinearIssue(
        id=node["id"],
        identifier=node["identifier"],
        title=node["title"],
        description=node.get("description") or "",
        state=((node.get("state") or {}).get("name")) or "",
        labels=labels,
        label_ids=label_ids,
        blocked_by=tuple(blocked_by),
        url=node.get("url"),
        previously_completed=_issue_previously_completed(node),
    )


def _issue_previously_completed(node: dict[str, Any]) -> bool:
    history_nodes = (((node.get("history") or {}).get("nodes")) or [])
    for event in history_nodes:
        from_state = ((event.get("fromState") or {}).get("name")) or ""
        to_state = ((event.get("toState") or {}).get("name")) or ""
        if _normalize_state_name(from_state) == "done" or _normalize_state_name(to_state) == "done":
            return True
    return False


def _connection_has_next(connection: Any) -> bool:
    return bool(isinstance(connection, dict) and (connection.get("pageInfo") or {}).get("hasNextPage"))


def _next_cursor(connection: dict[str, Any], seen: set[str], label: str) -> str | None:
    info = connection.get("pageInfo") or {}
    if not info.get("hasNextPage"):
        return None
    cursor = info.get("endCursor")
    if not cursor:
        raise RuntimeError(f"Linear pagination cursor missing for {label}")
    cursor = str(cursor)
    if cursor in seen:
        raise RuntimeError(f"Linear pagination cursor repeated for {label}")
    seen.add(cursor)
    return cursor
