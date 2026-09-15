"""Assigned Jira work items.

Two ways in, tried in order:

``acli``   Atlassian's CLI, when it is installed and logged in. This is the live
           path and needs a one-time ``acli jira auth login``.
``cache``  whatever last wrote ``~/.cache/lcarcat/dashboard/jira-work-items.json``.
           An agent with Jira access can fill this without the terminal ever
           holding a credential, and ``tools/refresh_jira_cache.py`` writes it in
           the shape this module reads.

The parser is deliberately forgiving about shape. ``acli --json`` and the Jira
REST search return the same facts nested differently -- ``status`` as a string in
one and ``fields.status.name`` in the other -- and a dashboard pane is not worth
breaking over which one produced the file.
"""
from __future__ import annotations

import json
import shutil
import subprocess
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from . import cache

CACHE_NAME = "jira-work-items"
DEFAULT_TIMEOUT = 25

#: Everything assigned to the user that is not finished, freshest first. Kept as a
#: default rather than hard-coded so a layout can narrow it (one project, one
#: sprint) without touching this module.
DEFAULT_JQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"

#: Fields acli's search will accept. It allows a fixed set and hard-errors on
#: anything else -- ``--fields ...,updated,project`` fails outright with
#: "fields 'updated, project' are not allowed" rather than ignoring them, which
#: would send every live fetch silently down the cache path.
#:
#: ``updated`` is therefore unavailable on the acli path, so work items fetched
#: live carry no timestamp and sort by priority alone. ``project`` is no loss --
#: WorkItem.project_key falls back to the key prefix. A cache written from the
#: REST API or the MCP server does carry ``updated``, and the parser reads it
#: when it is there.
FIELDS = "key,summary,status,issuetype,priority"

#: Jira's three status categories, normalised. ``indeterminate`` is Jira's own name
#: for "in flight", which is the one a dashboard most wants to pick out.
CATEGORY_NEW = "new"
CATEGORY_ACTIVE = "indeterminate"
CATEGORY_DONE = "done"

_ACTIVE_STATUS_WORDS = ("progress", "review", "dev in", "analysis", "doing")
_BLOCKED_STATUS_WORDS = ("blocked", "impediment", "waiting", "on hold")


@dataclass(frozen=True)
class WorkItem:
    key: str
    summary: str
    status: str
    status_category: str
    issue_type: str
    priority: str
    updated: str
    project: str = ""

    @property
    def is_active(self) -> bool:
        if self.status_category == CATEGORY_ACTIVE:
            return True
        lowered = self.status.lower()
        return any(word in lowered for word in _ACTIVE_STATUS_WORDS)

    @property
    def is_blocked(self) -> bool:
        lowered = self.status.lower()
        return any(word in lowered for word in _BLOCKED_STATUS_WORDS)

    @property
    def age_days(self) -> Optional[float]:
        stamp = _parse_timestamp(self.updated)
        if stamp is None:
            return None
        return (datetime.now(timezone.utc) - stamp).total_seconds() / 86400

    @property
    def project_key(self) -> str:
        return self.project or (self.key.split("-")[0] if "-" in self.key else self.key)

    def priority_rank(self) -> int:
        """Lower sorts first. Jira sites disagree on naming, so match on both forms."""
        lowered = self.priority.lower()
        for rank, names in enumerate((
            ("highest", "p0", "blocker", "critical"),
            ("high", "p1", "major"),
            ("medium", "p2", "normal"),
            ("low", "p3", "minor"),
            ("lowest", "p4", "trivial"),
        )):
            if any(name in lowered for name in names):
                return rank
        return 3


@dataclass(frozen=True)
class WorkItemQueue:
    items: List[WorkItem]
    jql: str = DEFAULT_JQL
    cached: Optional[cache.CachedValue] = None
    live: bool = True

    @property
    def active(self) -> List[WorkItem]:
        return [item for item in self.items if item.is_active]

    @property
    def blocked(self) -> List[WorkItem]:
        return [item for item in self.items if item.is_blocked]

    def ranked(self) -> List[WorkItem]:
        """Most worth looking at first: in-flight work, then priority, then freshness.

        Blocked items sort with the active ones rather than the backlog -- something
        stuck is a thing to act on, not a thing to ignore.
        """
        def sort_key(item: WorkItem):
            return (
                0 if (item.is_active or item.is_blocked) else 1,
                item.priority_rank(),
                item.age_days if item.age_days is not None else 9999,
            )

        return sorted(self.items, key=sort_key)


def _parse_timestamp(value: str) -> Optional[datetime]:
    if not value:
        return None
    text = value.strip().replace("Z", "+00:00")
    # Jira emits +0000 without the colon, which fromisoformat rejects before 3.11.
    if len(text) > 5 and (text[-5] in "+-") and text[-3] != ":":
        text = text[:-2] + ":" + text[-2:]
    try:
        stamp = datetime.fromisoformat(text)
    except ValueError:
        return None
    return stamp if stamp.tzinfo else stamp.replace(tzinfo=timezone.utc)


def _text(value: Any, *keys: str) -> str:
    """Pull a string out of either a bare value or a nested Jira object."""
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in keys:
            found = value.get(key)
            if isinstance(found, str) and found:
                return found
    return ""


def _first(source: Dict[str, Any], *names: str) -> Any:
    """The first of ``names`` present in ``source``.

    Producers spell the same field differently -- Jira uses ``issuetype``, the REST
    docs use ``issueType``, and this module's own cache uses the dataclass name
    ``issue_type``. Reading all of them is what lets one parser handle a live fetch
    and a reload of what that fetch wrote.
    """
    for name in names:
        if name in source and source[name] not in (None, ""):
            return source[name]
    return None


def parse_item(row: Dict[str, Any]) -> Optional[WorkItem]:
    """Build a work item from a row in any of the shapes described in the module docstring."""
    if not isinstance(row, dict):
        return None
    nested = row.get("fields")
    merged: Dict[str, Any] = dict(nested) if isinstance(nested, dict) else {}
    # Top-level keys win: acli's flattened output puts the useful value there.
    merged.update({k: v for k, v in row.items() if k != "fields"})

    key = _text(_first(merged, "key"), "key") or _text(_first(merged, "id"), "id")
    if not key:
        return None

    status_value = _first(merged, "status")
    status = _text(status_value, "name", "value")
    category = _text(_first(merged, "status_category", "statusCategory"),
                     "key", "name").lower()
    if not category and isinstance(status_value, dict):
        category = _text(status_value.get("statusCategory"), "key", "name").lower()

    return WorkItem(
        key=key,
        summary=_text(_first(merged, "summary"), "summary") or "",
        status=status or "UNKNOWN",
        status_category=category,
        issue_type=_text(_first(merged, "issuetype", "issueType", "issue_type"), "name"),
        priority=_text(_first(merged, "priority"), "name", "value"),
        updated=_text(_first(merged, "updated"), "value"),
        project=_text(_first(merged, "project"), "key", "name"),
    )


def _rows_from(document: Any) -> List[Dict[str, Any]]:
    """Find the list of work items in whatever envelope the producer used."""
    if isinstance(document, list):
        return [row for row in document if isinstance(row, dict)]
    if isinstance(document, dict):
        for key in ("issues", "workItems", "work_items", "items", "values", "results"):
            found = document.get(key)
            if isinstance(found, list):
                return [row for row in found if isinstance(row, dict)]
        # The MCP search tool wraps its list one level deeper.
        nested = document.get("issues")
        if isinstance(nested, dict) and isinstance(nested.get("nodes"), list):
            return [row for row in nested["nodes"] if isinstance(row, dict)]
    return []


def fetch(jql: str = DEFAULT_JQL, limit: int = 40,
          timeout: int = DEFAULT_TIMEOUT) -> WorkItemQueue:
    """Query Jira live through ``acli``. Raises when it is missing or logged out."""
    if shutil.which("acli") is None:
        raise RuntimeError("acli is not installed")

    completed = subprocess.run(
        ["acli", "jira", "workitem", "search",
         "--jql", jql, "--fields", FIELDS, "--limit", str(limit), "--json"],
        capture_output=True, text=True, timeout=timeout,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip().splitlines()
        message = detail[0] if detail else "acli search failed"
        if "unauthorized" in message.lower():
            message = "acli not logged in -- run: acli jira auth login"
        raise RuntimeError(message)

    document = json.loads(completed.stdout or "[]")
    items = [item for item in (parse_item(row) for row in _rows_from(document)) if item]
    queue = WorkItemQueue(items=items, jql=jql, live=True)
    cache.write(CACHE_NAME, {"jql": jql, "items": [asdict(i) for i in items]},
                source="acli jira workitem search")
    return queue


def load(jql: str = DEFAULT_JQL, limit: int = 40, timeout: int = DEFAULT_TIMEOUT,
         allow_live: bool = True) -> WorkItemQueue:
    """Live if possible, cached if not, empty if neither. Never raises."""
    if allow_live:
        try:
            return fetch(jql=jql, limit=limit, timeout=timeout)
        except Exception:  # noqa: BLE001 - fall through to the cache
            pass
    cached = cache.read(CACHE_NAME)
    if cached is None:
        return WorkItemQueue(items=[], jql=jql, live=False)
    payload = cached.payload
    rows = payload.get("items") if isinstance(payload, dict) else payload
    items = [item for item in (parse_item(row) for row in _rows_from(
        rows if isinstance(rows, (list, dict)) else [])) if item]
    return WorkItemQueue(
        items=items,
        jql=(payload.get("jql") if isinstance(payload, dict) else jql) or jql,
        cached=cached,
        live=False,
    )
