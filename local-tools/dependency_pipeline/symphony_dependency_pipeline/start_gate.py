"""Markdown Start Gate parsing and update helpers."""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Iterable


CHECKBOX_RE = re.compile(r"^(\s*[-*]\s+\[)( |x|X)(\]\s+)(.*)$")
ISSUE_KEY_RE = re.compile(r"\b[A-Z][A-Z0-9]+-\d+\b")
MARKER_RE = re.compile(r"^(?P<kind>dep|human)\s*:\s*(?P<body>.*)$", re.IGNORECASE)
DEP_MARKER_RE = re.compile(r"^dep\s*:\s*(?P<key>[A-Za-z][A-Za-z0-9_-]*)\b", re.IGNORECASE)


@dataclass(frozen=True)
class CheckboxItem:
    line_index: int
    checked: bool
    text: str


@dataclass(frozen=True)
class StartGateSection:
    start_index: int
    end_index: int
    items: tuple[CheckboxItem, ...]


@dataclass(frozen=True)
class MarkResult:
    text: str
    found: bool
    changed: bool


def find_section(markdown: str, heading: str = "Start Gate") -> StartGateSection | None:
    """Find the named level-2 Start Gate section."""
    lines = markdown.splitlines()
    heading_re = re.compile(rf"^##\s+{re.escape(heading)}\s*$", re.IGNORECASE)

    start_index = None
    for index, line in enumerate(lines):
        if heading_re.match(line.strip()):
            start_index = index
            break

    if start_index is None:
        return None

    end_index = len(lines)
    for index in range(start_index + 1, len(lines)):
        line = lines[index]
        if line.startswith("## "):
            end_index = index
            break

    items: list[CheckboxItem] = []
    for index in range(start_index + 1, end_index):
        match = CHECKBOX_RE.match(lines[index])
        if match:
            checked = match.group(2).lower() == "x"
            items.append(CheckboxItem(index, checked, match.group(4).strip()))

    return StartGateSection(start_index, end_index, tuple(items))


def all_checkboxes_checked(markdown: str) -> bool:
    """Return true only when a Start Gate exists and every checkbox is checked."""
    section = find_section(markdown)
    return section is not None and bool(section.items) and all(item.checked for item in section.items)


def dependency_checkbox(key: str, text: str = "dependency completed", checked: bool = False) -> str:
    mark = "x" if checked else " "
    return f"- [{mark}] dep:{key.strip()} {text.strip()}".rstrip()


def ensure_human_checkbox_marker(line: str) -> str:
    match = CHECKBOX_RE.match(line)
    if not match:
        return line

    text = match.group(4).strip()
    if _marker_kind(text):
        return line
    return f"{match.group(1)}{match.group(2)}{match.group(3)}human: {text}"


def human_items_checked(markdown: str, dependency_keys: Iterable[str] = ()) -> bool:
    """Return true when non-dependency Start Gate items are checked.

    Structured `dep:` lines are dependency-owned and structured `human:` lines are
    person-owned. Legacy issue-key lines are treated as dependency-owned for compatibility.
    """
    section = find_section(markdown)
    if section is None:
        return False

    dependency_key_set = {key.strip() for key in dependency_keys if key and key.strip()}
    human_items = [
        item
        for item in section.items
        if not _dependency_item(item.text, dependency_key_set)
    ]

    return bool(human_items) and all(item.checked for item in human_items)


def mark_dependency_checked(markdown: str, dependency_key: str) -> MarkResult:
    """Mark the Start Gate checkbox for dependency_key as checked."""
    if not dependency_key or not dependency_key.strip():
        return MarkResult(markdown, found=False, changed=False)

    dependency_key = dependency_key.strip()
    lines = markdown.splitlines()
    section = find_section(markdown)
    if section is None:
        return MarkResult(markdown, found=False, changed=False)

    found = False
    changed = False

    for item in section.items:
        if not _dependency_item_matches(item.text, dependency_key):
            continue

        found = True
        if item.checked:
            continue

        match = CHECKBOX_RE.match(lines[item.line_index])
        if not match:
            continue

        lines[item.line_index] = f"{match.group(1)}x{match.group(3)}{match.group(4)}"
        changed = True

    if not found:
        return MarkResult(markdown, found=False, changed=False)

    return MarkResult("\n".join(lines) + ("\n" if markdown.endswith("\n") else ""), found=True, changed=changed)


def _dependency_item(text: str, dependency_keys: set[str]) -> bool:
    kind = _marker_kind(text)
    if kind == "dep":
        return True
    if kind == "human":
        return False
    if any(_contains_dependency_key(text, key) for key in dependency_keys):
        return True
    return ISSUE_KEY_RE.search(text) is not None


def _dependency_item_matches(text: str, dependency_key: str) -> bool:
    marker_key = _dependency_marker_key(text)
    if marker_key is not None:
        return marker_key == dependency_key
    return _contains_dependency_key(text, dependency_key)


def _marker_kind(text: str) -> str | None:
    match = MARKER_RE.match(text.strip())
    return match.group("kind").lower() if match else None


def _dependency_marker_key(text: str) -> str | None:
    match = DEP_MARKER_RE.match(text.strip())
    return match.group("key") if match else None


def _contains_dependency_key(text: str, dependency_key: str) -> bool:
    if not dependency_key:
        return False
    pattern = rf"(?<![A-Za-z0-9-]){re.escape(dependency_key)}(?![A-Za-z0-9-])"
    return re.search(pattern, text) is not None
