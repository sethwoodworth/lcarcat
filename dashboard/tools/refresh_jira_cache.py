#!/usr/bin/env python3
"""Fill the dashboard's Jira cache from a JQL search result.

The dashboard's live Jira path is ``acli``, which needs a one-time interactive
login. Until that happens -- or on a machine where it should never happen -- the
Jira pane reads a cache, and this writes it.

Point it at any JSON search result: Atlassian's REST ``/search`` response, the
Atlassian MCP server's output, a bare list of issues. The parser in
``dashboard/sources/jira.py`` accepts all of them, so an agent that already has
Jira access can refresh the pane by saving a query to a file and running this,
without a credential ever reaching the terminal.

    uv run dashboard/tools/refresh_jira_cache.py search-result.json
    some-command-producing-json | uv run dashboard/tools/refresh_jira_cache.py -

Prints where the cache landed and how many work items it holds.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from dashboard.sources import cache, jira  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "source",
        help="JSON file holding a Jira search result, or - to read standard input",
    )
    parser.add_argument(
        "--jql",
        default=jira.DEFAULT_JQL,
        help="the query this result came from, recorded alongside the items",
    )
    parser.add_argument(
        "--label",
        default="refresh_jira_cache.py",
        help="what produced this data, shown when the pane reports its source",
    )
    arguments = parser.parse_args()

    raw = sys.stdin.read() if arguments.source == "-" else Path(arguments.source).read_text(
        encoding="utf-8")
    try:
        document = json.loads(raw)
    except ValueError as failure:
        print("not valid JSON: %s" % failure, file=sys.stderr)
        return 1

    rows = jira._rows_from(document)
    if not rows:
        print("found no work items in that document; expected a list of issues, or an "
              "object with an 'issues' / 'values' / 'nodes' list", file=sys.stderr)
        return 1

    items = [item for item in (jira.parse_item(row) for row in rows) if item]
    if not items:
        print("found %d rows but none parsed as work items" % len(rows), file=sys.stderr)
        return 1

    path = cache.write(
        jira.CACHE_NAME,
        {"jql": arguments.jql, "items": [asdict(item) for item in items]},
        source=arguments.label,
    )
    active = sum(1 for item in items if item.is_active)
    print("wrote %d work items (%d in flight) to %s" % (len(items), active, path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
