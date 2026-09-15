"""Pull requests, via the ``gh`` CLI.

One GraphQL query rather than two ``gh search prs`` calls: the REST search gh
exposes through ``--json`` cannot report a review decision or a CI rollup, and
those are the two facts that decide whether a pull request needs attention today.
Both queues -- authored and review-requested -- come back in the same round trip.

``gh`` owns authentication, so there is nothing here to configure. When it is
missing or logged out the fetch fails and the cache takes over.
"""
from __future__ import annotations

import json
import shutil
import subprocess
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

from . import cache

CACHE_NAME = "github-pull-requests"
DEFAULT_TIMEOUT = 20

QUERY = """
query($mine: String!, $reviews: String!, $limit: Int!) {
  mine: search(query: $mine, type: ISSUE, first: $limit) {
    nodes { ...pr }
  }
  reviews: search(query: $reviews, type: ISSUE, first: $limit) {
    nodes { ...pr }
  }
}
fragment pr on PullRequest {
  number
  title
  url
  isDraft
  updatedAt
  reviewDecision
  author { login }
  repository { nameWithOwner }
  commits(last: 1) {
    nodes { commit { statusCheckRollup { state } } }
  }
}
"""


@dataclass(frozen=True)
class PullRequest:
    repository: str
    number: int
    title: str
    url: str
    author: str
    is_draft: bool
    review_decision: str
    checks: str
    updated_at: str

    @property
    def short_repository(self) -> str:
        """Just the repo name, and without the team prefix these repos all share."""
        name = self.repository.split("/")[-1]
        for prefix in ("saks-data-team-", "saks-"):
            if name.startswith(prefix) and len(name) > len(prefix):
                return name[len(prefix):]
        return name

    @property
    def reference(self) -> str:
        return "%s#%d" % (self.short_repository, self.number)

    @property
    def age_days(self) -> Optional[float]:
        stamp = _parse_timestamp(self.updated_at)
        if stamp is None:
            return None
        return (datetime.now(timezone.utc) - stamp).total_seconds() / 86400

    def state_label(self) -> str:
        """The single most important thing about this pull request right now.

        Ordered by what blocks progress: a draft is not waiting on anyone, a failing
        build is the author's problem, changes requested is the author's problem,
        approved means it can land, and anything else is waiting on a reviewer.
        """
        if self.is_draft:
            return "DRAFT"
        if self.checks == "FAILURE":
            return "FAILING"
        if self.review_decision == "CHANGES_REQUESTED":
            return "CHANGES"
        if self.review_decision == "APPROVED":
            return "APPROVED"
        if self.checks == "PENDING":
            return "BUILDING"
        return "REVIEW"


@dataclass(frozen=True)
class PullRequestQueues:
    mine: List[PullRequest]
    awaiting_my_review: List[PullRequest]
    cached: Optional[cache.CachedValue] = None
    live: bool = True

    @property
    def total(self) -> int:
        return len(self.mine) + len(self.awaiting_my_review)


def _parse_timestamp(value: str) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _to_pull_request(node: Dict[str, Any]) -> Optional[PullRequest]:
    if not node:
        return None
    commits = (node.get("commits") or {}).get("nodes") or []
    rollup = None
    if commits:
        rollup = ((commits[0] or {}).get("commit") or {}).get("statusCheckRollup")
    return PullRequest(
        repository=((node.get("repository") or {}).get("nameWithOwner") or ""),
        number=int(node.get("number") or 0),
        title=(node.get("title") or "").strip(),
        url=node.get("url") or "",
        author=((node.get("author") or {}).get("login") or ""),
        is_draft=bool(node.get("isDraft")),
        review_decision=node.get("reviewDecision") or "",
        checks=(rollup or {}).get("state") or "",
        updated_at=node.get("updatedAt") or "",
    )


def fetch(limit: int = 20, timeout: int = DEFAULT_TIMEOUT) -> PullRequestQueues:
    """Query GitHub live. Raises when ``gh`` is missing, logged out, or slow."""
    if shutil.which("gh") is None:
        raise RuntimeError("gh is not installed")

    completed = subprocess.run(
        [
            "gh", "api", "graphql",
            "-f", "query=%s" % QUERY,
            "-F", "mine=is:pr is:open archived:false author:@me",
            "-F", "reviews=is:pr is:open archived:false review-requested:@me",
            "-F", "limit=%d" % limit,
        ],
        capture_output=True, text=True, timeout=timeout,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip().splitlines()
        raise RuntimeError(detail[0] if detail else "gh api graphql failed")

    document = json.loads(completed.stdout)
    data = document.get("data") or {}

    def collect(key: str) -> List[PullRequest]:
        nodes = ((data.get(key) or {}).get("nodes")) or []
        built = [_to_pull_request(node) for node in nodes]
        return [pull_request for pull_request in built if pull_request]

    queues = PullRequestQueues(
        mine=collect("mine"),
        awaiting_my_review=collect("reviews"),
        live=True,
    )
    cache.write(CACHE_NAME, _serialise(queues), source="gh api graphql")
    return queues


def _serialise(queues: PullRequestQueues) -> Dict[str, Any]:
    return {
        "mine": [asdict(pull_request) for pull_request in queues.mine],
        "awaiting_my_review": [asdict(p) for p in queues.awaiting_my_review],
    }


def _deserialise(payload: Any) -> Tuple[List[PullRequest], List[PullRequest]]:
    if not isinstance(payload, dict):
        return ([], [])

    def build(key: str) -> List[PullRequest]:
        out = []
        for row in payload.get(key) or []:
            if isinstance(row, dict):
                try:
                    out.append(PullRequest(**row))
                except TypeError:
                    continue
        return out

    return (build("mine"), build("awaiting_my_review"))


def load(limit: int = 20, timeout: int = DEFAULT_TIMEOUT,
         allow_live: bool = True) -> PullRequestQueues:
    """Live if possible, cached if not, empty if neither.

    Never raises. A pane that cannot reach GitHub should say so in its header and
    keep its shape, not vanish from the layout.
    """
    if allow_live:
        try:
            return fetch(limit=limit, timeout=timeout)
        except Exception:  # noqa: BLE001 - fall through to the cache
            pass
    cached = cache.read(CACHE_NAME)
    if cached is None:
        return PullRequestQueues(mine=[], awaiting_my_review=[], live=False)
    mine, reviews = _deserialise(cached.payload)
    return PullRequestQueues(mine=mine, awaiting_my_review=reviews,
                             cached=cached, live=False)
