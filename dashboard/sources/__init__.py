"""Data sources for the dashboard's live panes.

A source turns an external system into plain dataclasses and nothing else -- no
colors, no layout, no knowledge of the widget that will draw it. Sources are
allowed to be slow and allowed to fail; the widget layer decides what a failure
looks like on screen.

Every source degrades the same way. It tries live access first, falls back to a
cache written by an earlier successful fetch, and reports how old that cache is
so the pane can mark itself stale instead of quietly showing yesterday's work.
"""
