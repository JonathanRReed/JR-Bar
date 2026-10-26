"""Shared provider order and menu visibility. Presentation only."""

from __future__ import annotations

import re

_PROVIDER_ID = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")


def provider_display(value: object) -> dict[str, list[str]] | None:
    if value is None:
        return None
    if not isinstance(value, dict) or set(value) != {"order", "hidden"}:
        raise ValueError("provider_display needs order and hidden lists")
    result = {}
    for key in ("order", "hidden"):
        ids = value[key]
        if (not isinstance(ids, list) or len(ids) > 128
                or any(not isinstance(item, str) or not _PROVIDER_ID.fullmatch(item) for item in ids)
                or len(set(ids)) != len(ids)):
            raise ValueError(f"provider_display.{key} needs unique lowercase provider ids")
        result[key] = list(ids)
    return result


def load_provider_display(value: object) -> dict[str, list[str]] | None:
    try:
        return provider_display(value)
    except ValueError:
        return None
