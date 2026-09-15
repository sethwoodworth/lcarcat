"""A JSON cache on disk, with the age of what it holds.

Two things need this. A pane whose source is unreachable should show the last
good answer rather than an empty box, and a pane whose source needs credentials
the dashboard does not have should still show real data that something else
fetched. Both want the same thing: a file, a timestamp, and an honest report of
how old it is.
"""
from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

CACHE_DIR = Path(
    os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")
) / "lcarcat" / "dashboard"


@dataclass(frozen=True)
class CachedValue:
    payload: Any
    fetched_at: float
    source: str = ""

    @property
    def age_seconds(self) -> float:
        return max(0.0, time.time() - self.fetched_at)

    def age_label(self) -> str:
        """Compact age for a header chip: ``12S``, ``4M``, ``3H``, ``2D``."""
        age = self.age_seconds
        if age < 90:
            return "%dS" % int(age)
        if age < 90 * 60:
            return "%dM" % int(age / 60)
        if age < 36 * 3600:
            return "%dH" % int(age / 3600)
        return "%dD" % int(age / 86400)

    def is_stale(self, limit_seconds: float) -> bool:
        return self.age_seconds > limit_seconds


def path_for(name: str, directory: Optional[Path] = None) -> Path:
    return (directory or CACHE_DIR) / ("%s.json" % name)


def write(name: str, payload: Any, source: str = "",
          directory: Optional[Path] = None) -> Path:
    """Store ``payload`` under ``name``, stamped with the current time.

    Written to a sibling temp and renamed, so a reader never sees a half-written
    file -- the dashboard redraw loop and a refresh can run at the same time.
    """
    target = path_for(name, directory)
    target.parent.mkdir(parents=True, exist_ok=True)
    document = {"fetched_at": time.time(), "source": source, "payload": payload}
    temporary = target.with_suffix(".%d.tmp" % os.getpid())
    try:
        temporary.write_text(json.dumps(document, indent=2), encoding="utf-8")
        os.replace(temporary, target)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    return target


def read(name: str, directory: Optional[Path] = None) -> Optional[CachedValue]:
    """Load a cached value, or ``None`` when there is no usable file.

    A corrupt or truncated cache is treated as absent rather than raised: the
    caller's next move is the same either way, and a bad cache file should not be
    able to stop the dashboard from starting.
    """
    target = path_for(name, directory)
    try:
        document = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(document, dict) or "payload" not in document:
        return None
    return CachedValue(
        payload=document["payload"],
        fetched_at=float(document.get("fetched_at", 0.0)),
        source=str(document.get("source", "")),
    )
