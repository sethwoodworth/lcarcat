"""Dashboard widgets, and a registry so layouts can name them as strings.

Naming widgets rather than importing them is what lets a layout be data. A user
who wants the Jira pane swapped for the orrery edits a name, and the CLI can list
what is available without a layout having to enumerate it.
"""
from __future__ import annotations

from typing import Callable, Dict, List

from .base import Widget, WidgetChrome
from .github import PullRequestWidget
from .jira import JiraWidget
from .framed_image import FramedImageWidget
from .orrery import MoonWidget, OrreryWidget, SkyWidget
from .sol import SolWidget
from .stardate import StardateWidget
from .telemetry import TelemetryWidget

#: name -> factory. Factories take no arguments, so a layout can ask for a default
#: instance; a layout that wants a configured one constructs the class directly.
REGISTRY: Dict[str, Callable[[], Widget]] = {
    "jira": JiraWidget,
    "pull-requests": PullRequestWidget,
    "orrery": OrreryWidget,
    "sky": SkyWidget,
    "moon": MoonWidget,
    "sol": SolWidget,
    "stardate": StardateWidget,
    "telemetry": TelemetryWidget,
}


def build(name: str) -> Widget:
    try:
        return REGISTRY[name]()
    except KeyError:
        raise KeyError("unknown widget %r; available: %s"
                       % (name, ", ".join(sorted(REGISTRY))))


def names() -> List[str]:
    return sorted(REGISTRY)


__all__ = [
    "FramedImageWidget", "JiraWidget", "MoonWidget",
    "OrreryWidget", "SolWidget",
    "PullRequestWidget",
    "SkyWidget", "StardateWidget", "TelemetryWidget", "Widget", "WidgetChrome",
    "REGISTRY", "build", "names",
]
