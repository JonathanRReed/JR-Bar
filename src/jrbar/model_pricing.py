"""The price list the usage estimates use, and the person's own overrides.

``resources/model_pricing.json`` is a snapshot of the per-million-token
rates, written by ``scripts/update_model_pricing.py`` (by hand, from our
own table or from LiteLLM's MIT price list). It ships with the app; nothing
here ever fetches a price at runtime. ``usage_stats`` loads it at import and
falls back to its hand-kept table when the file is missing or unreadable.

``pricing_overrides`` in the settings lets a person price a model their
own way (a negotiated rate, a model the table does not know yet):
``{"model": {"input", "output", "cache_read", "cache_write"}}`` in USD per
million tokens. A key matches the way the table's markers do: when it
appears inside the model name ("opus", "gpt-5.6-sol"), the longest key
first. An override always wins over the table. A model neither knows stays
unpriced, never $0.
"""

from __future__ import annotations

import json
import threading
import time
from importlib import resources
from typing import Any

SNAPSHOT_SCHEMA = 1
_FAMILIES = ("anthropic", "openai", "gemini")
_OVERRIDE_REFRESH_SECONDS = 30.0


def _rows(raw: object) -> tuple[tuple[str, float, float], ...] | None:
    if not isinstance(raw, list) or not raw:
        return None
    rows = []
    for item in raw:
        if (
            not isinstance(item, list)
            or len(item) != 3
            or not isinstance(item[0], str)
            or not item[0]
            or not all(isinstance(value, (int, float)) and not isinstance(value, bool) for value in item[1:])
            or item[1] < 0
            or item[2] < 0
        ):
            return None
        rows.append((item[0].lower(), float(item[1]), float(item[2])))
    return tuple(rows)


def load_snapshot(text: str | None = None) -> dict[str, Any] | None:
    """The packaged snapshot as ``{"anthropic": rows, "openai": rows,
    "gemini": rows, "cache_read_overrides": {...}, "as_of": str}``, or
    None when it is missing or malformed (the hand table is then used)."""
    try:
        if text is None:
            text = resources.files("jrbar.resources").joinpath("model_pricing.json").read_text(encoding="utf-8")
        document = json.loads(text)
    except (OSError, ValueError, ModuleNotFoundError):
        return None
    if not isinstance(document, dict) or document.get("schemaVersion") != SNAPSHOT_SCHEMA:
        return None
    tables = {}
    for family in _FAMILIES:
        rows = _rows(document.get(family))
        if rows is None:
            return None
        tables[family] = rows
    overrides = document.get("cacheReadOverrides") or {}
    if not isinstance(overrides, dict) or not all(
        isinstance(key, str) and isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0
        for key, value in overrides.items()
    ):
        return None
    as_of = document.get("asOf")
    return {
        **tables,
        "cache_read_overrides": {key.lower(): float(value) for key, value in overrides.items()},
        "as_of": as_of if isinstance(as_of, str) else None,
    }


class _Overrides:
    """``pricing_overrides`` from the settings, re-read at most every 30 s
    (the price lookups run once per usage record)."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._loaded_at: float | None = None
        self._rows: tuple[tuple[str, dict[str, float]], ...] = ()
        self._pinned: dict[str, dict[str, float]] | None = None

    def pin(self, overrides: dict[str, dict[str, float]] | None) -> None:
        """Tests and callers that already hold the settings pin the table."""
        from .usage_source_settings import normalize_pricing_overrides

        with self._lock:
            self._pinned = None if overrides is None else normalize_pricing_overrides(overrides)
            self._loaded_at = None

    def rows(self) -> tuple[tuple[str, dict[str, float]], ...]:
        now = time.monotonic()
        with self._lock:
            if self._loaded_at is not None and now - self._loaded_at < _OVERRIDE_REFRESH_SECONDS:
                return self._rows
            source = self._pinned
        if source is None:
            try:
                from .settings import load_settings
                from .usage_source_settings import normalize_pricing_overrides

                source = normalize_pricing_overrides(getattr(load_settings(), "pricing_overrides", None))
            except Exception:
                source = {}
        rows = tuple(sorted(source.items(), key=lambda item: -len(item[0])))
        with self._lock:
            self._rows = rows
            self._loaded_at = now
        return rows


OVERRIDES = _Overrides()


def override_for(model: str) -> dict[str, float] | None:
    """The person's own rates for ``model``, or None."""
    lowered = str(model or "").lower()
    if not lowered:
        return None
    for key, prices in OVERRIDES.rows():
        if key in lowered:
            return prices
    return None


__all__ = ["OVERRIDES", "SNAPSHOT_SCHEMA", "load_snapshot", "override_for"]
